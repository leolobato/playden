import XCTest
import SteamCore
@testable import Sources

private final class FakeClient: @unchecked Sendable {
    let id: Int
    private let lock = NSLock()
    private var _alive = true
    var alive: Bool { get { lock.withLock { _alive } } set { lock.withLock { _alive = newValue } } }
    init(id: Int) { self.id = id }
}

private actor Opener {
    private(set) var opened: [String] = []
    private(set) var closed: [Int] = []
    var delay: Duration = .zero
    var failure: Error?
    func setDelay(_ value: Duration) { delay = value }
    func setFailure(_ value: Error?) { failure = value }
    func open(_ key: String) async throws -> FakeClient {
        opened.append(key)
        let id = opened.count
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return FakeClient(id: id)
    }
    func close(_ client: FakeClient) { client.alive = false; closed.append(client.id) }
}

final class SharedConnectionTests: XCTestCase {
    private func connection(_ opener: Opener, idle: Duration = .seconds(60)) -> SharedConnection<String, FakeClient> {
        SharedConnection(idleTimeout: idle, open: { try await opener.open($0) }, isAlive: { $0.alive }, close: { await opener.close($0) })
    }

    func testConcurrentOperationsShareOneLogon() async throws {
        let opener = Opener(); await opener.setDelay(.milliseconds(50))
        let shared = connection(opener)
        let ids = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 { group.addTask { try await shared.use("token") { client in try await Task.sleep(for: .milliseconds(20)); return client.id } } }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(ids), [1])
        let opened = await opener.opened
        XCTAssertEqual(opened, ["token"])
    }

    func testDroppedClientIsReplacedOnNextUse() async throws {
        let opener = Opener(), shared = connection(opener)
        let first = try await shared.use("token") { $0 }
        first.alive = false
        let second = try await shared.use("token") { $0.id }
        XCTAssertEqual(second, 2)
    }

    func testChangedSignInClosesPreviousClient() async throws {
        let opener = Opener(), shared = connection(opener)
        _ = try await shared.use("old") { $0.id }
        let id = try await shared.use("new") { $0.id }
        XCTAssertEqual(id, 2)
        let closed = await opener.closed
        XCTAssertEqual(closed, [1])
    }

    func testIdleClientClosesOnlyAfterLastUser() async throws {
        let opener = Opener(), shared = connection(opener, idle: .milliseconds(50))
        let long = Task { try await shared.use("token") { _ in try await Task.sleep(for: .milliseconds(200)) } }
        try await Task.sleep(for: .milliseconds(20))
        _ = try await shared.use("token") { $0.id }
        try await Task.sleep(for: .milliseconds(100))
        var closed = await opener.closed
        XCTAssertEqual(closed, [], "A client in use must not close when another user finishes")
        try await long.value
        try await Task.sleep(for: .milliseconds(150))
        closed = await opener.closed
        XCTAssertEqual(closed, [1])
    }

    func testFailedOpenIsSharedAndRetriedByLaterUse() async throws {
        let opener = Opener(); await opener.setDelay(.milliseconds(30)); await opener.setFailure(URLError(.notConnectedToInternet))
        let shared = connection(opener)
        let a = Task { try await shared.use("token") { $0.id } }
        let b = Task { try await shared.use("token") { $0.id } }
        for task in [a, b] {
            do { _ = try await task.value; XCTFail("Open failure must reach every waiter") } catch {}
        }
        var opened = await opener.opened
        XCTAssertEqual(opened.count, 1)
        await opener.setFailure(nil)
        let id = try await shared.use("token") { $0.id }
        XCTAssertEqual(id, 2)
        opened = await opener.opened
        XCTAssertEqual(opened.count, 2)
    }

    func testResetClosesClient() async throws {
        let opener = Opener(), shared = connection(opener)
        _ = try await shared.use("token") { $0.id }
        await shared.reset()
        let closed = await opener.closed
        XCTAssertEqual(closed, [1])
    }

    func testOnlyDroppedSessionsReconnect() {
        // Another client took the sign-in; logging straight back on would kick it in turn.
        XCTAssertFalse(SteamAccount.isDroppedSession(SteamError.eresult(.logonSessionReplaced, context: "")))
        XCTAssertTrue(SteamAccount.isReplacedSession(SteamError.eresult(.logonSessionReplaced, context: "")))
        XCTAssertTrue(SteamAccount.isDroppedSession(SteamError.authSessionExpired))
        XCTAssertTrue(SteamAccount.isDroppedSession(URLError(.networkConnectionLost)))
        XCTAssertFalse(SteamAccount.isDroppedSession(SteamError.authFailed("rejected")))
        XCTAssertFalse(SteamAccount.isDroppedSession(SteamError.eresult(.accessDenied, context: "")))
        XCTAssertFalse(SteamAccount.isDroppedSession(CancellationError()))
    }
}
