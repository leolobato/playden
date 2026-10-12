import XCTest
import Darwin
import CryptoKit
@testable import SteamCore

final class CDNTransportTests: XCTestCase {
    // Per-request sessions lose both the connection and the session across depot boundaries.
    func testSequentialRequestsAcrossDepotsReuseConnection() async throws {
        let server = try KeepAliveHTTPFixture()
        defer { server.stop() }
        let diagnostics = SteamPerformanceDiagnostics()
        let transport = URLSessionCDNTransport()
        for depot in [1, 2] {
            let data = try await CDNClient.get(server.url("/depot/\(depot)/chunk/fixture"), diagnostics: diagnostics, transport: transport)
            XCTAssertEqual(data, Data("fixture".utf8))
        }
        XCTAssertEqual(server.snapshot.connections, 1)
        XCTAssertEqual(server.snapshot.requests, 2)
        XCTAssertEqual(diagnostics.snapshot()[.sessionCreation].count, 1)
        XCTAssertEqual(diagnostics.snapshot()[.networkTransfer].count, 2)
        XCTAssertEqual(diagnostics.snapshot()[.networkTransfer].bytes, 14)
    }

    func testConcurrentRequestsUseOneSessionAndIndependentResponses() async throws {
        let server = try KeepAliveHTTPFixture { request, _ in
            let path = request.components(separatedBy: " ")[1]
            return .init(body: Data(path.utf8), delay: 0.3)
        }
        defer { server.stop() }
        let diagnostics = SteamPerformanceDiagnostics(), transport = URLSessionCDNTransport()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let path = "/chunk/\(index)"
                    let data = try await CDNClient.get(server.url(path), diagnostics: diagnostics, transport: transport)
                    XCTAssertEqual(data, Data(path.utf8))
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(server.snapshot.maximumActive, 16, "The HTTP/1.1 pool must cover the supported in-flight chunk budget")
        XCTAssertEqual(server.snapshot.requests, 16)
        XCTAssertEqual(diagnostics.snapshot()[.sessionCreation].count, 1, "Concurrent first requests must not race session construction")
        XCTAssertEqual(diagnostics.snapshot()[.networkTransfer].count, 16)
    }

    func testCancellingOneRequestPreservesSiblingAndPool() async throws {
        let server = try KeepAliveHTTPFixture { request, _ in
            .init(delay: request.contains("/cancel ") ? 1 : 0.2)
        }
        defer { server.stop() }
        let diagnostics = SteamPerformanceDiagnostics(), transport = URLSessionCDNTransport()
        let cancelled = Task { try await CDNClient.get(server.url("/cancel"), diagnostics: diagnostics, transport: transport) }
        let sibling = Task { try await CDNClient.get(server.url("/sibling"), diagnostics: diagnostics, transport: transport) }
        try await waitForRequests(2, on: server)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled request must fail") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        let siblingData = try await sibling.value
        XCTAssertEqual(siblingData, Data("fixture".utf8))
        let after = try await CDNClient.get(server.url("/after"), diagnostics: diagnostics, transport: transport)
        XCTAssertEqual(after, Data("fixture".utf8))
        XCTAssertEqual(server.snapshot.requests, 3)
        XCTAssertEqual(server.snapshot.connections, 2, "The completed sibling connection remains reusable")
        XCTAssertEqual(diagnostics.snapshot()[.sessionCreation].count, 1)
        XCTAssertEqual(diagnostics.snapshot()[.networkTransfer].count, 3)
        XCTAssertEqual(diagnostics.snapshot()[.networkTransfer].bytes, 14)
    }

