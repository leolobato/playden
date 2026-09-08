import Foundation
import Domain
import GRDB

extension CatalogStore {
    public func reviewUninstall(_ gameID: GameID) throws -> UninstallReview {
        try database.read { try Self.uninstallReview($0, gameID: gameID) }
    }

    /// Commits consent, retires explicitly discarded pending Cloud work, and reserves maintenance
    /// in one transaction. No filesystem or remote save mutation is performed by the journal.
    public func beginUninstall(_ authorization: UninstallAuthorization, queuePosition: Int = 0) throws -> JobRecord {
        try database.write { db in
            let review = authorization.review, installed = review.installation
            guard try Self.uninstallReview(db, gameID: installed.gameID) == review else {
                throw Self.uninstallFailure("The game or its saves changed. Review uninstall again.")
            }
            guard !review.requiresDiscardConfirmation || authorization.discardUnsyncedProgress else {
                throw Self.uninstallFailure("Sync this game's saves or explicitly discard unsynced local progress before uninstalling.")
            }
            for var operation in review.cloudOperations where !operation.phase.isTerminal {
                // reviewUninstall rejects active writers and local recovery, even with consent.
                guard authorization.discardUnsyncedProgress, operation.claim == nil, !operation.needsLocalRecovery,
                      operation.version < Int64.max else { throw CloudJournalError.unresolvedAttempt }
                operation.phase = .superseded; operation.version += 1; operation.updatedAt = .now
                operation.failure = .init(stage: "Uninstall", reason: "Unsynced local progress was explicitly discarded during uninstall.", output: "")
                operation.preparingSessionID = nil
                try Self.putOperation(db, table: "cloud_operations", id: operation.id, gameID: installed.gameID, value: operation)
            }
            var job = JobRecord(gameID: installed.gameID, kind: .uninstall, queuePosition: queuePosition)
            job.stage = .removeFiles; job.originalInstallation = installed; job.uninstallAuthorization = authorization
            job.ownershipToken = installed.ownershipToken; job.location = installed.location
            job.bottle = .init(gameID: installed.gameID, name: installed.bottleID,
                ownershipToken: installed.ownershipToken, templateVersion: installed.templateVersion)
            job.bytesTotal = installed.installedBytes
            try Self.putOperation(db, table: "jobs", id: job.id, gameID: job.gameID, value: job)
            return job
        }
    }

    /// CAS checkpoints survive restart without trusting a worker that holds an obsolete receipt.
    /// A failed or paused removal remains an unfinished job and continues to block play/sync.
    public func checkpointUninstall(_ expected: JobRecord, stage: JobStage, state: JobState,
                                    completedStages: Set<JobStage>, failure: OperationFailure? = nil) throws -> JobRecord {
        try database.write { db in
            let old = try Self.currentUninstall(db, expected)
            let stages: Set<JobStage> = [.removeFiles, .removeBottle]
            guard [.removeFiles, .removeBottle, .commit].contains(stage),
                  [.queued, .running, .paused, .failed].contains(state),
                  completedStages.isSubset(of: stages), old.completedStages.isSubset(of: completedStages),
                  !completedStages.contains(.removeBottle) || completedStages.contains(.removeFiles),
                  stage != .removeBottle || completedStages.contains(.removeFiles),
                  stage != .commit || completedStages == stages else { throw CatalogError.identityMismatch }
            var next = old; next.stage = stage; next.state = state; next.completedStages = completedStages
            next.failure = failure; next.updatedAt = .now
            try Self.putOperation(db, table: "jobs", id: next.id, gameID: next.gameID, value: next)
            return next
        }
    }

    /// The worker has verified both owned paths are absent. Install state and job completion become
    /// visible together; edits, collections, session history, Cloud history and remote files remain.
    public func completeUninstall(_ expected: JobRecord) throws -> JobRecord {
        try database.write { db in
            var job = try Self.currentUninstall(db, expected)
            guard job.stage == .commit, job.completedStages == [.removeFiles, .removeBottle],
                  let installed = job.originalInstallation else { throw CatalogError.identityMismatch }
            try db.execute(sql: "DELETE FROM installations WHERE id = ?", arguments: [installed.id.uuidString])
            job.state = .completed; job.stage = .finished; job.failure = nil; job.updatedAt = .now
            job.completedStages.formUnion([.commit, .finished])
            try Self.putOperation(db, table: "jobs", id: job.id, gameID: job.gameID, value: job)
            return job
        }
    }

