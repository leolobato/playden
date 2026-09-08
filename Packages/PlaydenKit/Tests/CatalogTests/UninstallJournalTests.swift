import XCTest
import Domain
@testable import Catalog

final class UninstallJournalTests: XCTestCase {
    private let id = GameID(source: "steam", value: "1055540")
    private func installed(_ store: CatalogStore) throws -> InstallationRecord {
        let game = SourceGameRecord(id: id, title: "A Short Hike")
        let value = InstallationRecord(game: game,
            location: .init(volumeID: "fixture", lastKnownRoot: URL(fileURLWithPath: "/fixture"), relativePath: "playden-steam-1055540/game"),
            bottleID: "playden-steam-1055540", manifestIDs: [:], templateVersion: "1",
            launchSpec: .init(executableRelativePath: "game.exe"), installedBytes: 100)
        try store.replaceSourceCatalog(source: "steam", games: [game]); try store.saveInstallation(value)
        return value
    }
    private func staged(_ store: CatalogStore, _ installed: InstallationRecord) throws -> CloudSyncOperation {
        let operation = try store.beginCloudSync(installation: installed, accountKey: "fixture-account", mapping: .init())
        return try store.stageCloudSync(operation,
            plan: .init(gameID: id, installationID: installed.id, accountKey: operation.accountKey, remoteRevision: 1, decisions: [], requiresAccountConfirmation: false),
            remote: .init(gameID: id, accountKey: operation.accountKey, revision: 1, files: []),
            localSnapshotID: UUID(), remoteSnapshotID: UUID())
    }
    @discardableResult private func synced(_ store: CatalogStore, _ installed: InstallationRecord) throws -> CloudSyncOperation {
        var operation = try staged(store, installed)
        operation = try store.markCloudVerifying(operation)
        return try store.completeCloudSync(operation, baseline: .init(gameID: id, installationID: installed.id,
            accountKey: operation.accountKey, revision: 1, mapping: .init(), files: []))
    }
    private func authorization(_ store: CatalogStore, discard: Bool = false) throws -> UninstallAuthorization {
        .init(review: try store.reviewUninstall(id), discardUnsyncedProgress: discard)
    }

    func testUnsyncedRemovalRequiresExplicitDiscardAndKeepsCloudHistory() throws {
        let store = try CatalogStore(), installation = try installed(store)
        var cloud = try staged(store, installation)
        cloud = try store.pauseCloudSync(cloud, phase: .conflict)
        let review = try store.reviewUninstall(id)
        XCTAssertTrue(review.requiresDiscardConfirmation)
        XCTAssertThrowsError(try store.beginUninstall(.init(review: review, discardUnsyncedProgress: false)))
        XCTAssertEqual(try store.cloudOperations(), [cloud]); XCTAssertTrue(try store.jobs().isEmpty)
        let job = try store.beginUninstall(.init(review: review, discardUnsyncedProgress: true))
        XCTAssertEqual(job.uninstallAuthorization?.review, review)
        let retired = try XCTUnwrap(store.cloudOperations().first)
        XCTAssertEqual(retired.phase, .superseded); XCTAssertEqual(retired.version, cloud.version + 1)
        XCTAssertEqual(retired.localSnapshotID, cloud.localSnapshotID)
        XCTAssertEqual(retired.remoteSnapshotID, cloud.remoteSnapshotID)
        XCTAssertNil(try store.cloudBaseline(for: id, accountKey: cloud.accountKey))
        XCTAssertThrowsError(try store.resumeCloudSync(cloud))
        XCTAssertEqual(try store.snapshot().entries.first?.installation, installation)
    }

    func testConsentCannotDiscardActiveSyncOrPartiallyAppliedLocalSaves() throws {
        let store = try CatalogStore(), installation = try installed(store)
        let before = try authorization(store, discard: true)
        var cloud = try staged(store, installation)
        XCTAssertThrowsError(try store.reviewUninstall(id))
        XCTAssertThrowsError(try store.beginUninstall(before))
        cloud = try store.markCloudApplying(cloud)
        cloud = try store.pauseCloudSync(cloud, phase: .failed)
        XCTAssertTrue(cloud.needsLocalRecovery)
        XCTAssertThrowsError(try store.reviewUninstall(id))
        XCTAssertThrowsError(try store.beginUninstall(before))
        XCTAssertEqual(try store.cloudOperations(), [cloud]); XCTAssertTrue(try store.jobs().isEmpty)
    }

    func testNewPlaySyncOrInstallationInvalidatesDisplayedConsent() throws {
        let store = try CatalogStore(), installation = try installed(store)
        var old = try authorization(store, discard: true)
        var session = PlaySessionRecord(gameID: id, bottleID: installation.bottleID)
        try store.saveSession(session)
        XCTAssertThrowsError(try store.beginUninstall(old))
        session.endedAt = session.startedAt; session.outcome = .clean; try store.saveSession(session)
        XCTAssertThrowsError(try store.beginUninstall(old))
        old = try authorization(store, discard: true)
        try synced(store, installation)
        XCTAssertThrowsError(try store.beginUninstall(old))
        old = try authorization(store)
        var changed = installation; changed.installedBytes += 1; try store.saveInstallation(changed)
        XCTAssertThrowsError(try store.beginUninstall(old))
        XCTAssertTrue(try store.jobs().isEmpty)
    }

