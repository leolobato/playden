import XCTest
import Domain
import SteamCore
@testable import Sources

private struct PassthroughBackend: SteamBackend {
    func loginQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> StoredAuth { throw SourceFailure.unavailable }
    func login(accountName: String, password: String, guardData: String?, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
               onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> StoredAuth { throw SourceFailure.unavailable }
    func renew(_ auth: StoredAuth) async throws -> StoredAuth { auth }
    func ownedGames(_ auth: StoredAuth, acquisitionDates: @escaping @Sendable () async -> [UInt32: Date]) async throws -> [SourceGameRecord] { [] }
}
private actor Opens {
    private(set) var count = 0
    private(set) var closed = 0
    func open() { count += 1 }
    func close() { closed += 1 }
}

final class SteamSignInSharingTests: XCTestCase {
    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("playden-signin-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func account(_ opens: Opens, root: URL) throws -> SteamAccount {
        let store = MemoryCredentials()
        try store.save(StoredAuth(accountName: "Fixture", steamID: 1, refreshToken: "fixture-refresh", accessToken: "fixture-access"))
        let connection = SharedConnection<CMLogin, CMClient>(idleTimeout: .seconds(60), open: { _ in
            await opens.open(); return CMClient(depotKeyStore: MemoryDepotKeys())
        }, isAlive: { _ in true }, close: { _ in await opens.close() })
        return SteamAccount(store: store, backend: PassthroughBackend(), connection: connection, diagnostics: SteamConnectionDiagnostics(root: root))
    }

    func testDeviceIdentityIsCreatedOnceAndReused() throws {
        let root = temporaryRoot()
        let first = SteamDeviceIdentity.load(root: root)
        XCTAssertEqual(SteamDeviceIdentity.load(root: root), first)
        XCTAssertEqual(first.machineName, "Playden")
        XCTAssertNotEqual(SteamDeviceIdentity.load(root: temporaryRoot()).loginID, first.loginID)
    }

    func testLogonsTodayCountsOnlyTodaysLogons() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().date(from: "2026-09-27T10:00:00Z")!
        try """
        2026-09-26T23:59:59Z A connection CM logon result=1
        2026-09-27T00:00:01Z B connection CM logon result=1
        2026-09-27T00:00:02Z B connection ready logons-today=1
        """.write(to: root.appendingPathComponent("steam-connections.previous.log"), atomically: true, encoding: .utf8)
        try "2026-09-27T09:00:00Z C connection CM logon result=5\n"
            .write(to: root.appendingPathComponent("steam-connections.log"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SteamConnectionDiagnostics(root: root).logonsToday(now: now), 2)
    }

    func testGameSteamClientHoldsTheSignInUntilItEnds() async throws {
        let opens = Opens(), root = temporaryRoot(), account = try account(opens, root: root)
        _ = try await account.withCM { _ in 1 }
        let first = await opens.count
        XCTAssertEqual(first, 1)

        let game = UUID()
        await account.beginSteamClientSession(game)
        let closed = await opens.closed
        XCTAssertEqual(closed, 1, "Handing off closes Playden's own session")
        do {
            _ = try await account.withCM { _ -> Int in XCTFail("Steam work ran while a game held the sign-in"); return 1 }
            XCTFail("Expected refusal")
        } catch { XCTAssertEqual(error as? SourceFailure, .unavailable) }
        var opened = await opens.count
        XCTAssertEqual(opened, 1, "No logon while the game's client is signed in")

        await account.endSteamClientSession(UUID())  // an unknown session does not release it
        do { _ = try await account.withCM { _ in 1 }; XCTFail("Expected refusal") } catch {}

        await account.endSteamClientSession(game)
        _ = try await account.withCM { _ in 1 }
        opened = await opens.count
        XCTAssertEqual(opened, 2)
        let log = try String(contentsOf: root.appendingPathComponent("steam-connections.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("steam-client session begin active=1"))
        XCTAssertTrue(log.contains("refused: a game's Steam client holds the sign-in"))
    }

    func testReplacedSessionIsNotRetried() async throws {
        let opens = Opens(), account = try account(opens, root: temporaryRoot())
        let attempts = Opens()
        do {
            _ = try await account.withCM { _ -> Int in
                await attempts.open()
                throw SteamError.eresult(.logonSessionReplaced, context: "fixture")
            }
            XCTFail("Expected the replaced session to surface")
        } catch {}
        let tries = await attempts.count
        XCTAssertEqual(tries, 1)
    }
}