    func testRequestTimeoutLeavesTransportUsable() async throws {
        let server = try KeepAliveHTTPFixture { request, _ in .init(delay: request.contains("/slow ") ? 1 : 0) }
        defer { server.stop() }
        let diagnostics = SteamPerformanceDiagnostics()
        let transport = LoopbackCDNTransport(pool: URLSessionCDNTransport(), ports: [:], timeout: 0.1)
        do {
            _ = try await CDNClient.get(server.url("/slow"), diagnostics: diagnostics, transport: transport)
            XCTFail("Delayed response must time out")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let after = try await CDNClient.get(server.url("/after"), diagnostics: diagnostics, transport: transport)
        XCTAssertEqual(after, Data("fixture".utf8))
        XCTAssertEqual(diagnostics.snapshot()[.sessionCreation].count, 1)
        XCTAssertEqual(diagnostics.snapshot()[.networkTransfer].count, 2)
        XCTAssertEqual(diagnostics.snapshot()[.networkTransfer].bytes, 7)
    }

    func testTransportDoesNotRetainCookiesOrCacheResponses() async throws {
        let server = try KeepAliveHTTPFixture { request, ordinal in
            .init(body: Data("\(ordinal):\(request.contains("Cookie:"))".utf8),
                headers: "Set-Cookie: fixture=value; Path=/\r\nCache-Control: max-age=3600\r\n")
        }
        defer { server.stop() }
        let transport = URLSessionCDNTransport()
        let first = try await CDNClient.get(server.url("/same"), transport: transport)
        let second = try await CDNClient.get(server.url("/same"), transport: transport)
        XCTAssertEqual(first, Data("1:false".utf8))
        XCTAssertEqual(second, Data("2:false".utf8))
        XCTAssertEqual(server.snapshot.connections, 1)
    }

    func testExistingSharedSessionDoesNotClaimAnotherCreation() async throws {
        let server = try KeepAliveHTTPFixture()
        defer { server.stop() }
        _ = try await CDNClient.get(server.url("/warm"))
        let diagnostics = SteamPerformanceDiagnostics()
        _ = try await CDNClient.get(server.url("/measured"), diagnostics: diagnostics)
        XCTAssertEqual(server.snapshot.connections, 1)
        XCTAssertEqual(diagnostics.snapshot()[.sessionCreation].count, 0)
        XCTAssertEqual(diagnostics.snapshot()[.networkTransfer].count, 1)
    }

    func testRetryFailsOverWithSameTransportAndRealChunkValidation() async throws {
        let failed = try KeepAliveHTTPFixture { _, _ in .init(status: "503 Service Unavailable") }
        let good = try KeepAliveHTTPFixture { _, _ in .init(body: encryptedFixtureChunk) }
        defer { failed.stop(); good.stop() }
        let diagnostics = SteamPerformanceDiagnostics()
        let transport = LoopbackCDNTransport(pool: URLSessionCDNTransport(), ports: ["failed.fixture": failed.port, "good.fixture": good.port])
        let data = try await DownloadEngine.fetchChunkWithRetry(servers: [contentServer("failed.fixture"), contentServer("good.fixture")],
            depotID: 1, chunk: fixtureChunk(), key: Data(repeating: 0, count: 32), diagnostics: diagnostics, transport: transport)
        XCTAssertEqual(data, Data("fixture".utf8))
        XCTAssertEqual(failed.snapshot.requests, 1)
        XCTAssertEqual(good.snapshot.requests, 1)
        XCTAssertEqual(diagnostics.snapshot()[.sessionCreation].count, 1)
        XCTAssertEqual(diagnostics.snapshot()[.networkTransfer].count, 2)
        XCTAssertEqual(diagnostics.snapshot()[.networkTransfer].bytes, 151)
        XCTAssertEqual(diagnostics.snapshot()[.adler32].bytes, 7)
    }

    func testCorruptPlaintextResponseRetriesBeforeWriterCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cdn-corrupt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = try KeepAliveHTTPFixture { _, _ in .init(body: corruptEncryptedFixtureChunk) }
        let good = try KeepAliveHTTPFixture { _, _ in .init(body: encryptedFixtureChunk) }
        defer { corrupt.stop(); good.stop() }
        let diagnostics = SteamPerformanceDiagnostics()
        let transport = LoopbackCDNTransport(pool: URLSessionCDNTransport(), ports: ["corrupt.fixture": corrupt.port, "good.fixture": good.port])
        let manifest = DepotManifest(depotID: 1, gid: 1, files: [.init(path: "file", size: 7, chunks: [fixtureChunk()],
            contentSHA1: SteamCrypto.sha1(Data("fixture".utf8)))], totalSize: 7)
        try await ResumableDepotDownload(destination: root, diagnostics: diagnostics).download(manifest: manifest) { chunk in
            try await DownloadEngine.fetchChunkWithRetry(servers: [contentServer("corrupt.fixture"), contentServer("good.fixture")],
                depotID: 1, chunk: chunk, key: Data(repeating: 0, count: 32), diagnostics: diagnostics, transport: transport)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file")), Data("fixture".utf8))
        XCTAssertEqual(corrupt.snapshot.requests, 1); XCTAssertEqual(good.snapshot.requests, 1)
        XCTAssertEqual(diagnostics.snapshot()[.adler32].count, 2, "One failed response check and one successful incoming check")
        XCTAssertEqual(diagnostics.snapshot()[.fileWrite].count, 2, "One content write and one journal write")
    }
    func testCorruptPlaintextResponsesExhaustRetryBudget() async throws {
        let server = try KeepAliveHTTPFixture { _, _ in .init(body: corruptEncryptedFixtureChunk) }
        defer { server.stop() }
        let diagnostics = SteamPerformanceDiagnostics()
        let transport = LoopbackCDNTransport(pool: URLSessionCDNTransport(), ports: ["corrupt.fixture": server.port])
        do {
            _ = try await DownloadEngine.fetchChunkWithRetry(servers: [contentServer("corrupt.fixture")], depotID: 1,
                chunk: fixtureChunk(), key: Data(repeating: 0, count: 32), diagnostics: diagnostics, transport: transport)
            XCTFail("Corrupt decoded content must exhaust retries")
        } catch SteamError.download(let message) { XCTAssertEqual(message, "chunk checksum mismatch") }
        XCTAssertEqual(server.snapshot.requests, 3)
        XCTAssertEqual(diagnostics.snapshot()[.adler32].count, 3)
    }

    func testRetryExhaustionKeepsThreeAttemptBudgetAndConnection() async throws {
        let server = try KeepAliveHTTPFixture { _, _ in .init(status: "503 Service Unavailable") }
        defer { server.stop() }
        let diagnostics = SteamPerformanceDiagnostics()
        let transport = LoopbackCDNTransport(pool: URLSessionCDNTransport(), ports: ["failed.fixture": server.port])
        do {
            _ = try await DownloadEngine.fetchChunkWithRetry(servers: [contentServer("failed.fixture")], depotID: 1,
                chunk: fixtureChunk(), key: Data(repeating: 0, count: 32), diagnostics: diagnostics, transport: transport)
            XCTFail("Three failed responses must exhaust retry budget")
        } catch SteamError.http(let status, _) { XCTAssertEqual(status, 503) }
        XCTAssertEqual(server.snapshot.requests, 3)
        XCTAssertEqual(server.snapshot.connections, 1)
        XCTAssertEqual(diagnostics.snapshot()[.sessionCreation].count, 1)
        XCTAssertEqual(diagnostics.snapshot()[.networkTransfer].count, 3)
    }

    func testCancelledChunkDoesNotRetry() async throws {
        let server = try KeepAliveHTTPFixture { _, _ in .init(body: encryptedFixtureChunk, delay: 1) }
        defer { server.stop() }
        let diagnostics = SteamPerformanceDiagnostics()
        let transport = LoopbackCDNTransport(pool: URLSessionCDNTransport(), ports: ["good.fixture": server.port])
        let task = Task {
            try await DownloadEngine.fetchChunkWithRetry(servers: [contentServer("good.fixture")], depotID: 1,
                chunk: fixtureChunk(), key: Data(repeating: 0, count: 32), diagnostics: diagnostics, transport: transport)
        }
        try await waitForRequests(1, on: server)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled chunk must fail") }
        catch is CancellationError {}
        XCTAssertEqual(server.snapshot.requests, 1)
        XCTAssertEqual(diagnostics.snapshot()[.networkTransfer].count, 1)
    }

    func testPreparationAndMultipleDepotEnginesShareLazyPool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cdn-transport-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try KeepAliveHTTPFixture { _, _ in .init(body: encryptedFixtureChunk) }
        defer { server.stop() }
        let keys = MemoryDepotKeys()
        for depot: UInt32 in [1, 2] { keys.save(Data(repeating: 0, count: 32), for: depot) }
        let cm = CMClient(depotKeyStore: keys), diagnostics = SteamPerformanceDiagnostics()
        let transport = LoopbackCDNTransport(pool: URLSessionCDNTransport(), ports: ["good.fixture": server.port])
        let manifests = [UInt32(1), 2].map { depot in
            DepotManifest(depotID: depot, gid: 1, files: [.init(path: "depot\(depot).bin", size: 14,
                chunks: [fixtureChunk(), fixtureChunk(offset: 7)])], totalSize: 14)
        }
        let preparation = DownloadEngine(cm: cm, appID: 1, destination: root, diagnostics: diagnostics, transport: transport)
        try await preparation.prepare(manifests: manifests)
        XCTAssertEqual(diagnostics.snapshot()[.sessionCreation].count, 0, "Key preparation must not create an unused session")
        for manifest in manifests {
            var engine = DownloadEngine(cm: cm, appID: 1, destination: root, diagnostics: diagnostics, transport: transport)
            engine.chunkConcurrency = 1
            try await engine.download(manifest: manifest, servers: [contentServer("good.fixture")])
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("depot\(manifest.depotID).bin")), Data("fixturefixture".utf8))
        }
        XCTAssertEqual(server.snapshot.connections, 1)
        XCTAssertEqual(server.snapshot.requests, 4)
        XCTAssertEqual(diagnostics.snapshot()[.sessionCreation].count, 1)
        XCTAssertEqual(diagnostics.snapshot()[.networkTransfer].bytes, 576)
        // Four fresh fetch validations plus four assembled-file fallback checks (step 4 removes those).
        XCTAssertEqual(diagnostics.snapshot()[.adler32].count, 8)
        XCTAssertEqual(diagnostics.snapshot()[.adler32].bytes, 56)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let metadataBytes = try manifests.reduce(UInt64(0)) { total, manifest in
            total + UInt64(Data(manifest.files[0].path.utf8).count + (try encoder.encode(manifest.files[0])).count)
        }
        XCTAssertEqual(diagnostics.snapshot()[.sha256].bytes, metadataBytes, "Only path and pinned manifest metadata are hashed")
    }

    private func waitForRequests(_ count: Int, on server: KeepAliveHTTPFixture) async throws {
        let deadline = Date().addingTimeInterval(2)
        while server.snapshot.requests < count, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThanOrEqual(server.snapshot.requests, count)
    }
}

