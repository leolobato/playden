import XCTest
import GRDB
import Domain
@testable import Catalog

final class AppResetTests: XCTestCase {
    private let gameID = GameID(source: "steam", value: "1055540")
    private func fixture() throws -> (URL, CatalogStore, InstallationRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppReset-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let catalog = try CatalogStore(path: root.appendingPathComponent("catalog.sqlite").path)
        let game = SourceGameRecord(id: gameID, title: "A Short Hike")
        let installed = InstallationRecord(game: game, location: .init(volumeID: "fixture", lastKnownRoot: root, relativePath: "game"),
            bottleID: "playden-steam-1055540", manifestIDs: [:], templateVersion: "1", launchSpec: .init(executableRelativePath: "game.exe"), installedBytes: 100)
        try catalog.saveInstallation(installed)
        try catalog.replaceSourceCatalog(source: "steam", games: [game, .init(id: .init(source: "steam", value: "other"), title: "Other game")])
        var preferences = LibraryPreferences(); preferences.reducedMotion = true; preferences.setupCompleted = true
        preferences.selectedDisplayUUID = "fixture-display"; preferences.startInFullscreen = false
        try catalog.saveLibraryState(edits: [gameID: .init(isFavorite: true, isHidden: true, compatibility: .works, note: "Personal note")],
            collections: [.init(name: "Favorites", gameIDs: [gameID])], preferences: preferences)
        return (root, catalog, installed)
    }
    private func payloads(_ catalog: CatalogStore, table: String) throws -> [Data] {
        try catalog.database.read { try Data.fetchAll($0, sql: "SELECT payload FROM \(table) ORDER BY rowid") }
    }

    func testResetKeepsGamesSavesHistoryAndCloudRecoveryByteForByteAcrossRestart() throws {
        let (root, catalog, installed) = try fixture()
        let save = root.appendingPathComponent("GameSaveNew.mountain"), original = root.appendingPathComponent("steam_api.dll.orig")
        try Data("saved progress".utf8).write(to: save); try Data("original library".utf8).write(to: original)
        var session = PlaySessionRecord(gameID: gameID, bottleID: installed.bottleID, startedAt: Date(timeIntervalSince1970: 100))
        session.endedAt = session.startedAt.addingTimeInterval(60); session.lastCheckpointAt = session.endedAt!
        session.outcome = .clean; session.playedSeconds = 60; try catalog.saveSession(session)
        var finished = JobRecord(gameID: gameID); finished.state = .completed; finished.stage = .finished
        try catalog.saveJob(finished); _ = try catalog.dismissJobHistory(finished)
        var paused = JobRecord(gameID: .init(source: "steam", value: "paused"))
        paused.state = .paused; paused.pauseReasons = [.user]; paused.bytesCompleted = 64
        try catalog.saveJob(paused)
        let mapping = SaveMapping(), remote = CloudFileList(gameID: gameID, accountKey: "account-a", revision: 1, files: [])
        let plan = CloudSyncPlan(gameID: gameID, installationID: installed.id, accountKey: "account-a", remoteRevision: 1, decisions: [], requiresAccountConfirmation: false)
        var cloud = try catalog.beginCloudSync(installation: installed, accountKey: "account-a", mapping: mapping)
        cloud = try catalog.stageCloudSync(cloud, plan: plan, remote: remote, localSnapshotID: UUID(), remoteSnapshotID: UUID())
        cloud = try catalog.markCloudApplying(cloud); cloud = try catalog.markCloudLocalApplied(cloud)
        _ = try catalog.completeCloudSync(cloud, baseline: .init(gameID: gameID, installationID: installed.id,
            accountKey: "account-a", revision: 1, mapping: mapping, files: []))
        var pending = try catalog.beginCloudSync(installation: installed, accountKey: "account-a", mapping: mapping)
        pending = try catalog.stageCloudSync(pending, plan: plan, remote: remote, localSnapshotID: UUID(), remoteSnapshotID: UUID())
        pending = try catalog.markCloudApplying(pending)
        _ = try catalog.pauseCloudSync(pending, phase: .pending)
        let tables = ["installations", "jobs", "sessions", "cloud_operations", "cloud_baselines", "cloud_attachments", "diagnostic_logs"]
        let before = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try payloads(catalog, table: $0)) })
        let client = try catalog.cloudClientID()
        try catalog.resetAppData()
        let reopened = try CatalogStore(path: root.appendingPathComponent("catalog.sqlite").path)
        for table in tables { XCTAssertEqual(try payloads(reopened, table: table), before[table], table) }
        XCTAssertEqual(try reopened.cloudClientID(), client)
        XCTAssertEqual(try reopened.preferences(), .init())
        let snapshot = try reopened.snapshot()
        XCTAssertEqual(snapshot.entries.map(\.id), [gameID])
        XCTAssertEqual(snapshot.entries.first?.edits, .init())
        XCTAssertEqual(snapshot.entries.first?.localPlaytimeSeconds, 60)
        XCTAssertTrue(snapshot.collections.isEmpty)
        XCTAssertNil(try reopened.lastSync(for: "steam"))
        XCTAssertTrue(try reopened.jobHistoryDismissals().isEmpty)
        XCTAssertEqual(try reopened.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM collection_members") }, 0)
        XCTAssertEqual(try Data(contentsOf: save), Data("saved progress".utf8))
        XCTAssertEqual(try Data(contentsOf: original), Data("original library".utf8))
    }

    func testFailedResetRollsBackCacheEditsCollectionsAndSettingsTogether() throws {
        let (_, catalog, _) = try fixture()
        let before = try catalog.snapshot(), cached = try payloads(catalog, table: "source_games")
        try catalog.database.write { try $0.execute(sql: "CREATE TRIGGER reject_reset BEFORE DELETE ON game_edits BEGIN SELECT RAISE(ABORT, 'fixture reset failure'); END") }
        XCTAssertThrowsError(try catalog.resetAppData())
        let after = try catalog.snapshot()
        XCTAssertEqual(after.entries, before.entries); XCTAssertEqual(after.collections, before.collections)
        XCTAssertEqual(after.preferences, before.preferences)
        XCTAssertEqual(try payloads(catalog, table: "source_games"), cached)
    }

    func testActiveWritersAndUnpausedJobsRejectResetWithoutChanges() throws {
        for kind in ["session", "queued", "running", "gameplay-pause", "cloud", "uninstall"] {
            let (_, catalog, installed) = try fixture()
            if kind == "session" { try catalog.saveSession(.init(gameID: gameID, bottleID: installed.bottleID)) }
            else if kind == "cloud" { _ = try catalog.beginCloudSync(installation: installed, accountKey: "a", mapping: .init()) }
            else if kind == "uninstall" {
                _ = try catalog.beginUninstall(.init(review: catalog.reviewUninstall(gameID), discardUnsyncedProgress: true))
            }
            else {
                var job = JobRecord(gameID: .init(source: "steam", value: "job"))
                if kind == "running" { job.state = .running }
                if kind == "gameplay-pause" { job.state = .paused; job.pauseReasons = [.gameplay] }
                try catalog.saveJob(job)
            }
            let before = try catalog.snapshot()
            XCTAssertThrowsError(try catalog.checkAppReset(), kind)
            XCTAssertThrowsError(try catalog.resetAppData(), kind)
            XCTAssertEqual(try catalog.snapshot().entries, before.entries, kind)
            XCTAssertEqual(try catalog.preferences(), before.preferences, kind)
        }
    }
}
