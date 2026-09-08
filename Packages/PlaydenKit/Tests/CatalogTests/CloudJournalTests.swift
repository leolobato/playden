import XCTest
import Domain
@testable import Catalog

final class CloudJournalTests: XCTestCase {
    func testArchiveRecoveryCannotAuthorizeSteamAndReplacementKeepsDurableSnapshot() throws {
        let databasePath = try path(), store = try CatalogStore(path: databasePath), installed = installation
        try store.saveInstallation(installed)
        var operation = try store.beginCloudSync(installation: installed, accountKey: "unattached", mapping: mapping)
        let originalID = UUID()
        operation = try store.recordCloudLocalSnapshot(operation, snapshotID: originalID)
        let location = CloudSavePath(root: .bottle, path: "saves/GameSaveNew.mountain")
        let plan = CloudSyncPlan(gameID: gameID, installationID: installed.id, accountKey: "unattached", remoteRevision: 0,
            decisions: [.init(name: file.name, location: location, action: .upload,
                local: .init(location: location, sha1: file.sha1, bytes: file.bytes, modifiedAt: file.modifiedAt), remote: nil)],
            requiresAccountConfirmation: false)
        XCTAssertThrowsError(try store.requireCloudArchiveRecovery(operation,
            input: .init(plan: plan, localSnapshotID: UUID(), remoteSnapshotID: UUID())))
        operation = try store.requireCloudArchiveRecovery(operation,
            input: .init(plan: plan, localSnapshotID: originalID, remoteSnapshotID: UUID()))
        XCTAssertThrowsError(try store.replaceCloudSync(operation, installation: installed, localSnapshotID: UUID()))
        XCTAssertThrowsError(try store.confirmCloudAccount(operation))
        XCTAssertThrowsError(try store.recordCloudBatch(operation, batch: .init(id: 42, revision: 1)))
        XCTAssertThrowsError(try store.markCloudApplying(operation))
        operation = try store.stageCloudLocalRecovery(operation,
            recovery: .init(localSnapshotID: UUID(), remoteSnapshotID: UUID(), plan: plan))
        operation = try store.authorizeCloudLocalRecovery(operation)
        operation = try store.markCloudLocalApplied(operation)
        XCTAssertThrowsError(try store.confirmCloudAccount(operation))
        XCTAssertNil(operation.plan); XCTAssertNil(operation.remote); XCTAssertEqual(operation.localSnapshotID, originalID)
        let unchanged = try store.cloudOperations()
        var foreign = installed; foreign.ownershipToken = UUID()
        XCTAssertThrowsError(try store.replaceCloudSync(operation, installation: foreign, localSnapshotID: UUID()))
        XCTAssertEqual(try store.cloudOperations(), unchanged)
        let freshID = UUID()
        let next = try store.replaceCloudSync(operation, installation: installed, localSnapshotID: freshID)
        let reopened = try CatalogStore(path: databasePath), saved = try reopened.cloudOperations()
        XCTAssertEqual(saved.filter { !$0.phase.isTerminal }, [next]); XCTAssertEqual(next.localSnapshotID, freshID)
        XCTAssertEqual(saved.first { $0.id == operation.id }?.localSnapshotID, originalID)
        XCTAssertThrowsError(try reopened.pauseCloudSync(operation, phase: .failed))
        XCTAssertNil(try reopened.cloudAttachment(for: gameID, installationID: installed.id))
        XCTAssertNil(try reopened.cloudBaseline(for: gameID, accountKey: "unattached"))
    }
    private let gameID = GameID(source: "steam", value: "1055540")
    private let mapping = SaveMapping(rules: [.init(root: .bottle, directory: "saves", pattern: "*.mountain", cloudPrefix: "%GameInstall%saves")], coverage: .metadata)
    private var installation: InstallationRecord {
        .init(game: .init(id: gameID, title: "A Short Hike"),
              location: .init(volumeID: "fixture", lastKnownRoot: URL(fileURLWithPath: "/fixture"), relativePath: "game"),
              bottleID: "gn-steam-1055540", manifestIDs: [:], templateVersion: "1",
              launchSpec: .init(executableRelativePath: "ShortHike.exe"), installedBytes: 100)
    }
    private var file: CloudFile {
        .init(name: "%GameInstall%saves/GameSaveNew.mountain", sha1: Data(repeating: 1, count: 20), bytes: 100,
              modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private func path() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudJournal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("catalog.sqlite").path
    }
    private func stage(_ store: CatalogStore, _ operation: CloudSyncOperation,
                       confirmation: Bool = false, action: CloudSyncDecision.Action = .download) throws -> CloudSyncOperation {
        let location = CloudSavePath(root: .bottle, path: "saves/GameSaveNew.mountain")
        let local: CloudLocalFile? = action == .download ? nil : .init(location: location, sha1: file.sha1, bytes: file.bytes, modifiedAt: file.modifiedAt)
        let remote = CloudFileList(gameID: gameID, accountKey: operation.accountKey, revision: 5, files: [file])
        let plan = CloudSyncPlan(gameID: gameID, installationID: operation.installationID, accountKey: operation.accountKey,
            remoteRevision: 5, decisions: [.init(name: file.name, location: location, action: action, local: local, remote: file)],
            requiresAccountConfirmation: confirmation)
        return try store.stageCloudSync(operation, plan: plan, remote: remote, localSnapshotID: UUID(), remoteSnapshotID: UUID())
    }
    private func baseline(_ operation: CloudSyncOperation, revision: UInt64 = 5, files: [CloudFile]? = nil) -> CloudSyncBaseline {
        .init(gameID: gameID, installationID: operation.installationID, accountKey: operation.accountKey,
              revision: revision, mapping: mapping, files: files ?? [file])
    }
    private func session(_ installed: InstallationRecord) -> PlaySessionRecord {
        .init(gameID: gameID, bottleID: installed.bottleID)
    }
    private func repair(_ installed: InstallationRecord) -> JobRecord {
        var job = JobRecord(gameID: gameID, kind: .repair)
        job.originalInstallation = installed; job.ownershipToken = installed.ownershipToken
        return job
    }

    func testReceiptsAndClaimsSurviveRestartAndRequireExplicitRecovery() throws {
        let databasePath = try path(), installed = installation
        let store = try CatalogStore(path: databasePath)
        try store.saveInstallation(installed)
        var operation = try stage(store, store.beginCloudSync(installation: installed, accountKey: "account-a", mapping: mapping), action: .upload)
        operation = try store.confirmCloudAccount(operation)
        operation = try store.recordCloudBatch(operation, batch: .init(id: 42, revision: 6))
        let reopened = try CatalogStore(path: databasePath)
        XCTAssertEqual(try reopened.cloudOperations(), [operation])
        XCTAssertThrowsError(try reopened.saveSession(session(installed)))
        XCTAssertThrowsError(try reopened.resumeCloudSync(operation))
        let interrupted = try reopened.recoverInterruptedCloudSync(operation)
        XCTAssertNil(interrupted.claim)
        XCTAssertEqual(interrupted.batches, [.init(id: 42, revision: 6)])
        XCTAssertEqual(interrupted.localSnapshotID, operation.localSnapshotID)
        XCTAssertEqual(interrupted.remoteSnapshotID, operation.remoteSnapshotID)
        XCTAssertNil(try reopened.cloudBaseline(for: gameID, accountKey: "account-a"))
        let resumed = try reopened.resumeCloudSync(interrupted)
        XCTAssertNotEqual(resumed.claim, operation.claim)
        XCTAssertThrowsError(try store.recordCloudBatch(operation, batch: .init(id: 43, revision: 7))) {
            XCTAssertEqual($0 as? CloudJournalError, .staleAttempt)
        }
        XCTAssertEqual(try reopened.cloudOperations().first, resumed)
    }

    func testLocalRecoveryReviewIsDurableFencedAndCannotAdvanceCloudBaseline() throws {
        let database = try path(), installed = installation, store = try CatalogStore(path: database)
        try store.saveInstallation(installed)
        var operation = try stage(store, store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping))
        operation = try store.markCloudApplying(operation)
        let initial = operation
        let location = CloudSavePath(root: .bottle, path: "saves/GameSaveNew.mountain")
        let local = CloudLocalFile(location: location, sha1: Data(repeating: 2, count: 20), bytes: 200, modifiedAt: .now)
        let plan = CloudSyncPlan(gameID: gameID, installationID: installed.id, accountKey: "a", remoteRevision: 5,
            decisions: [.init(name: file.name, location: location, action: .conflict, local: local, remote: file)], requiresAccountConfirmation: false)
        let review = CloudLocalRecovery(localSnapshotID: UUID(), remoteSnapshotID: UUID(), plan: plan)
        operation = try store.stageCloudLocalRecovery(operation, recovery: review)
        XCTAssertThrowsError(try store.authorizeCloudLocalRecovery(operation))
        XCTAssertThrowsError(try store.markCloudApplying(operation))
        operation = try store.pauseCloudSync(operation, phase: .conflict)
        let reopened = try CatalogStore(path: database)
        XCTAssertEqual(try reopened.cloudOperations().first?.localRecoveries, [review])
        operation = try reopened.resumeCloudSync(operation)
        let obsolete = operation
        operation = try reopened.authorizeCloudLocalRecovery(operation, choice: .remote)
        XCTAssertThrowsError(try store.authorizeCloudLocalRecovery(obsolete, choice: .local)) {
            XCTAssertEqual($0 as? CloudJournalError, .staleAttempt)
        }
        XCTAssertEqual(operation.localSnapshotID, initial.localSnapshotID)
        XCTAssertEqual(operation.remoteSnapshotID, initial.remoteSnapshotID)
        XCTAssertEqual(operation.plan, initial.plan)
        XCTAssertEqual(operation.localRecoveries?.last?.appliedPlan?.decisions.first?.action, .download)
        operation = try reopened.markCloudLocalApplied(operation)
        XCTAssertThrowsError(try reopened.completeCloudSync(operation, baseline: baseline(operation)))
        XCTAssertNil(try reopened.cloudBaseline(for: gameID, accountKey: "a"))
        operation = try reopened.supersedeCloudSync(operation)
        XCTAssertEqual(operation.phase, .superseded)
        XCTAssertEqual(operation.localRecoveries?.count, 1)
    }