/// Routing-only adapter: CDN URL construction, HTTP status handling, AES/ZIP, checksums,
/// retries and the injected pool remain real. Never opens an external connection.
private struct LoopbackCDNTransport: CDNTransport {
    let pool: URLSessionCDNTransport
    let ports: [String: UInt16]
    var timeout: TimeInterval? = nil
    func data(for request: URLRequest, diagnostics: SteamPerformanceDiagnostics?) async throws -> (Data, URLResponse) {
        var local = request
        if let host = request.url?.host, let port = ports[host] {
            var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            url.scheme = "http"; url.host = "127.0.0.1"; url.port = Int(port)
            local.url = url.url!
        }
        guard local.url?.host == "127.0.0.1" else { throw URLError(.unsupportedURL) }
        if let timeout { local.timeoutInterval = timeout }
        return try await pool.data(for: local, diagnostics: diagnostics)
    }
}

private func contentServer(_ host: String) -> ContentServer { .init(host: host, vhost: host, load: 0) }
private func fixtureChunk(offset: UInt64 = 0) -> DepotManifest.Chunk {
    .init(sha: Data(hexString: "51cff3c1f0bc59f6187e7040cc12a4e9b1eca7aa")!, offset: offset,
        compressedSize: 144, uncompressedSize: 7, checksum: 202375943)
}
// ZIP_STORED("fixture") encrypted with a zero AES-256 fixture key and zero IV,
// preceded by the ECB-encrypted IV. Fixed synthetic bytes, never a depot credential.
private let encryptedFixtureChunk = Data(hexString:
    "dc95c078a2408989ad48a21492842087aad318afca76531f80bc989bdd0db73f6fb7e75d506029df28c58c8c9c116a95ef2b5029da6dbb65cafce11b371e4b11aa8cf227631366bd1ef1f9f95a798939c991a7fd948bc9d7abe213f4ea44817ba879b60990dd2ace3ef8ab7af284ba0ddf4110f3dc5609cb592413c9233d1f0e12529733f474fd54d6c61dee211a4899")!

