import XCTest
import Domain
@testable import Catalog

final class CatalogStoreTests: XCTestCase {
    private let steam = GameID(source: "steam", value: "268910")
    private let other = GameID(source: "fixture", value: "268910")
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func temporaryPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BigScreenCatalogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("catalog.sqlite").path
    }
    private func game(_ id: GameID, name: String = "Cuphead") -> SourceGameRecord {
        SourceGameRecord(id: id, title: name, firstObservedAt: epoch)
    }
    private func installation(_ source: SourceGameRecord) -> InstallationRecord {
        InstallationRecord(game: source,
            location: GameLocation(volumeID: "test-volume-uuid", lastKnownRoot: URL(fileURLWithPath: "/Volumes/Fixture"), relativePath: "steam/268910/Cuphead"),
            bottleID: "gn-steam-268910", manifestIDs: ["268911": "12345678901234567890"], templateVersion: "1",
            launchSpec: LaunchSpec(executableRelativePath: "Cuphead.exe"), installedAt: epoch, installedBytes: 4_000_000_000)
    }
    func testPinnedInstallPlanAndStagingSurviveRestartAndOlderRecordsStillDecode() throws {
        let path = try temporaryPath(), source = game(steam)
        var installed = installation(source)
        let plan = InstallPlan(game: source, manifestIDs: installed.manifestIDs,
            estimate: InstallEstimate(downloadBytes: 100, installedBytes: 200, requiredBytes: 500),
            launchSpec: installed.launchSpec, sourcePayload: Data("versioned fixture content".utf8))
        let staging = InstallStaging(mutations: [FileMutation(relativePath: "steam_api.dll", originalRelativePath: "steam_api.dll.orig", stagedSHA256: Data(repeating: 1, count: 32))], dllOverrides: ["steam_api=n,b"])
        var job = JobRecord(gameID: steam); job.plan = plan; job.manifestIDs = plan.manifestIDs
        job.stage = .download; job.state = .paused; job.pauseReasons = [.user]
        installed.plan = plan; installed.staging = staging
        do {
            let store = try CatalogStore(path: path)
            try store.saveJob(job); try store.saveInstallation(installed)
        }
        let reopened = try CatalogStore(path: path)
        XCTAssertEqual(try reopened.jobs().first, job)
        XCTAssertEqual(try reopened.snapshot().entries.first?.installation, installed)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(installed)) as? [String: Any])
        old.removeValue(forKey: "plan"); old.removeValue(forKey: "staging")
        let decoded = try JSONDecoder().decode(InstallationRecord.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.plan); XCTAssertNil(decoded.staging)
        XCTAssertEqual(decoded.launchSpec, installed.launchSpec)
    }
    func testMigrationsAndReopeningPersistLocalState() throws {
        let path = try temporaryPath()
        let collection = GameCollection(name: "Weekend 🎮", gameIDs: [steam, other], isPinned: true)
        let edit = GameEdits(isFavorite: true, isHidden: true, compatibility: .playable, note: "Use 1080p — café 🎮")
        var preferences = LibraryPreferences(); preferences.scope = .collection(collection.id)
        preferences.sort = .recentlyAdded; preferences.reducedMotion = true; preferences.selectedDisplayID = 42
        do {
            let store = try CatalogStore(path: path)
            try store.replaceSourceCatalog(source: steam.source, games: [game(steam)])
            try store.saveLibraryState(edits: [steam: edit], collections: [collection], preferences: preferences)
        }
        let reopened = try CatalogStore(path: path)
        let result = try reopened.snapshot()
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.edits, edit)
        XCTAssertEqual(result.collections, [collection])
        XCTAssertEqual(result.preferences, preferences)
    }
    func testRefreshKeepsEditsFirstSeenAndMetadataAndSeparatesSources() throws {
        let store = try CatalogStore()
        var original = game(steam); original.summary = "An enriched description"
        original.genres = ["Action"]; original.metadataUpdatedAt = epoch
        try store.replaceSourceCatalog(source: steam.source, games: [original])
        try store.replaceSourceCatalog(source: other.source, games: [game(other, name: "Other store")])
        try store.saveEdits(GameEdits(isFavorite: true, compatibility: .works), for: steam)
        var refreshed = game(steam, name: "Cuphead updated")
        refreshed.importedPlaytimeSeconds = 3600; refreshed.firstObservedAt = epoch.addingTimeInterval(1000)
        try store.replaceSourceCatalog(source: steam.source, games: [refreshed])
        let entries = try store.snapshot().entries
        let result = try XCTUnwrap(entries.first { $0.id == steam })
        XCTAssertEqual(result.source.title, "Cuphead updated")
        XCTAssertEqual(result.source.summary, original.summary)
        XCTAssertEqual(result.source.firstObservedAt, epoch)
        XCTAssertEqual(result.totalPlaytimeSeconds, 3600)
        XCTAssertTrue(result.edits.isFavorite)
        XCTAssertEqual(entries.count, 2)
        XCTAssertFalse(try XCTUnwrap(entries.first { $0.id == other }).edits.isFavorite)
    }
    func testInvalidRefreshAndDuplicateCollectionsRollbackEntireTransaction() throws {
        let store = try CatalogStore()
        try store.replaceSourceCatalog(source: steam.source, games: [game(steam)], syncedAt: epoch)
        let collection = GameCollection(name: "Café", gameIDs: [steam])
        try store.saveCollections([collection])
        XCTAssertThrowsError(try store.replaceSourceCatalog(source: steam.source, games: [game(other)]))
        XCTAssertThrowsError(try store.replaceSourceCatalog(source: steam.source, games: [game(steam), game(steam)]))
        XCTAssertThrowsError(try store.saveLibraryState(edits: [steam: GameEdits(isHidden: true)],
            collections: [collection, GameCollection(name: "CAFÉ")], preferences: LibraryPreferences()))
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.collections, [collection])
        XCTAssertFalse(try XCTUnwrap(snapshot.entries.first).edits.isHidden)
        XCTAssertEqual(try store.lastSync(for: steam.source), epoch)
    }
    func testLogoutKeepsLocalInstallsHistoryAndMembershipAndRejectsLateMetadata() throws {
        let store = try CatalogStore()
        let uninstalledID = GameID(source: "steam", value: "1055540")
        try store.replaceSourceCatalog(source: steam.source, games: [game(steam), game(uninstalledID)])
        try store.saveInstallation(installation(game(steam)))
        let collection = GameCollection(name: "Keep", gameIDs: [steam, uninstalledID])
        try store.saveCollections([collection]); try store.saveEdits(GameEdits(note: "Keep this"), for: uninstalledID)
        var session = PlaySessionRecord(gameID: steam, bottleID: "gn-steam-268910", startedAt: epoch)
        session.playedSeconds = 300; session.lastCheckpointAt = epoch.addingTimeInterval(300)
        session.endedAt = session.lastCheckpointAt; session.outcome = .clean
        try store.saveSession(session)
        try store.clearSourceCatalog(steam.source)
        XCTAssertNil(try store.lastSync(for: steam.source))
        XCTAssertFalse(try store.updateMetadata(game(uninstalledID)))
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.entries.map(\.id), [steam])
        XCTAssertEqual(snapshot.entries.first?.localPlaytimeSeconds, 300)
        XCTAssertEqual(snapshot.collections, [collection])
        try store.replaceSourceCatalog(source: steam.source, games: [game(uninstalledID)])
        XCTAssertEqual(try store.snapshot().entries.first { $0.id == uninstalledID }?.edits.note, "Keep this")
    }
    func testCheckpointRestartAndDuplicateFinalizationDoNotChargeDowntime() throws {
        let path = try temporaryPath()
        var session = PlaySessionRecord(gameID: steam, bottleID: "gn-steam-268910", startedAt: epoch)
        session.playedSeconds = 180; session.lastCheckpointAt = epoch.addingTimeInterval(180)
        do {
            let store = try CatalogStore(path: path)
            var record = game(steam); record.importedPlaytimeSeconds = 3600
            try store.replaceSourceCatalog(source: steam.source, games: [record])
            try store.saveSession(session); try store.saveSession(session)
        }
        let store = try CatalogStore(path: path)
        XCTAssertEqual(try store.unfinishedSessions(), [session])
        XCTAssertEqual(try store.snapshot().entries.first?.totalPlaytimeSeconds, 3780)
        let oldCheckpoint = session
        session.endedAt = epoch.addingTimeInterval(86_400); session.outcome = .interrupted
        try store.saveSession(session); try store.saveSession(session); try store.saveSession(oldCheckpoint)
        XCTAssertTrue(try store.unfinishedSessions().isEmpty)
        XCTAssertEqual(try store.snapshot().entries.first?.totalPlaytimeSeconds, 3780)
        XCTAssertEqual(try store.snapshot().entries.first?.lastSession?.outcome, .interrupted)
        var invalid = session; invalid.id = UUID(); invalid.playedSeconds = -1
        XCTAssertThrowsError(try store.saveSession(invalid))
    }
    func testJobsReconstructExactStagePauseReasonsManifestAndQueueAfterRestart() throws {
        let path = try temporaryPath()
        var job = JobRecord(gameID: steam, queuePosition: 2, createdAt: epoch)
        job.state = .running; job.stage = .download; job.completedStages = [.resolve, .estimate, .reserve]
        job.pauseReasons = [.user, .gameplay]; job.manifestIDs = ["268911": "12345678901234567890"]
        job.bytesCompleted = 16_777_216; job.bytesTotal = 1_000_000_000
        let earlier = JobRecord(gameID: other, queuePosition: 1, createdAt: epoch)
        do {
            let store = try CatalogStore(path: path)
            try store.saveJob(job); try store.saveJob(earlier)
        }
        let store = try CatalogStore(path: path)
        XCTAssertEqual(try store.jobs(), [earlier, job])
        var resumed = job; resumed.pauseReasons.remove(.gameplay)
        try store.saveJob(resumed)
        XCTAssertEqual(try store.jobs().last?.pauseReasons, [.user])
        var wrongIdentity = job; wrongIdentity.gameID = other
        XCTAssertThrowsError(try store.saveJob(wrongIdentity))
    }
    func testInstallationCommitAndRemovalDoNotEraseEdits() throws {
        let store = try CatalogStore()
        let install = installation(game(steam))
        var job = JobRecord(gameID: steam); job.state = .completed; job.stage = .finished
        var wrongGame = job; wrongGame.gameID = other
        XCTAssertThrowsError(try store.commitInstallation(install, completing: wrongGame))
        XCTAssertTrue(try store.snapshot().entries.isEmpty)
        XCTAssertTrue(try store.jobs().isEmpty)
        try store.saveEdits(GameEdits(isFavorite: true, note: "keep"), for: steam)
        try store.commitInstallation(install, completing: job)
        XCTAssertEqual(try store.snapshot().entries.first?.installation, install)
        XCTAssertEqual(try store.jobs(), [job])
        try store.removeInstallation(id: install.id)
        try store.replaceSourceCatalog(source: steam.source, games: [game(steam)])
        XCTAssertEqual(try store.snapshot().entries.first?.edits.note, "keep")
    }
    func testStaleMetadataCannotOverwriteNewerDataOrImportedPlaytime() throws {
        let store = try CatalogStore()
        var source = game(steam); source.importedPlaytimeSeconds = 7200
        try store.replaceSourceCatalog(source: steam.source, games: [source])
        var newer = game(steam); newer.summary = "new"; newer.metadataUpdatedAt = epoch.addingTimeInterval(100)
        XCTAssertTrue(try store.updateMetadata(newer))
        var older = newer; older.metadataUpdatedAt = epoch; older.summary = "old"
        XCTAssertFalse(try store.updateMetadata(older))
        XCTAssertEqual(try store.snapshot().entries.first?.source.summary, "new")
        XCTAssertEqual(try store.snapshot().entries.first?.totalPlaytimeSeconds, 7200)
    }
    func testFailuresRedactCredentialsBeforeDatabasePersistence() throws {
        let store = try CatalogStore()
        var job = JobRecord(gameID: steam)
        job.failure = OperationFailure(stage: "Download", reason: "Sign-in expired", output: "Authorization: Bearer secret-a\n{\"refresh_token\":\"secret-b\"} password=secret-c SteamID 76561198000000000")
        try store.saveJob(job)
        let output = try XCTUnwrap(store.jobs().first?.failure?.output)
        for secret in ["secret-a", "secret-b", "secret-c", "76561198000000000"] { XCTAssertFalse(output.contains(secret)) }
        XCTAssertTrue(output.contains("[REDACTED]"))
        let spaced = DiagnosticRedactor.redact(#"{"password":"words with spaces", "account_name":"private user", "guardCode":"12345"}"#)
        for secret in ["words", "spaces", "private", "user\"", "12345"] { XCTAssertFalse(spaced.contains(secret)) }
    }
}