    func testRecoveryPreparationReservationCannotStartWriterOrChangeInstallationIdentity() throws {
        let installed = installation, store = try CatalogStore()
        try store.saveInstallation(installed)
        var operation = try stage(store, store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping))
        operation = try store.markCloudApplying(operation)
        let preparing = session(installed)
        XCTAssertThrowsError(try store.reserveCloudRecoverySession(preparing, operation: operation), "A live worker must retain its claim")
        operation = try store.recoverInterruptedCloudSync(operation)
        XCTAssertThrowsError(try store.saveSession(preparing))
        try store.reserveCloudRecoverySession(preparing, operation: operation)
        XCTAssertThrowsError(try store.reserveCloudRecoverySession(session(installed), operation: operation))
        XCTAssertThrowsError(try store.checkCloudBeforeLaunch(preparing))
        var prepared = installed; prepared.launchSpec = .init(executableRelativePath: "rebuilt.exe"); prepared.staging = .init(version: 2); prepared.stagingVersion = 2
        XCTAssertThrowsError(try store.saveInstallation(prepared))
        var wrong = prepared; wrong.installedBytes += 1
        XCTAssertThrowsError(try store.saveCloudRecoveryPreparation(wrong, replacing: installed, sessionID: preparing.id))
        wrong = prepared; wrong.stagingVersion = 3
        XCTAssertThrowsError(try store.saveCloudRecoveryPreparation(wrong, replacing: installed, sessionID: preparing.id))
        XCTAssertThrowsError(try store.saveCloudRecoveryPreparation(prepared, replacing: installed, sessionID: UUID()))
        try store.saveCloudRecoveryPreparation(prepared, replacing: installed, sessionID: preparing.id)
        XCTAssertEqual(try store.snapshot().entries.first?.installation, prepared)
        operation = try store.resumeCloudSync(operation, preparingSessionID: preparing.id)
        XCTAssertThrowsError(try store.saveCloudRecoveryPreparation(prepared, replacing: prepared, sessionID: preparing.id))
        operation = try store.markCloudApplying(operation)
        operation = try store.markCloudLocalApplied(operation)
        _ = try store.supersedeCloudSync(operation)
        XCTAssertNoThrow(try store.checkCloudBeforeLaunch(preparing))
    }

    func testSessionAndMaintenanceClaimsExcludeCloudInBothDirections() throws {
        let installed = installation, store = try CatalogStore()
        try store.saveInstallation(installed)
        var operation = try store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping)
        XCTAssertThrowsError(try store.saveSession(session(installed)))
        XCTAssertThrowsError(try store.enqueueRepair(repair(installed)))
        XCTAssertThrowsError(try store.saveJob(repair(installed)))
        // Queue reordering also checkpoints historical completed jobs. Those records do not
        // claim maintenance or touch the game's files and must not block unrelated downloads.
        var historical = repair(installed); historical.state = .completed; historical.stage = .finished
        try store.saveJobs([historical])
        historical.queuePosition = 4; try store.saveJobs([historical])
        XCTAssertEqual(try store.jobs().first?.queuePosition, 4)
        XCTAssertThrowsError(try store.saveInstallation(installed))
        XCTAssertThrowsError(try store.removeInstallation(id: installed.id))
        XCTAssertThrowsError(try store.beginCloudSync(installation: installed, accountKey: "b", mapping: mapping))
        operation = try store.supersedeCloudSync(operation)
        XCTAssertEqual(operation.phase, .superseded)
        var playing = session(installed)
        try store.saveSession(playing)
        XCTAssertThrowsError(try store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping))
        XCTAssertThrowsError(try store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping, preparingSessionID: UUID()))
        operation = try store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping, preparingSessionID: playing.id)
        var launched = playing
        launched.runtime = .init(run: .init(bottle: .init(gameID: gameID, name: installed.bottleID,
            ownershipToken: installed.ownershipToken, templateVersion: installed.templateVersion),
            launcher: .init(pid: 123, startSeconds: 1, startMicroseconds: 0)))
        XCTAssertThrowsError(try store.saveSession(launched))
        operation = try store.supersedeCloudSync(operation)
        try store.saveSession(launched)
        XCTAssertThrowsError(try store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping, preparingSessionID: playing.id))
        playing.endedAt = playing.startedAt; playing.outcome = .clean
        try store.saveSession(playing)
        try store.enqueueRepair(repair(installed))
        XCTAssertThrowsError(try store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping))
    }

    func testPendingNetworkWorkAllowsOfflinePlayButPartialLocalApplicationDoesNot() throws {
        let installed = installation, store = try CatalogStore()
        try store.saveInstallation(installed)
        var operation = try stage(store, store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping))
        operation = try store.pauseCloudSync(operation, phase: .pending)
        XCTAssertThrowsError(try store.removeInstallation(id: installed.id))
        var playing = session(installed)
        try store.saveSession(playing)
        XCTAssertThrowsError(try store.resumeCloudSync(operation))
        playing.endedAt = playing.startedAt; playing.outcome = .clean; try store.saveSession(playing)
        operation = try store.resumeCloudSync(operation)
        // A resumed staged download is re-verified before starting local application.
        operation = try store.markCloudVerifying(operation)
        operation = try store.completeCloudSync(operation, baseline: baseline(operation))
        operation = try stage(store, store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping))
        operation = try store.markCloudApplying(operation)
        operation = try store.pauseCloudSync(operation, phase: .failed)
        XCTAssertTrue(operation.needsLocalRecovery)
        XCTAssertThrowsError(try store.saveSession(session(installed)))
        XCTAssertThrowsError(try store.enqueueRepair(repair(installed)))
        operation = try store.resumeCloudSync(operation)
        XCTAssertThrowsError(try store.supersedeCloudSync(operation))
        operation = try store.markCloudApplying(operation)
        operation = try store.markCloudVerifying(operation)
        let finished = try store.completeCloudSync(operation, baseline: baseline(operation))
        XCTAssertFalse(finished.needsLocalRecovery)
        try store.saveSession(session(installed))
    }

    func testBaselineCompletionIsAtomicValidatedAndAccountScopedAcrossLogout() throws {
        let installed = installation, databasePath = try path(), store = try CatalogStore(path: databasePath)
        try store.saveInstallation(installed)
        var operation = try stage(store, store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping))
        XCTAssertThrowsError(try store.completeCloudSync(operation, baseline: baseline(operation)))
        operation = try store.markCloudVerifying(operation)
        XCTAssertThrowsError(try store.completeCloudSync(operation, baseline: baseline(operation, revision: 4)))
        XCTAssertThrowsError(try store.completeCloudSync(operation, baseline: baseline(operation, files: [])))
        let wrongAccount = CloudSyncBaseline(gameID: gameID, installationID: installed.id, accountKey: "b",
            revision: 5, mapping: mapping, files: [file])
        XCTAssertThrowsError(try store.completeCloudSync(operation, baseline: wrongAccount))
        XCTAssertNil(try store.cloudBaseline(for: gameID, accountKey: "a"))
        XCTAssertNil(try store.cloudAttachment(for: gameID, installationID: installed.id))
        XCTAssertEqual(try store.cloudOperations().first, operation)
        let expectedBaseline = baseline(operation)
        operation = try store.completeCloudSync(operation, baseline: expectedBaseline)
        try store.clearSourceCatalog("steam")
        let reopened = try CatalogStore(path: databasePath)
        XCTAssertEqual(try reopened.cloudBaseline(for: gameID, accountKey: "a"), expectedBaseline)
        XCTAssertNil(try reopened.cloudBaseline(for: gameID, accountKey: "b"))
        XCTAssertEqual(try reopened.cloudAttachment(for: gameID, installationID: installed.id)?.accountKey, "a")
        XCTAssertNil(try reopened.cloudAttachment(for: gameID, installationID: UUID()))
        XCTAssertEqual(try reopened.cloudOperations(), [operation])
        XCTAssertThrowsError(try reopened.recordCloudBatch(operation, batch: .init(id: 5, revision: 6)))
    }

    func testAccountSwitchRequiresConsentAndPreservesPriorAccountBaseline() throws {
        let installed = installation, store = try CatalogStore()
        try store.saveInstallation(installed)
        var operation = try stage(store, store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping))
        operation = try store.markCloudVerifying(operation)
        let first = baseline(operation)
        _ = try store.completeCloudSync(operation, baseline: first)
        operation = try stage(store, store.beginCloudSync(installation: installed, accountKey: "b", mapping: mapping), confirmation: true, action: .upload)
        XCTAssertThrowsError(try store.recordCloudBatch(operation, batch: .init(id: 10, revision: 6))) {
            XCTAssertEqual($0 as? CloudJournalError, .accountConfirmationRequired)
        }
        XCTAssertThrowsError(try store.markCloudApplying(operation))
        operation = try store.confirmCloudAccount(operation)
        operation = try store.recordCloudBatch(operation, batch: .init(id: 10, revision: 6))
        XCTAssertThrowsError(try store.confirmCloudAccount(operation))
        operation = try store.markCloudVerifying(operation)
        XCTAssertThrowsError(try store.completeCloudSync(operation, baseline: baseline(operation)))
        _ = try store.completeCloudSync(operation, baseline: baseline(operation, revision: 6))
        XCTAssertEqual(try store.cloudBaseline(for: gameID, accountKey: "a"), first)
        XCTAssertEqual(try store.cloudBaseline(for: gameID, accountKey: "b")?.revision, 6)
    }

    func testUnresolvedConflictAndItsSnapshotsCannotBeOverwrittenOrExecuted() throws {
        let installed = installation, store = try CatalogStore()
        try store.saveInstallation(installed)
        var operation = try stage(store, store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping), action: .conflict)
        let staged = operation
        XCTAssertEqual(operation.phase, .conflict)
        XCTAssertThrowsError(try stage(store, operation))
        XCTAssertThrowsError(try store.markCloudApplying(operation))
        XCTAssertThrowsError(try store.recordCloudBatch(operation, batch: .init(id: 1, revision: 6)))
        XCTAssertThrowsError(try store.markCloudVerifying(operation))
        operation = try store.pauseCloudSync(operation, phase: .conflict)
        XCTAssertThrowsError(try store.beginCloudSync(installation: installed, accountKey: "b", mapping: mapping))
        operation = try store.resumeCloudSync(operation)
        operation = try store.supersedeCloudSync(operation)
        let next = try store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping)
        XCTAssertNotEqual(next.id, operation.id)
        XCTAssertEqual(operation.localSnapshotID, staged.localSnapshotID)
        XCTAssertEqual(operation.remoteSnapshotID, staged.remoteSnapshotID)
        XCTAssertEqual(try store.cloudOperations().count, 2)
    }

    func testRecoveryAfterSessionFinalizationFencesOldPrelaunchWorker() throws {
        let installed = installation, store = try CatalogStore()
        try store.saveInstallation(installed)
        var playing = session(installed); try store.saveSession(playing)
        let old = try store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping, preparingSessionID: playing.id)
        playing.endedAt = playing.startedAt; playing.outcome = .interrupted
        try store.saveSession(playing)
        let recovered = try store.recoverInterruptedCloudSync(old)
        XCTAssertNil(recovered.claim)
        XCTAssertThrowsError(try store.confirmCloudAccount(old))
        _ = try store.resumeCloudSync(recovered)
    }

    func testInstallationAndReviewIdentitiesCannotBeSubstituted() throws {
        let installed = installation, store = try CatalogStore()
        try store.saveInstallation(installed)
        var wrong = installed; wrong.ownershipToken = UUID()
        XCTAssertThrowsError(try store.beginCloudSync(installation: wrong, accountKey: "a", mapping: mapping))
        wrong = installed; wrong.location.relativePath = "different"
        XCTAssertThrowsError(try store.beginCloudSync(installation: wrong, accountKey: "a", mapping: mapping))
        let operation = try store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping)
        let staged = try stage(store, operation)
        let remote = CloudFileList(gameID: gameID, accountKey: "b", revision: 5, files: [file])
        XCTAssertThrowsError(try store.stageCloudSync(staged, plan: XCTUnwrap(staged.plan), remote: remote,
                                                     localSnapshotID: UUID(), remoteSnapshotID: UUID()))
        var forged = staged; forged.claim = UUID()
        XCTAssertThrowsError(try store.markCloudVerifying(forged)) {
            XCTAssertEqual($0 as? CloudJournalError, .staleAttempt)
        }
        XCTAssertEqual(try store.cloudOperations(), [staged])
    }

    func testCompetingLaunchAndCloudTransactionsHaveExactlyOneWinner() async throws {
        for _ in 0..<20 {
            let store = try CatalogStore(), installed = installation, mapping = mapping
            let playing = session(installed)
            try store.saveInstallation(installed)
            let wins = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    do { try store.saveSession(playing); return true } catch { return false }
                }
                group.addTask {
                    do { _ = try store.beginCloudSync(installation: installed, accountKey: "a", mapping: mapping); return true }
                    catch { return false }
                }
                var count = 0
                for await won in group { if won { count += 1 } }
                return count
            }
            XCTAssertEqual(wins, 1)
        }
    }
}
