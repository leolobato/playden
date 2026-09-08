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
    func testLibraryImportKeepsSteamAcquisitionDateSeparateFromDiscoveryAndPlaytime() {
        let acquired = Date(timeIntervalSince1970: 1_400_000_000), played = Date(timeIntervalSince1970: 1_600_000_000)
        let result = LiveSteamBackend.libraryRecords([
            OwnedGame(appID: 100, name: "Owned", playtimeMinutes: 120, lastPlayedAt: played),
            OwnedGame(appID: 200, name: "Unknown date", playtimeMinutes: 0)
        ], acquiredAt: [100: acquired, 999: acquired])
        XCTAssertEqual(result.count, 2, "License metadata must not add apps to the owned-library response")
        XCTAssertEqual(result[0].sourceAcquiredAt, acquired)
        XCTAssertEqual(result[0].sourceLastPlayedAt, played)
        XCTAssertEqual(result[0].importedPlaytimeSeconds, 7200)
        XCTAssertGreaterThan(result[0].firstObservedAt, acquired)
        XCTAssertNil(result[1].sourceAcquiredAt, "Unknown acquisition must not become the import timestamp")
    }

    func testSignOutCancelsAuthenticatedOperationAndKeepsCredentialsCleared() async throws {
        let store = MemoryCredentials(), started = Gate(), release = Gate(), operationStarted = Gate()
        try store.save(StoredAuth(accountName: "Fixture", steamID: 1, refreshToken: "fixture"))
        await release.open()
        let account = SteamAccount(store: store, backend: DelayedBackend(started: started, release: release))
        let task = Task {
            try await account.authenticatedOperation { _ -> Int in
                await operationStarted.open()
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }
        await operationStarted.wait()
        try await account.signOut()
        do { _ = try await task.value; XCTFail("Signed-out operation returned a result") }
        catch { XCTAssertEqual(error as? SourceFailure, .cancelled) }
        XCTAssertNil(try store.load())
    }
    func testCallerCancellationStopsAuthenticatedOperationWithoutSigningOut() async throws {
        let store = MemoryCredentials(), started = Gate(), release = Gate(), operationStarted = Gate()
        try store.save(StoredAuth(accountName: "Fixture", steamID: 1, refreshToken: "fixture"))
        await release.open()
        let account = SteamAccount(store: store, backend: DelayedBackend(started: started, release: release))
        let task = Task {
            try await account.authenticatedOperation { _ -> Int in
                await operationStarted.open()
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }
        await operationStarted.wait(); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled operation returned a result") }
        catch { XCTAssertEqual(error as? SourceFailure, .cancelled) }
        XCTAssertNotNil(try store.load())
    }
    func testAuthenticatedOperationDoesNotReadCLIAuthFallback() async throws {
        let store = MemoryCredentials(), started = Gate(), release = Gate()
        let account = SteamAccount(store: store, backend: DelayedBackend(started: started, release: release))
        do {
            _ = try await account.authenticatedOperation { _ -> Int in XCTFail("Signed-out operation started"); return 1 }
            XCTFail("Expected signed-out failure")
        } catch { XCTAssertEqual(error as? SourceFailure, .signedOut) }
    }
    func testLiveQRChallengeAndPublicMetadataWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["BIGSCREEN_STEAM_NETWORK_PROBE"] == "1" else {
            throw XCTSkip("Set BIGSCREEN_STEAM_NETWORK_PROBE=1 for the unauthenticated network probe")
        }
        let store = MemoryCredentials()
        let account = SteamAccount(store: store, backend: LiveSteamBackend())
        let ready = expectation(description: "Steam issued an HTTPS QR challenge")
        ready.assertForOverFulfill = false
        let login = Task {
            try await account.signInWithQR { event in
                if case .qrChallenge(let url, _) = event, url.scheme == "https" { ready.fulfill() }
            }
        }
        await fulfillment(of: [ready], timeout: 20)
        login.cancel(); await account.cancelSignIn()
        _ = try? await login.value
        XCTAssertNil(try store.load())
        let game = SourceGameRecord(id: GameID(source: "steam", value: "268910"), title: "Cuphead")
        let metadata = try await SteamSource().metadata(for: game)
        XCTAssertFalse(metadata.summary.isEmpty)
        XCTAssertFalse(metadata.genres.isEmpty)
    }
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
        let first = KeychainCredentials(service: "com.bigscreen.app.tests.\(UUID().uuidString)")
        let second = KeychainCredentials(service: "com.bigscreen.app.tests.\(UUID().uuidString)")
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
    func testLegacyCredentialsMigrateOnceAndSignOutCannotRestoreThem() throws {
        let legacy = KeychainCredentials(service: "com.bigscreen.app.tests.legacy.\(UUID().uuidString)")
        let current = KeychainCredentials(service: "com.bigscreen.app.tests.current.\(UUID().uuidString)", legacyService: legacy.service)
        defer { try? current.clear(); try? legacy.clear() }
        let fixture = StoredAuth(accountName: "Fixture", steamID: 1, refreshToken: "not-a-real-token")
        try legacy.save(fixture)
        XCTAssertEqual(try current.load()?.refreshToken, fixture.refreshToken)
        XCTAssertNil(try legacy.load())
        try current.clear()
        XCTAssertNil(try current.load())
        try legacy.save(fixture)
        try current.clear()
        XCTAssertNil(try current.load())
        XCTAssertNil(try legacy.load())
    }
    func testFailureMappingDoesNotExposeCredentialURLs() {
        let error = SteamError.http(status: 403, url: "https://fixture.invalid?access_token=do-not-display")
        let failure = sourceFailure(error)
        XCTAssertEqual(failure, .expired)
        XCTAssertFalse(failure.localizedDescription.contains("do-not-display"))
    }
}