    static func requireNoUninstall(_ db: Database, gameID: GameID) throws {
        let jobs: [JobRecord] = try values(db, table: "jobs", whereSQL: "source = ? AND game = ?", arguments: [gameID.source, gameID.value])
        guard !jobs.contains(where: { $0.kind == .uninstall && ![.completed, .cancelled].contains($0.state) }) else {
            throw uninstallFailure("Finish uninstalling this game in Downloads before playing or changing its installation.")
        }
    }

    /// Generic queue writes may reorder an existing uninstall, but cannot forge its consent,
    /// advance deletion checkpoints or release its reservation by marking it cancelled/completed.
    static func validateOrdinaryJobWrite(_ db: Database, _ job: JobRecord) throws {
        let existing: [JobRecord] = try values(db, table: "jobs", whereSQL: "id = ?", arguments: [job.id.uuidString])
        if job.kind == .uninstall || existing.first?.kind == .uninstall {
            guard let old = existing.first, old.kind == .uninstall else { throw CatalogError.identityMismatch }
            var comparable = job; comparable.queuePosition = old.queuePosition; comparable.updatedAt = old.updatedAt
            guard comparable == old else { throw CatalogError.identityMismatch }
        } else if ![.completed, .cancelled].contains(job.state) {
            try requireNoUninstall(db, gameID: job.gameID)
        }
    }

    private static func uninstallReview(_ db: Database, gameID: GameID) throws -> UninstallReview {
        let installs: [InstallationRecord] = try values(db, table: "installations", whereSQL: "source = ? AND game = ?", arguments: [gameID.source, gameID.value])
        guard installs.count == 1, let installed = installs.first else { throw CatalogError.identityMismatch }
        let sessions: [PlaySessionRecord] = try values(db, table: "sessions", whereSQL: "source = ? AND game = ?", arguments: [gameID.source, gameID.value])
        guard sessions.allSatisfy({ $0.endedAt != nil }) else { throw uninstallFailure("Quit this game before uninstalling it.") }
        let jobs: [JobRecord] = try values(db, table: "jobs", whereSQL: "source = ? AND game = ?", arguments: [gameID.source, gameID.value])
        guard jobs.allSatisfy({ [.completed, .cancelled].contains($0.state) }) else {
            throw uninstallFailure("This game already has an unfinished job. Finish it in Downloads first.")
        }
        try requireCloudIdle(db, gameID: gameID)
        let cloud: [CloudSyncOperation] = try values(db, table: "cloud_operations", whereSQL: "source = ? AND game = ?", arguments: [gameID.source, gameID.value])
        return .init(installation: installed,
            latestSession: sessions.max { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt },
            cloudOperations: cloud.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    private static func currentUninstall(_ db: Database, _ expected: JobRecord) throws -> JobRecord {
        let jobs: [JobRecord] = try values(db, table: "jobs", whereSQL: "id = ?", arguments: [expected.id.uuidString])
        guard let job = jobs.first, job == expected, job.kind == .uninstall,
              ![.completed, .cancelled].contains(job.state), let installed = job.originalInstallation,
              job.uninstallAuthorization?.review.installation == installed else { throw CatalogError.identityMismatch }
        let installs: [InstallationRecord] = try values(db, table: "installations", whereSQL: "id = ?", arguments: [installed.id.uuidString])
        guard installs == [installed] else { throw CatalogError.identityMismatch }
        try requireCloudIdle(db, gameID: job.gameID)
        let sessions: [PlaySessionRecord] = try values(db, table: "sessions", whereSQL: "source = ? AND game = ?", arguments: [job.gameID.source, job.gameID.value])
        guard sessions.allSatisfy({ $0.endedAt != nil }) else { throw uninstallFailure("The game is still running.") }
        return job
    }
    private static func uninstallFailure(_ reason: String) -> OperationFailure { .init(stage: "Uninstall", reason: reason, output: "") }
}
