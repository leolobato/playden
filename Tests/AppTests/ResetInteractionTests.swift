import XCTest
import GRDB
import Domain
import Catalog
import Installs
import Input
@testable import Playden

private actor ResetAuth: SourceAuth {
    var signedIn = true, failSignOut = false, holdSignOut = false
    var signOutCalls = 0
    func configure(failing: Bool = false, holding: Bool = false) { failSignOut = failing; holdSignOut = holding }
    func identity() async throws -> SourceIdentity? { signedIn ? .init(sourceID: "fixture", displayName: "Fixture player") : nil }
    func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func signIn(accountName: String, password: String, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
                onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func cancelSignIn() async {}
    func signOut() async throws {
        signOutCalls += 1
        while holdSignOut { try await Task.sleep(for: .milliseconds(5)) }
        if failSignOut { throw SourceFailure.storage("Fixture keychain failure") }
        signedIn = false
    }
}
private actor ResetRefreshGate {
    var entered = false
    var continuation: CheckedContinuation<[SourceGameRecord], Never>?
    func wait() async -> [SourceGameRecord] {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ games: [SourceGameRecord]) { continuation?.resume(returning: games); continuation = nil }
}
private struct ResetSource: GameSource {
    let id = "fixture", displayName = "Fixture"
    let auth: any SourceAuth
    var gate: ResetRefreshGate?
    func installer(for game: SourceGameRecord) throws -> any Installer { throw SourceFailure.unavailable }
    func ownedGames() async throws -> [SourceGameRecord] { if let gate { return await gate.wait() }; return [] }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
}
private actor ResetQueue: InstallQueuing {
    func start() async throws {}
    func shutdown() async {}
    func updates() -> AsyncStream<InstallQueueSnapshot> { AsyncStream { $0.finish() } }
    func offer(for game: SourceGameRecord, volume: GamesVolumeSelection) async throws -> InstallOffer { throw SourceFailure.unavailable }
    func enqueue(_ offer: InstallOffer) async throws -> UUID { throw SourceFailure.unavailable }
    func uninstall(_ authorization: UninstallAuthorization) async throws -> UUID { throw SourceFailure.unavailable }
    func repair(_ gameID: GameID) async throws -> UUID { throw SourceFailure.unavailable }
    func setPaused(_ paused: Bool, reason: PauseReason, jobID: UUID) async throws {}
    func retry(_ jobID: UUID) async throws {}
    func cancel(_ jobID: UUID) async throws {}
    func move(_ jobID: UUID, before otherID: UUID) async throws {}
    func setGameplayPaused(_ paused: Bool) async throws {}
}

@MainActor final class ResetInteractionTests: XCTestCase {
    private func fixture(gate: ResetRefreshGate? = nil) throws -> (LibraryModel, CatalogStore, ResetAuth, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResetUI-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("catalog.sqlite").path, catalog = try CatalogStore(path: path)
        let id = GameID(source: "fixture", value: "game"), game = SourceGameRecord(id: id, title: "Installed game")
        try catalog.saveInstallation(.init(game: game, location: .init(volumeID: "fixture", lastKnownRoot: root, relativePath: "game"),
            bottleID: "fixture-game", manifestIDs: [:], templateVersion: "1", launchSpec: .init(executableRelativePath: "game.exe"), installedBytes: 100))
        try catalog.replaceSourceCatalog(source: "fixture", games: [game])
        var preferences = LibraryPreferences(); preferences.setupCompleted = true; preferences.reducedMotion = true
        preferences.downloadWhilePlaying = true; preferences.selectedDisplayUUID = "TV"; preferences.startInFullscreen = false
        try catalog.saveLibraryState(edits: [id: .init(isFavorite: true, isHidden: true, compatibility: .works, note: "My note")],
            collections: [.init(name: "Weekend", gameIDs: [id])], preferences: preferences)
        let auth = ResetAuth()
        let model = LibraryModel(catalog: catalog, preview: false, source: ResetSource(auth: auth, gate: gate), installQueue: ResetQueue())
        model.identity = .init(sourceID: "fixture", displayName: "Fixture player")
        return (model, catalog, auth, path)
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The reset fixture did not reach the requested state")
        throw SourceFailure.unavailable
    }
    func testAboutNavigationAndCancelNeverResetData() async throws {
        let (model, catalog, auth, _) = try fixture()
        let before = try catalog.snapshot()
        model.selectTab(.settings); model.settingsSection = 5; model.settingsIndex = 1
        model.perform(.move(.down)); XCTAssertEqual(model.settingsIndex, 2)
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .resetAppData); XCTAssertEqual(model.panelIndex, 0)
        model.perform(.nextTab); XCTAssertEqual(model.tab, .settings)
        model.perform(.confirm)
        XCTAssertNil(model.panel)
        XCTAssertEqual(try catalog.preferences(), before.preferences)
        XCTAssertEqual(try catalog.snapshot().entries, before.entries)
        let calls = await auth.signOutCalls; XCTAssertEqual(calls, 0)
        model.stopServices()
    }
    func testConfirmedResetSignsOutRestoresDefaultsAndKeepsInstalledGame() async throws {
        let (model, catalog, auth, _) = try fixture()
        let installed = try catalog.snapshot().entries.first?.installation
        model.showResetAppData(); model.perform(.move(.right)); model.perform(.confirm)
        await model.resetTask?.value
        XCTAssertNil(model.resetError); XCTAssertNil(model.identity)
        XCTAssertNil(model.panel); XCTAssertTrue(model.onboarding)
        XCTAssertEqual(model.setupScreen, .controller)
        XCTAssertEqual(try catalog.preferences(), .init())
        XCTAssertEqual(try catalog.snapshot().entries.first?.installation, installed)
        XCTAssertEqual(model.games.count, 1); XCTAssertFalse(model.games[0].isFavorite); XCTAssertFalse(model.games[0].isHidden)
        XCTAssertTrue(model.collections.isEmpty); XCTAssertFalse(model.reducedMotion); XCTAssertFalse(model.downloadWhilePlaying)
        XCTAssertNil(model.selectedDisplayUUID); XCTAssertTrue(model.startInFullscreen)
        let calls = await auth.signOutCalls; XCTAssertEqual(calls, 1)
        model.stopServices()
    }
    func testKeychainFailureKeepsCustomizationsAndOffersRetry() async throws {
        let (model, catalog, auth, _) = try fixture()
        let before = try catalog.snapshot()
        await auth.configure(failing: true)
        model.showResetAppData(); model.activateReset(.reset); await model.resetTask?.value
        XCTAssertEqual(model.panel, .resetAppData); XCTAssertNotNil(model.resetError)
        XCTAssertFalse(model.resetBusy); XCTAssertFalse(model.onboarding)
        XCTAssertEqual(try catalog.snapshot().entries, before.entries)
        XCTAssertEqual(try catalog.preferences(), before.preferences)
        XCTAssertEqual(model.resetActionTitle(.reset), "Retry reset")
        await auth.configure()
        model.activateReset(.reset); await model.resetTask?.value
        XCTAssertNil(model.resetError); XCTAssertTrue(model.onboarding)
        model.stopServices()
    }
    func testDatabaseFailureReportsSignOutAndRollsBackUntilExplicitRetry() async throws {
        let (model, catalog, _, path) = try fixture(), before = try catalog.snapshot()
        let database = try DatabaseQueue(path: path)
        try await database.write { try $0.execute(sql: "CREATE TRIGGER reject_reset BEFORE DELETE ON game_edits BEGIN SELECT RAISE(ABORT, 'fixture reset failure'); END") }
        model.showResetAppData(); model.activateReset(.reset); await model.resetTask?.value
        XCTAssertNil(model.identity)
        XCTAssertTrue(model.resetError?.contains("signed out") == true)
        XCTAssertEqual(try catalog.snapshot().entries, before.entries)
        XCTAssertEqual(try catalog.preferences(), before.preferences)
        try await database.write { try $0.execute(sql: "DROP TRIGGER reject_reset") }
        model.activateReset(.reset); await model.resetTask?.value
        XCTAssertNil(model.resetError); XCTAssertTrue(model.onboarding)
        model.stopServices()
    }
    func testBusyResetTrapsInputAndJoinsLateLibraryRefresh() async throws {
        let gate = ResetRefreshGate(), (model, catalog, auth, _) = try fixture(gate: gate)
        model.refreshLibrary(); try await wait { await gate.entered }
        model.selectTab(.settings); model.showResetAppData(); model.activateReset(.reset)
        XCTAssertTrue(model.resetBusy)
        model.perform(.back); model.perform(.nextTab); model.selectTab(.home)
        model.beginSignIn(); model.beginPlay(.init(source: "fixture", value: "game"))
        XCTAssertEqual(model.panel, .resetAppData); XCTAssertEqual(model.tab, .settings)
        let calls = await auth.signOutCalls; XCTAssertEqual(calls, 0)
        await gate.release([.init(id: .init(source: "fixture", value: "late"), title: "Late result")])
        await model.resetTask?.value
        XCTAssertNil(model.resetError); XCTAssertTrue(model.onboarding)
        XCTAssertEqual(try catalog.snapshot().entries.map(\.id.value), ["game"])
        XCTAssertNil(try catalog.lastSync(for: "fixture"))
        model.stopServices()
    }
    func testActiveDownloadBlocksResetBeforeSigningOutAndCanBeRechecked() async throws {
        let (model, catalog, auth, _) = try fixture()
        var job = JobRecord(gameID: .init(source: "fixture", value: "download")); job.state = .running
        try catalog.saveJob(job)
        model.showResetAppData()
        XCTAssertEqual(model.resetActions, [.cancel, .checkAgain])
        model.activateReset(.reset); XCTAssertNil(model.resetTask)
        let calls = await auth.signOutCalls; XCTAssertEqual(calls, 0)
        job.state = .paused; job.pauseReasons = [.user]; try catalog.saveJob(job)
        model.activateReset(.checkAgain)
        XCTAssertNil(model.resetBlocker)
        model.activateReset(.reset); await model.resetTask?.value
        XCTAssertNil(model.resetError)
        XCTAssertEqual(try catalog.jobs().first, job)
        model.stopServices()
    }
}