// Same valid encrypted ZIP container carrying seven wrong plaintext bytes.
private let corruptEncryptedFixtureChunk = Data(hexString: "dc95c078a2408989ad48a21492842087aad318afca76531f80bc989bdd0db73f045a08fc04950f0855ecc6add7d8ac53c5b7605682014b99075e3a99ca1ae8cb1d74e80cc792cb7ecf0fa4f9b458a36421380a86a459be66dca09bb19aaceac52e01c6c74b553a674c5f2b2f43bc853478189b37733bf319caa5b1b1cff136b6159773b8929c6f0455c8f32121f8b97c")!

/// Real HTTP/1.1 keep-alive with independent socket workers and numeric evidence.
/// All request bytes stay inside this bounded loopback fixture.
final class KeepAliveHTTPFixture: @unchecked Sendable {
    struct Reply {
        var status = "200 OK"
        var body = Data("fixture".utf8)
        var delay: TimeInterval = 0
        var headers = ""
    }
    struct Snapshot { let connections: Int; let requests: Int; let maximumActive: Int }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var sockets: Set<Int32> = []
        var stopped = false
        var connections = 0
        var requests = 0
        var active = 0
        var maximumActive = 0
        let reply: @Sendable (String, Int) -> Reply
        init(reply: @escaping @Sendable (String, Int) -> Reply) { self.reply = reply }
    }
    private let listener: Int32
    private let state: State
    let port: UInt16
    var snapshot: Snapshot {
        state.lock.withLock { Snapshot(connections: state.connections, requests: state.requests, maximumActive: state.maximumActive) }
    }
    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    init(reply: @escaping @Sendable (String, Int) -> Reply = { _, _ in Reply() }) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 32) == 0 else { Darwin.close(fd); throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard resolved == 0 else { Darwin.close(fd); throw POSIXError(.EIO) }
        listener = fd; port = UInt16(bigEndian: address.sin_port)
        let state = State(reply: reply)
        self.state = state
        DispatchQueue.global().async {
            while true {
                let connection = accept(fd, nil, nil)
                guard connection >= 0 else { return }
                var suppressPipe: Int32 = 1
                _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &suppressPipe, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                let accepted = state.lock.withLock { () -> Bool in
                    guard !state.stopped else { return false }
                    state.connections += 1; state.sockets.insert(connection)
                    return true
                }
                guard accepted else { Darwin.close(connection); return }
                DispatchQueue.global().async { Self.serve(connection, state: state) }
            }
        }
    }

    func stop() {
        state.lock.withLock {
            guard !state.stopped else { return }
            state.stopped = true
            shutdown(listener, SHUT_RDWR); Darwin.close(listener)
            for socket in state.sockets { shutdown(socket, SHUT_RDWR) }
        }
    }
    deinit { stop() }

    private static func serve(_ socket: Int32, state: State) {
        defer {
            state.lock.withLock { _ = state.sockets.remove(socket); Darwin.close(socket) }
        }
        var buffered = Data()
        while true {
            while buffered.range(of: Data("\r\n\r\n".utf8)) == nil {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = recv(socket, &bytes, bytes.count, 0)
                guard count > 0 else { return }
                buffered.append(contentsOf: bytes.prefix(count))
                guard buffered.count < 65536 else { return }
            }
            let end = buffered.range(of: Data("\r\n\r\n".utf8))!.upperBound
            let request = String(decoding: buffered.prefix(end), as: UTF8.self)
            buffered.removeSubrange(..<end)
            let ordinal = state.lock.withLock { () -> Int in
                state.requests += 1; state.active += 1
                state.maximumActive = max(state.maximumActive, state.active)
                return state.requests
            }
            let reply = state.reply(request, ordinal)
            if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }
            let header = "HTTP/1.1 \(reply.status)\r\nContent-Length: \(reply.body.count)\r\nConnection: keep-alive\r\n\(reply.headers)\r\n"
            let response = Data(header.utf8) + reply.body
            let sent = response.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < buffer.count {
                    let count = send(socket, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            state.lock.withLock { state.active -= 1 }
            if !sent { return }
        }
    }
}
