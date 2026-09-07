import XCTest
import Domain
import SteamCore
@testable import Sources

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; for waiter in waiters { waiter.resume() }; waiters = [] }
}
private struct DelayedBackend: SteamBackend {
    let started: Gate
    let release: Gate
    func credentials() -> StoredAuth { StoredAuth(accountName: "Fixture", steamID: 1, refreshToken: "fixture-refresh", accessToken: "fixture-access") }
    func loginQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> StoredAuth {
        await started.open(); await release.wait(); return credentials()
    }
    func login(accountName: String, password: String, guardData: String?, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
               onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> StoredAuth { credentials() }
    func renew(_ auth: StoredAuth) async throws -> StoredAuth {
        await started.open(); await release.wait(); return credentials()
    }
    func ownedGames(_ auth: StoredAuth) async throws -> [SourceGameRecord] { [] }
}
final class SteamAccountTests: XCTestCase {
    func testSignOutDuringRenewalCannotResurrectKeychainCredentials() async throws {
        let store = MemoryCredentials()
        try store.save(StoredAuth(accountName: "Fixture", steamID: 1, refreshToken: "fixture-refresh"))
        let started = Gate(), release = Gate()
        let account = SteamAccount(store: store, backend: DelayedBackend(started: started, release: release))
        let refresh = Task { try await account.ownedGames() }
        await started.wait(); try await account.signOut(); await release.open()
        do { _ = try await refresh.value; XCTFail("Stale renewal must be rejected") } catch { XCTAssertEqual(error as? SourceFailure, .cancelled) }
        XCTAssertNil(try store.load())
    }
    func testCancelledLoginNeverStoresCredentials() async throws {
        let store = MemoryCredentials(), started = Gate(), release = Gate()
        let account = SteamAccount(store: store, backend: DelayedBackend(started: started, release: release))
        let login = Task { try await account.signInWithQR(onEvent: { _ in }) }
        await started.wait(); await account.cancelSignIn(); await release.open()
        do { _ = try await login.value; XCTFail("Cancelled login must not succeed") } catch {}
        XCTAssertNil(try store.load())
    }
    func testKeychainRoundTripUsesOnlyItsOwnService() throws {
        let first = KeychainCredentials(service: "com.gamenative.bigscreen.tests.\(UUID().uuidString)")
        let second = KeychainCredentials(service: "com.gamenative.bigscreen.tests.\(UUID().uuidString)")
        defer { try? first.clear(); try? second.clear() }
        XCTAssertNil(try first.load())
        let fixture = StoredAuth(accountName: "Fixture", steamID: 1, refreshToken: "not-a-real-token")
        try first.save(fixture)
        XCTAssertEqual(try first.load()?.refreshToken, fixture.refreshToken)
        XCTAssertNil(try second.load())
        var renewed = fixture; renewed.accessToken = "not-a-real-access-token"
        try first.save(renewed)
        XCTAssertEqual(try first.load()?.accessToken, renewed.accessToken)
        try first.clear(); XCTAssertNil(try first.load())
    }
    func testPublicMetadataMappingLeavesMissingSupportUnknown() throws {
        let game = SourceGameRecord(id: GameID(source: "steam", value: "268910"), title: "Cuphead")
        let data = Data(#"{"268910":{"success":true,"data":{"steam_appid":268910,"short_description":"Run &amp; <b>jump</b>","genres":[{"description":"Action"}]}}}"#.utf8)
        let metadata = try SteamSource.parseMetadata(data, for: game)
        XCTAssertEqual(metadata.summary, "Run & jump")
        XCTAssertEqual(metadata.genres, ["Action"])
        XCTAssertEqual(metadata.controllerSupport, .unknown)
        XCTAssertNotNil(metadata.metadataUpdatedAt)
        let mismatch = Data(#"{"268910":{"success":true,"data":{"steam_appid":42}}}"#.utf8)
        XCTAssertThrowsError(try SteamSource.parseMetadata(mismatch, for: game))
    }
    func testFailureMappingDoesNotExposeCredentialURLs() {
        let error = SteamError.http(status: 403, url: "https://fixture.invalid?access_token=do-not-display")
        let failure = sourceFailure(error)
        XCTAssertEqual(failure, .expired)
        XCTAssertFalse(failure.localizedDescription.contains("do-not-display"))
    }
}
