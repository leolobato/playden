import XCTest
import CryptoKit
import Darwin
@testable import SteamCore

final class SteamPerformanceDiagnosticsTests: XCTestCase {
    func testConcurrentMeasurementsKeepAllNumericTotals() async throws {
        let diagnostics = SteamPerformanceDiagnostics()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1000 {
                group.addTask { diagnostics.record(.networkTransfer, bytes: 17, nanoseconds: 23) }
            }
        }
        let value = diagnostics.snapshot()[.networkTransfer]
        XCTAssertEqual(value.count, 1000)
        XCTAssertEqual(value.bytes, 17000)
        XCTAssertEqual(value.nanoseconds, 23000)
        XCTAssertEqual(diagnostics.snapshot()[.sha1].count, 0)
        let json = String(decoding: try JSONEncoder().encode(diagnostics.snapshot()), as: UTF8.self)
        XCTAssertFalse(json.contains("account"))
        XCTAssertFalse(json.contains("https"))
    }

    func testOneCollectorAggregatesDepotWritesAndDiskVerification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("performance-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = SteamPerformanceDiagnostics()
        let bytes = Data("fixture".utf8)
        let chunk = DepotManifest.Chunk(sha: SteamCrypto.sha1(bytes), offset: 0,
            compressedSize: UInt32(bytes.count), uncompressedSize: UInt32(bytes.count), checksum: DepotManifest.Chunk.adler(bytes))
        for depot: UInt32 in [1, 2] {
            let manifest = DepotManifest(depotID: depot, gid: 1, files: [.init(path: "sub/file\(depot)",
                size: UInt64(bytes.count), chunks: [chunk], contentSHA1: SteamCrypto.sha1(bytes))], totalSize: UInt64(bytes.count))
            let download = ResumableDepotDownload(destination: root, diagnostics: diagnostics)
            try await download.download(manifest: manifest) { chunk in
                try chunk.validate(bytes, diagnostics: diagnostics)
                return bytes
            }
            XCTAssertTrue(try download.invalidFiles(in: manifest).isEmpty)
        }
        let result = diagnostics.snapshot()
        // Fetch validates once; only explicit disk verification rereads content.
        XCTAssertEqual(result[.adler32].bytes, UInt64(bytes.count * 2))
        XCTAssertEqual(result[.sha1].bytes, UInt64(bytes.count * 2))
        XCTAssertEqual(result[.contentRead].bytes, UInt64(bytes.count * 2))
        XCTAssertEqual(result[.checkpoint].count, 2, "One completion receipt checkpoint per depot")
        XCTAssertEqual(result[.fileSync].count, 4, "One content sync and one receipt sync per depot")
        XCTAssertEqual(result[.directorySync].count, 10, "Publication, receipt replacement, and cleanup are durable")
        XCTAssertEqual(result[.sha256].count, 6, "Two path hashes and four journal/receipt manifest fingerprints; no chunk hashes")
        XCTAssertGreaterThan(result[.directoryWalk].count, 0)
        XCTAssertGreaterThan(result[.progressCallback].count, 0)
        XCTAssertEqual(result[.fileValidation].count, 4)
        XCTAssertEqual(result[.networkTransfer].count, 0, "Injected plaintext fixture fetch is not a real CDN transfer")
        XCTAssertEqual(result[.sessionCreation].count, 0)
    }
    func testChunkSHA1FallbackMeasuresFetchAndDiskValidations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("performance-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = SteamPerformanceDiagnostics(), bytes = Data("fixture".utf8)
        let chunk = DepotManifest.Chunk(sha: SteamCrypto.sha1(bytes), offset: 0,
            compressedSize: UInt32(bytes.count), uncompressedSize: UInt32(bytes.count))
        let manifest = DepotManifest(depotID: 1, gid: 1, files: [.init(path: "file", size: UInt64(bytes.count), chunks: [chunk])], totalSize: UInt64(bytes.count))
        let download = ResumableDepotDownload(destination: root, diagnostics: diagnostics)
        try await download.download(manifest: manifest) { chunk in
            try chunk.validate(bytes, diagnostics: diagnostics)
            return bytes
        }
        XCTAssertTrue(try download.invalidFiles(in: manifest).isEmpty)
        XCTAssertEqual(diagnostics.snapshot()[.sha1].bytes, UInt64(bytes.count * 2))
        XCTAssertEqual(diagnostics.snapshot()[.adler32].bytes, 0)
        XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, UInt64(bytes.count))
    }

    func testResumeMeasuresRetainedChunkRereadAndValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("performance-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pieces = [Data("first".utf8), Data("second".utf8)]
        var offset: UInt64 = 0
        let chunks = pieces.map { data -> DepotManifest.Chunk in
            defer { offset += UInt64(data.count) }
            return .init(sha: SteamCrypto.sha1(data), offset: offset, compressedSize: UInt32(data.count),
                uncompressedSize: UInt32(data.count), checksum: DepotManifest.Chunk.adler(data))
        }
        let manifest = DepotManifest(depotID: 1, gid: 1, files: [.init(path: "file", size: offset, chunks: chunks,
            contentSHA1: SteamCrypto.sha1(pieces.reduce(Data(), +)))], totalSize: offset)
        var interrupted = ResumableDepotDownload(destination: root); interrupted.chunkConcurrency = 1
        do {
            try await interrupted.download(manifest: manifest) { chunk in
                if chunk.offset > 0 { throw CancellationError() }
                try chunk.validate(pieces[0])
                return pieces[0]
            }
            XCTFail("Expected interrupted fixture")
        } catch is CancellationError {}
        let diagnostics = SteamPerformanceDiagnostics()
        let resumed = ResumableDepotDownload(destination: root, diagnostics: diagnostics)
        try await resumed.download(manifest: manifest) { chunk in
            XCTAssertGreaterThan(chunk.offset, 0, "Verified checkpointed chunk must be retained")
            try chunk.validate(pieces[1], diagnostics: diagnostics)
            return pieces[1]
        }
        let result = diagnostics.snapshot()
        XCTAssertEqual(result[.contentRead].bytes, UInt64(pieces[0].count))
        XCTAssertEqual(result[.sha1].bytes, 0)
        XCTAssertEqual(result[.adler32].bytes, UInt64(pieces[0].count + pieces[1].count))
        XCTAssertEqual(result[.checkpoint].count, 1, "Completion receipt is checkpointed at depot end")
        XCTAssertEqual(result[.sha256].count, 3, "Path and journal/receipt manifests only; retained and fresh content receive no SHA-256")
    }

    func testHTTPMeasuresSessionsResponseBytesAndFailedStatusWithoutURLs() async throws {
        let server = try NumericHTTPFixture()
        let diagnostics = SteamPerformanceDiagnostics()
        let base = "http://127.0.0.1:\(server.port)/fixture-private-token"
        let transport = URLSessionCDNTransport()
        let response = try await CDNClient.get(base, diagnostics: diagnostics, transport: transport)
        XCTAssertEqual(response, Data("fixture".utf8))
        do {
            _ = try await CDNClient.get(base, diagnostics: diagnostics, transport: transport)
            XCTFail("Expected failed HTTP status")
        } catch SteamError.http(let status, _) { XCTAssertEqual(status, 404) }
        let result = diagnostics.snapshot()
        XCTAssertEqual(result[.sessionCreation].count, 1)
        XCTAssertEqual(result[.networkTransfer].count, 2)
        XCTAssertEqual(result[.networkTransfer].bytes, 14, "Count response bodies on failed status as well")
        XCTAssertGreaterThan(result[.networkTransfer].nanoseconds, 0)
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(json.contains("fixture-private-token"))
        XCTAssertFalse(json.contains("127.0.0.1"))
    }

}

/// A bounded local socket server: no internet, account or URLSession configuration override.
private final class NumericHTTPFixture {
    private let listener: Int32
    let port: UInt16
    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 2) == 0 else { Darwin.close(fd); throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard resolved == 0 else { Darwin.close(fd); throw POSIXError(.EIO) }
        listener = fd; port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global().async {
            for status in ["200 OK", "404 Not Found"] {
                let connection = accept(fd, nil, nil)
                guard connection >= 0 else { return }
                var request = [UInt8](repeating: 0, count: 4096)
                _ = recv(connection, &request, request.count, 0)
                let response = Data("HTTP/1.1 \(status)\r\nContent-Length: 7\r\nConnection: close\r\n\r\nfixture".utf8)
                _ = response.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
                Darwin.close(connection)
            }
        }
    }
    deinit { shutdown(listener, SHUT_RDWR); Darwin.close(listener) }
}