    func testFreshSyncIsRequiredAfterOfflinePlayEvenWhenOlderSyncWasGreen() throws {
        let store = try CatalogStore(), installation = try installed(store)
        let completed = try synced(store, installation)
        XCTAssertFalse(try store.reviewUninstall(id).requiresDiscardConfirmation)
        let when = completed.updatedAt.addingTimeInterval(1)
        var session = PlaySessionRecord(gameID: id, bottleID: installation.bottleID, startedAt: when)
        session.endedAt = when; session.outcome = .clean; try store.saveSession(session)
        XCTAssertTrue(try store.reviewUninstall(id).requiresDiscardConfirmation)
        XCTAssertThrowsError(try store.beginUninstall(authorization(store)))
    }

    func testReservationBlocksGenericMutationAndCannotBeForgedOrCancelled() throws {
        let store = try CatalogStore(), installation = try installed(store)
        XCTAssertThrowsError(try store.saveJob(.init(gameID: id, kind: .uninstall)))
        try synced(store, installation)
        let job = try store.beginUninstall(authorization(store))
        XCTAssertThrowsError(try store.saveSession(.init(gameID: id, bottleID: installation.bottleID)))
        XCTAssertThrowsError(try store.saveInstallation(installation))
        XCTAssertThrowsError(try store.removeInstallation(id: installation.id))
        XCTAssertThrowsError(try store.beginCloudSync(installation: installation, accountKey: "a", mapping: .init()))
        XCTAssertThrowsError(try store.saveJob(.init(gameID: id, kind: .repair)))
        var forged = job; forged.state = .cancelled
        XCTAssertThrowsError(try store.saveJob(forged))
        forged = job; forged.kind = .install; forged.uninstallAuthorization = nil
        XCTAssertThrowsError(try store.saveJobs([forged]))
        var reordered = job; reordered.queuePosition = 42
        try store.saveJobs([reordered]); XCTAssertEqual(try store.jobs().first?.queuePosition, 42)
        XCTAssertThrowsError(try store.checkpointUninstall(job, stage: .removeFiles, state: .running, completedStages: []))
    }

    func testInterruptedRemovalResumesWithSameOwnershipAndCompletesAtomically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UninstallJournal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("catalog.sqlite").path
        let store = try CatalogStore(path: path), installation = try installed(store)
        try store.saveEdits(.init(isFavorite: true, compatibility: .works), for: id)
        let collection = GameCollection(name: "Keep", gameIDs: [id])
        try store.saveLibraryState(edits: [id: .init(isFavorite: true, compatibility: .works)], collections: [collection], preferences: .init())
        var played = PlaySessionRecord(gameID: id, bottleID: installation.bottleID, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        played.playedSeconds = 120; played.endedAt = played.startedAt; played.outcome = .clean; try store.saveSession(played)
        let cloud = try synced(store, installation)
        var job = try store.beginUninstall(authorization(store))
        XCTAssertThrowsError(try store.completeUninstall(job))
        XCTAssertThrowsError(try store.checkpointUninstall(job, stage: .commit, state: .running, completedStages: [.removeBottle]))
        job = try store.checkpointUninstall(job, stage: .removeBottle, state: .failed, completedStages: [.removeFiles],
            failure: .init(stage: "Game runtime", reason: "Retry removal", output: ""))
        let reopened = try CatalogStore(path: path)
        XCTAssertEqual(try reopened.jobs().first, job)
        XCTAssertEqual(job.originalInstallation, installation)
        XCTAssertThrowsError(try reopened.saveSession(.init(gameID: id, bottleID: installation.bottleID)))
        let stale = job
        job = try reopened.checkpointUninstall(job, stage: .commit, state: .running, completedStages: [.removeFiles, .removeBottle])
        XCTAssertThrowsError(try reopened.completeUninstall(stale))
        job = try reopened.completeUninstall(job)
        XCTAssertEqual(job.state, .completed)
        let entry = try XCTUnwrap(reopened.snapshot().entries.first)
        XCTAssertNil(entry.installation); XCTAssertTrue(entry.edits.isFavorite)
        XCTAssertEqual(entry.edits.compatibility, .works); XCTAssertEqual(entry.totalPlaytimeSeconds, 120)
        XCTAssertEqual(try reopened.snapshot().collections, [collection])
        XCTAssertEqual(try reopened.cloudOperations(), [cloud])
        XCTAssertNotNil(try reopened.cloudBaseline(for: id, accountKey: cloud.accountKey))
        XCTAssertThrowsError(try reopened.completeUninstall(job))
        var reinstalled = installation; reinstalled.id = UUID(); reinstalled.ownershipToken = UUID()
        try reopened.saveInstallation(reinstalled)
        XCTAssertThrowsError(try reopened.completeUninstall(stale))
        XCTAssertEqual(try reopened.snapshot().entries.first?.installation, reinstalled)
    }
}
