import XCTest
import Synchronization
import SteamProto
import SwiftProtobuf
@testable import SteamCore

final class CMRequestTests: XCTestCase {
    func testLoggedOffDiagnosticRetainsSteamReason() async throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Diagnostic capture requires macOS 15") }
        let messages = Mutex<[String]>([])
        let cm = CMClient(depotKeyStore: MemoryDepotKeys(), diagnostic: { message in
            messages.withLock { $0.append(message) }
        })
        let transport = TestCMTransport()
        try await cm.attach(transport)
        let licenses = Task { try await cm.waitForLicenses() }
        try await wait(cm, count: 1)
        var loggedOff = CMsgClientLoggedOff(); loggedOff.eresult = 34
        transport.deliver(try frame(.kEmsgClientLoggedOff, body: loggedOff))
        await expectFailure(licenses)
        XCTAssertTrue(messages.withLock { $0.contains("CM logged off result=34 pending=1") })
        XCTAssertTrue(transport.isClosed)
    }
    func testLiveCMHelloWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["PLAYDEN_CM_NETWORK_PROBE"] == "1" else {
            throw XCTSkip("Set PLAYDEN_CM_NETWORK_PROBE=1 for an unauthenticated CM handshake")
        }
        let cm = client(timeout: 10)
        do {
            try await cm.connect()
            let pending = await cm.outstandingRequests
            XCTAssertEqual(pending, 0)
            await cm.disconnect()
        } catch { await cm.disconnect(); throw error }
    }
    private func client(timeout: TimeInterval = 0.2) -> CMClient { CMClient(depotKeyStore: MemoryDepotKeys(), requestTimeout: timeout) }
    private func frame<M: Message>(_ type: EMsg, body: M, target: UInt64? = nil, session: Int32 = 0) throws -> Data {
        var header = CMsgProtoBufHeader(); header.clientSessionid = session
        if session != 0 { header.steamid = 123 }
        if let target { header.jobidTarget = target }
        let bytes = try header.serializedData()
        var data = Data(); data.appendLE(UInt32(type.rawValue) | 0x8000_0000); data.appendLE(UInt32(bytes.count))
        data.append(bytes); data.append(try body.serializedData()); return data
    }
    private func wait(_ cm: CMClient, count: Int) async throws {
        let deadline = Date().addingTimeInterval(1)
        while await cm.outstandingRequests != count {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private func expectFailure<T>(_ task: Task<T, Error>) async {
        do { _ = try await task.value; XCTFail("Request unexpectedly completed") } catch {}
    }
    func testJobDeadlineReleasesWaiterAndIgnoresLateReply() async throws {
        let cm = client(timeout: 0.03), transport = TestCMTransport()
        try await cm.attach(transport)
        do { _ = try await cm.jobRequest(.kEmsgClientHeartBeat, body: CMsgClientHeartBeat()); XCTFail() }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let pending = await cm.outstandingRequests; XCTAssertEqual(pending, 0)
        transport.deliver(try frame(.kEmsgClientHeartBeat, body: CMsgClientHeartBeat(), target: 2))
        await cm.disconnect()
    }
    func testCancellationRemovesOnlyThatLicenseWaiter() async throws {
        let cm = client(), transport = TestCMTransport(); try await cm.attach(transport)
        let first = Task { try await cm.waitForLicenses() }, second = Task { try await cm.waitForLicenses() }
        try await wait(cm, count: 2)
        first.cancel(); await expectFailure(first)
        try await wait(cm, count: 1)
        transport.deliver(try frame(.kEmsgClientLicenseList, body: CMsgClientLicenseList()))
        try await second.value
        try await cm.waitForLicenses() // Already received; no second registration.
        await cm.disconnect()
    }
    func testDisconnectReleasesLogonJobsAndLicenseWaits() async throws {
        let cm = client(timeout: 10), transport = TestCMTransport(); try await cm.attach(transport)
        let logon = Task { try await cm.logOn(accountName: "fixture", refreshToken: "fixture") }
        let job = Task { try await cm.jobRequest(.kEmsgClientHeartBeat, body: CMsgClientHeartBeat()) }
        let licenses = Task { try await cm.waitForLicenses() }
        try await wait(cm, count: 3)
        await cm.disconnect()
        await expectFailure(logon); await expectFailure(job); await expectFailure(licenses)
        let pending = await cm.outstandingRequests; XCTAssertEqual(pending, 0)
        XCTAssertTrue(transport.isClosed)
    }
    func testLogonTimeoutClosesConnectionAndClearsIdentity() async throws {
        let cm = client(timeout: 0.03), transport = TestCMTransport(); try await cm.attach(transport)
        let login = Task { try await cm.logOn(accountName: "fixture", refreshToken: "fixture") }
        await expectFailure(login)
        XCTAssertTrue(transport.isClosed)
        let session = await cm.sessionID; XCTAssertEqual(session, 0)
    }
    func testStaleConnectionCannotDeliverIdentityOrFailNewRequests() async throws {
        let cm = client(), old = TestCMTransport(ignoreClose: true), current = TestCMTransport()
        try await cm.attach(old)
        let login = Task { try await cm.logOn(accountName: "fixture", refreshToken: "fixture") }
        try await wait(cm, count: 1)
        try await cm.attach(current)
        await expectFailure(login)
        var response = CMsgClientLogonResponse(); response.eresult = 1
        old.deliver(try frame(.kEmsgClientLogOnResponse, body: response, session: 55))
        let licenses = Task { try await cm.waitForLicenses() }
        try await wait(cm, count: 1)
        current.deliver(try frame(.kEmsgClientLicenseList, body: CMsgClientLicenseList()))
        try await licenses.value
        XCTAssertFalse(current.isClosed)
        let session = await cm.sessionID; XCTAssertEqual(session, 0)
        await cm.disconnect()
    }
    func testCancelledBeforeRegistrationAndSendFailureLeaveNoWaiters() async throws {
        let cm = client(), transport = TestCMTransport(); try await cm.attach(transport)
        let cancelled = Task { try Task.checkCancellation(); try await cm.waitForLicenses() }
        cancelled.cancel(); await expectFailure(cancelled)
        transport.close()
        let request = Task { try await cm.jobRequest(.kEmsgClientHeartBeat, body: CMsgClientHeartBeat()) }
        await expectFailure(request)
        let pending = await cm.outstandingRequests; XCTAssertEqual(pending, 0)
        await cm.disconnect()
    }
    func testMultipartResponseCompletesOnlyAtTerminalFrame() async throws {
        let cm = client(), transport = TestCMTransport(); try await cm.attach(transport)
        let request = Task { try await cm.jobRequest(.kEmsgClientHeartBeat, body: CMsgClientHeartBeat(), isComplete: { $0.count == 0 }) }
        try await wait(cm, count: 1)
        var first = CMsgClientHeartBeat(); first.sendReply = true
        transport.deliver(try frame(.kEmsgClientHeartBeat, body: first, target: 2))
        transport.deliver(try frame(.kEmsgClientHeartBeat, body: CMsgClientHeartBeat(), target: 2))
        let parts = try await request.value; XCTAssertEqual(parts.count, 2)
        await cm.disconnect()
    }
    func testPreparedDepotsDownloadAfterCMDisconnectAndMissingKeysReportNetworkLoss() async throws {
        let cm = client(), transport = TestCMTransport(); try await cm.attach(transport)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifests = [UInt32(7), 8].map { DepotManifest(depotID: $0, gid: 1, files: [], totalSize: 0) }
        let engine = DownloadEngine(cm: cm, appID: 42, destination: root)
        let preparation = Task { try await engine.prepare(manifests: manifests) }
        try await wait(cm, count: 1)
        var response = CMsgClientGetDepotDecryptionKeyResponse(); response.eresult = 1
        response.depotEncryptionKey = Data(repeating: 1, count: 32)
        transport.deliver(try frame(.kEmsgClientGetDepotDecryptionKeyResponse, body: response, target: 2))
        // Waiting for the second request's actual send avoids confusing the first pending job.
        let deadline = Date().addingTimeInterval(1)
        while await cm.outstandingRequests != 1 || transport.sentCount < 3 {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
        transport.deliver(try frame(.kEmsgClientGetDepotDecryptionKeyResponse, body: response, target: 3))
        try await preparation.value
        await cm.disconnect()
        for manifest in manifests {
            try await engine.download(manifest: manifest, servers: [.init(host: "unused.invalid", vhost: "unused.invalid", load: 0)])
        }
        do { _ = try await cm.depotKey(appID: 42, depotID: 9); XCTFail("Missing key must require a connection") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
    }
    func testConnectionLossIsReportedAsNetworkFailure() async throws {
        let cm = client(), transport = TestCMTransport(); try await cm.attach(transport)
        let request = Task { try await cm.waitForLicenses() }
        try await wait(cm, count: 1); transport.close()
        do { try await request.value; XCTFail() }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        await cm.disconnect()
    }
    func testSteamLoggedOffIsReportedAsExpiredAuthentication() async throws {
        let cm = client(), transport = TestCMTransport(); try await cm.attach(transport)
        let request = Task { try await cm.waitForLicenses() }
        try await wait(cm, count: 1)
        transport.deliver(try frame(.kEmsgClientLoggedOff, body: CMsgClientLoggedOff()))
        do { try await request.value; XCTFail() }
        catch { guard case SteamError.authSessionExpired = error else { XCTFail("Wrong error: \(error)"); return } }
        XCTAssertTrue(transport.isClosed)
        await cm.disconnect()
    }
}

private final class TestCMTransport: CMTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var sent = 0
    var sentCount: Int { lock.withLock { sent } }
    private var frames: [Data] = []
    private var receiver: CheckedContinuation<Data, Error>?
    private let ignoreClose: Bool
    init(ignoreClose: Bool = false) { self.ignoreClose = ignoreClose }
    var isClosed: Bool { lock.withLock { closed } }
    func send(_ data: Data) async throws { try lock.withLock { if closed { throw URLError(.networkConnectionLost) }; sent += 1 } }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if closed { continuation.resume(throwing: URLError(.cancelled)) }
                else if !frames.isEmpty { continuation.resume(returning: frames.removeFirst()) }
                else { receiver = continuation }
            }
        }
    }
    func deliver(_ frame: Data) {
        lock.withLock {
            if let receiver { self.receiver = nil; receiver.resume(returning: frame) }
            else { frames.append(frame) }
        }
    }
    func close() {
        guard !ignoreClose else { return }
        lock.withLock { closed = true; receiver?.resume(throwing: URLError(.cancelled)); receiver = nil }
    }
}
