import Foundation
import Domain
import GRDB

public enum CloudJournalError: Error, Equatable {
    case staleAttempt, invalidTransition, identityMismatch, gameBusy, unresolvedAttempt, accountConfirmationRequired
}

extension CatalogStore {
    /// Reserve preparation, not a game writer, while a released Cloud publication needs local
    /// recovery. This lets SessionService recreate a missing runtime and rerun its recipe before
    /// resuming that operation. Normal saveSession still rejects unrecovered publications.
    public func reserveCloudRecoverySession(_ session: PlaySessionRecord, operation: CloudSyncOperation) throws {
        try database.write { db in
            let pending = try Self.currentCloud(db, operation)
            guard pending.needsLocalRecovery, pending.claim == nil, !pending.phase.isTerminal,
                  session.gameID == pending.gameID, session.runtime == nil, session.endedAt == nil,
                  session.outcome == nil, session.playedSeconds == 0, session.startedAt == session.lastCheckpointAt else {
                throw CloudJournalError.invalidTransition
            }
            let sessions: [PlaySessionRecord] = try Self.values(db, table: "sessions")
            guard !sessions.contains(where: { $0.endedAt == nil || $0.id == session.id }) else { throw CloudJournalError.gameBusy }
            let installed = try Self.requireCloudAccess(db, operation: pending, sessionID: nil)
            guard installed.bottleID == session.bottleID else { throw CloudJournalError.identityMismatch }
            try Self.putOperation(db, table: "sessions", id: session.id, gameID: session.gameID, value: session)
        }
    }

    /// Only launch/staging metadata may change during recovery preparation. The installation,
    /// owner, mapping plan, storage and Cloud receipts retain their existing identities.
    public func saveCloudRecoveryPreparation(_ prepared: InstallationRecord, replacing original: InstallationRecord,
                                             sessionID: UUID) throws {
        var allowed = original; allowed.launchSpec = prepared.launchSpec; allowed.staging = prepared.staging
        allowed.stagingVersion = prepared.staging?.version ?? original.stagingVersion
        guard prepared == allowed else { throw CloudJournalError.identityMismatch }
        try database.write { db in
            let operations: [CloudSyncOperation] = try Self.values(db, table: "cloud_operations",
                whereSQL: "source = ? AND game = ?", arguments: [prepared.gameID.source, prepared.gameID.value])
            let pending = operations.filter { !$0.phase.isTerminal }
            guard pending.count == 1, pending[0].needsLocalRecovery, pending[0].claim == nil else { throw CloudJournalError.gameBusy }
            let installed = try Self.requireCloudAccess(db, operation: pending[0], sessionID: sessionID)
            let sessions: [PlaySessionRecord] = try Self.values(db, table: "sessions", whereSQL: "id = ?", arguments: [sessionID.uuidString])
            guard installed == original, sessions.first?.runtime == nil, sessions.first?.endedAt == nil else { throw CloudJournalError.identityMismatch }
            try Self.putOperation(db, table: "installations", id: prepared.id, gameID: prepared.gameID, value: prepared)
        }
    }

    /// Check the durable fence before invoking the runtime, not only after a writer is created.
    public func checkCloudBeforeLaunch(_ session: PlaySessionRecord) throws {
        try database.read { db in
            let sessions: [PlaySessionRecord] = try Self.values(db, table: "sessions", whereSQL: "id = ?", arguments: [session.id.uuidString])
            guard sessions.first == session, session.runtime == nil, session.endedAt == nil else { throw CloudJournalError.gameBusy }
            try Self.requireCloudIdle(db, gameID: session.gameID)
        }
    }

    /// A stable installation-of-Big-Screen identifier, separate from editable library preferences.
    /// Preferences row 1 remains the library model; row 2 is this private Cloud client receipt.
    public func cloudClientID() throws -> UInt64 {
        try database.write { db in
            if let bytes = try Data.fetchOne(db, sql: "SELECT payload FROM preferences WHERE id = 2") {
                let id = try Self.decode(UInt64.self, bytes)
                guard id != 0 else { throw CloudJournalError.identityMismatch }
                return id
            }
            let id = UInt64.random(in: 1...UInt64.max)
            try db.execute(sql: "INSERT INTO preferences (id, payload) VALUES (2, ?)", arguments: [try Self.encode(id)])
            return id
        }
    }

    /// Save local staging before network access, so offline failure still has a durable copy.
    public func recordCloudLocalSnapshot(_ expected: CloudSyncOperation, snapshotID: UUID) throws -> CloudSyncOperation {
        try changeCloud(expected) { _, value in
            guard value.plan == nil, value.localSnapshotID == nil || value.localSnapshotID == snapshotID else {
                throw CloudJournalError.invalidTransition
            }
            value.localSnapshotID = snapshotID
        }
    }

    /// The coordinator has reapplied and verified the complete local result. Remote reconciliation
    /// can remain pending without blocking offline play. This does not advance a sync baseline.
    public func markCloudLocalApplied(_ expected: CloudSyncOperation) throws -> CloudSyncOperation {
        try changeCloud(expected) { db, value in
            try Self.requireLocalRecoveryAccess(db, value)
            guard value.phase == .applyingLocal,
                  value.localRecoveries?.isEmpty != false || value.localRecoveries?.last?.appliedPlan != nil else {
                throw CloudJournalError.invalidTransition
            }
            value.needsLocalRecovery = false; value.phase = .verifying
        }
    }

    /// The coordinator has staged both the current files and the complete previously authorized
    /// result. Recovery never changes the original plan, account, batch receipts or baseline.
    public func stageCloudLocalRecovery(_ expected: CloudSyncOperation, recovery: CloudLocalRecovery) throws -> CloudSyncOperation {
        try changeCloud(expected) { db, value in
            try Self.requireLocalRecoveryAccess(db, value)
            guard value.needsLocalRecovery, recovery.appliedPlan == nil,
                  recovery.localSnapshotID != recovery.remoteSnapshotID,
                  recovery.plan.gameID == value.gameID, recovery.plan.installationID == value.installationID,
                  recovery.plan.accountKey == value.accountKey,
                  recovery.plan.remoteRevision == (value.archiveRecoveryInput?.plan.remoteRevision ?? value.plan?.remoteRevision),
                  !recovery.plan.hasUnavailableFiles, !recovery.plan.requiresAccountConfirmation,
                  !(value.localRecoveries ?? []).contains(where: { $0.id == recovery.id }) else {
                throw CloudJournalError.invalidTransition
            }
            value.localRecoveries = (value.localRecoveries ?? []) + [recovery]
            value.phase = recovery.requiresReview ? .conflict : .pending
        }
    }

    /// Persist the exact local recovery choice before writing. Automatic recovery is permitted
    /// only when the staged review contains no unfamiliar current progress.
    public func authorizeCloudLocalRecovery(_ expected: CloudSyncOperation,
                                           choice: CloudSyncAuthorization.ConflictChoice? = nil) throws -> CloudSyncOperation {
        try changeCloud(expected) { db, value in
            try Self.requireLocalRecoveryAccess(db, value)
            guard value.needsLocalRecovery, var reviews = value.localRecoveries, !reviews.isEmpty,
                  reviews[reviews.count - 1].appliedPlan == nil,
                  let plan = reviews.last?.choosing(choice), !plan.hasConflicts, !plan.hasUnavailableFiles else {
                throw CloudJournalError.invalidTransition
            }
            reviews[reviews.count - 1].appliedPlan = plan
            value.localRecoveries = reviews; value.phase = .applyingLocal
        }
    }
    public func cloudOperations(for gameID: GameID? = nil) throws -> [CloudSyncOperation] {
        try database.read { db in
            let operations: [CloudSyncOperation] = try Self.values(db, table: "cloud_operations",
                whereSQL: gameID == nil ? "1" : "source = ? AND game = ?",
                arguments: gameID.map { [$0.source, $0.value] } ?? [])
            return operations.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        }
    }

    public func cloudBaseline(for gameID: GameID, accountKey: String) throws -> CloudSyncBaseline? {
        try database.read { db in
            let values: [CloudSyncBaseline] = try Self.values(db, table: "cloud_baselines",
                whereSQL: "source = ? AND game = ? AND account = ?", arguments: [gameID.source, gameID.value, accountKey])
            return values.first
        }
    }

    public func cloudAttachment(for gameID: GameID, installationID: UUID) throws -> CloudAccountAttachment? {
        try database.read { db in
            let attachment = try Self.attachment(db, gameID: gameID)
            return attachment?.installationID == installationID ? attachment : nil
        }
    }

    /// Claims the same durable game boundary used by sessions and maintenance. The only permitted
    /// unfinished session is the caller's reservation before launch or after verified runtime exit.
    public func beginCloudSync(installation: InstallationRecord, accountKey: String, mapping: SaveMapping,
                               preparingSessionID: UUID? = nil) throws -> CloudSyncOperation {
        guard !accountKey.isEmpty else { throw CloudJournalError.identityMismatch }
        return try database.write { db in
            let existing: [CloudSyncOperation] = try Self.values(db, table: "cloud_operations",
                whereSQL: "source = ? AND game = ?", arguments: [installation.gameID.source, installation.gameID.value])
            guard !existing.contains(where: { !$0.phase.isTerminal }) else { throw CloudJournalError.unresolvedAttempt }
            let operation = CloudSyncOperation(installation: installation, accountKey: accountKey,
                                              mapping: mapping, preparingSessionID: preparingSessionID)
            let installed = try Self.requireCloudAccess(db, operation: operation, sessionID: preparingSessionID)
            guard installed == installation else { throw CloudJournalError.identityMismatch }
            try Self.putCloud(db, operation)
            return operation
        }
    }

    /// Retire the previous attempt only in the same transaction that records its replacement's
    /// verified local archive. A crash cannot leave progress reachable only through retired history.
    public func replaceCloudSync(_ expected: CloudSyncOperation, installation: InstallationRecord,
                                 localSnapshotID: UUID, accountKey: String? = nil) throws -> CloudSyncOperation {
        try database.write { db in
            var old = try Self.currentCloud(db, expected)
            guard old.claim != nil, !old.phase.isTerminal, !old.needsLocalRecovery else { throw CloudJournalError.invalidTransition }
            let installed = try Self.requireCloudAccess(db, operation: old, sessionID: old.preparingSessionID)
            guard installed == installation, !(accountKey ?? old.accountKey).isEmpty else { throw CloudJournalError.identityMismatch }
            var next = CloudSyncOperation(installation: installation, accountKey: accountKey ?? old.accountKey,
                mapping: old.mapping, preparingSessionID: old.preparingSessionID)
            next.localSnapshotID = localSnapshotID
            old.phase = .superseded; old.claim = nil; old.preparingSessionID = nil
            try Self.advanceCloud(db, &old)
            try Self.putCloud(db, next)
            return next
        }
    }

    /// Fence a lost-root archive for local recovery without modifying the original Steam plan,
    /// upload batches, account attachment or baseline. Inputs must come from this attempt's local
    /// archive or its latest already-authorized local recovery.
    public func requireCloudArchiveRecovery(_ expected: CloudSyncOperation,
                                            input: CloudArchiveRecoveryInput) throws -> CloudSyncOperation {
        try changeCloud(expected) { _, value in
            let accepted = value.localRecoveries?.last(where: { $0.appliedPlan != nil })
            let acceptedInput = accepted.map { CloudArchiveRecoveryInput(plan: $0.appliedPlan!,
                localSnapshotID: $0.localSnapshotID, remoteSnapshotID: $0.remoteSnapshotID) }
            guard !value.needsLocalRecovery, input.localSnapshotID != input.remoteSnapshotID,
                  input.plan.gameID == value.gameID, input.plan.installationID == value.installationID,
                  input.plan.accountKey == value.accountKey, !input.plan.requiresAccountConfirmation,
                  !input.plan.hasConflicts, !input.plan.hasUnavailableFiles,
                  (acceptedInput == input || (accepted == nil && input.localSnapshotID == value.localSnapshotID &&
                    input.plan.decisions.allSatisfy { $0.action == .upload && $0.local != nil && $0.remote == nil })) else {
                throw CloudJournalError.invalidTransition
            }
            value.archiveRecoveryInput = input; value.needsLocalRecovery = true; value.phase = .pending
        }
    }

    /// Both snapshot IDs must already identify fully durable, verified copies (including empty
    /// snapshots). A conflict plan may be journaled, but cannot start writes. Supersede it with
    /// a resolved attempt, keeping its backup references. Staged context is immutable.
    public func stageCloudSync(_ expected: CloudSyncOperation, plan: CloudSyncPlan, remote: CloudFileList,
                               localSnapshotID: UUID, remoteSnapshotID: UUID) throws -> CloudSyncOperation {
        try changeCloud(expected) { _, value in
            guard value.plan == nil, value.batches.isEmpty, !value.needsLocalRecovery, value.archiveRecoveryInput == nil,
                  [.checking, .ready, .conflict, .pending, .failed, .unavailable].contains(value.phase),
                  plan.gameID == value.gameID, plan.installationID == value.installationID,
                  plan.accountKey == value.accountKey, remote.gameID == value.gameID,
                  remote.accountKey == value.accountKey, plan.remoteRevision == remote.revision,
                  localSnapshotID != remoteSnapshotID,
                  value.localSnapshotID == nil || value.localSnapshotID == localSnapshotID else { throw CloudJournalError.invalidTransition }
            guard Set(plan.decisions.map(\.name)).count == plan.decisions.count else { throw CloudJournalError.invalidTransition }
            value.plan = plan; value.remote = remote
            value.localSnapshotID = localSnapshotID; value.remoteSnapshotID = remoteSnapshotID
            value.phase = plan.hasUnavailableFiles ? .unavailable : plan.hasConflicts ? .conflict : .ready
            value.failure = nil
        }
    }

    /// Call only after the player explicitly authorizes attaching this installation's progress to
    /// this account. Kept separate from sign-in and from choosing a timestamp-based conflict winner.
    public func confirmCloudAccount(_ expected: CloudSyncOperation) throws -> CloudSyncOperation {
        try changeCloud(expected) { db, value in
            guard value.batches.isEmpty, !value.needsLocalRecovery, value.archiveRecoveryInput == nil else { throw CloudJournalError.invalidTransition }
            try Self.putGame(db, table: "cloud_attachments", id: value.gameID,
                value: CloudAccountAttachment(gameID: value.gameID, installationID: value.installationID, accountKey: value.accountKey))
        }
    }

    /// Suitable for CloudWriting.onBatchStarted. This transaction completes before HTTP writes.
    public func recordCloudBatch(_ expected: CloudSyncOperation, batch: CloudUploadBatch) throws -> CloudSyncOperation {
        try changeCloud(expected) { db, value in
            try Self.requireExecutable(db, value)
            guard [.ready, .uploading].contains(value.phase), !value.needsLocalRecovery,
                  batch.id != 0, !value.batches.contains(where: { $0.id == batch.id }) else { throw CloudJournalError.invalidTransition }
            // Even an unexpected reservation must be recorded: it might need recovery at Steam.
            value.batches.append(batch); value.phase = .uploading
        }
    }

    /// Persist before replacing/deleting any local file. A failed partial application continues to
    /// block play and maintenance until recovery verifies a complete set of saves.
    public func markCloudApplying(_ expected: CloudSyncOperation) throws -> CloudSyncOperation {
        try changeCloud(expected) { db, value in
            try Self.requireExecutable(db, value)
            guard [.ready, .uploading, .applyingLocal, .pending, .failed].contains(value.phase),
                  value.localRecoveries?.isEmpty != false || value.localRecoveries?.last?.appliedPlan != nil else {
                throw CloudJournalError.invalidTransition
            }
            value.phase = .applyingLocal; value.needsLocalRecovery = true
        }
    }

    public func markCloudVerifying(_ expected: CloudSyncOperation) throws -> CloudSyncOperation {
        try changeCloud(expected) { db, value in
            try Self.requireExecutable(db, value)
            guard [.ready, .uploading, .applyingLocal, .verifying, .failed, .pending].contains(value.phase) else {
                throw CloudJournalError.invalidTransition
            }
            value.phase = .verifying
        }
    }

    public func pauseCloudSync(_ expected: CloudSyncOperation, phase: CloudSyncOperation.Phase,
                               failure: OperationFailure? = nil) throws -> CloudSyncOperation {
        guard [.pending, .failed, .conflict, .unavailable].contains(phase) else { throw CloudJournalError.invalidTransition }
        return try changeCloud(expected) { _, value in
            value.phase = phase; value.failure = failure; value.claim = nil; value.preparingSessionID = nil
        }
    }

    /// Startup recovery only, after the coordinator has established that the previous worker is
    /// gone (or cancelled and joined). An old timestamp is not sufficient evidence. Reopening the
    /// database does not release claims automatically. The CAS rejects a still-advancing worker.
    public func recoverInterruptedCloudSync(_ expected: CloudSyncOperation) throws -> CloudSyncOperation {
        try database.write { db in
            var value = try Self.currentCloud(db, expected)
            guard value.claim != nil, !value.phase.isTerminal else { throw CloudJournalError.invalidTransition }
            // Session recovery can already have finalized the old pre-launch record. Releasing
            // that dead worker is allowed, but a live game still prevents recovery mutations.
            let sessions: [PlaySessionRecord] = try Self.values(db, table: "sessions",
                whereSQL: "source = ? AND game = ?", arguments: [value.gameID.source, value.gameID.value])
            let active = sessions.filter { $0.endedAt == nil }
            guard active.allSatisfy({ $0.id == value.preparingSessionID && ($0.runtime == nil || $0.runtime?.phase == .exited) }) else { throw CloudJournalError.gameBusy }
            value.phase = .pending; value.claim = nil; value.preparingSessionID = nil
            value.failure = .init(stage: "Cloud saves", reason: "Save sync was interrupted. Retry to reconcile both copies.", output: "")
            try Self.advanceCloud(db, &value)
            return value
        }
    }

    public func resumeCloudSync(_ expected: CloudSyncOperation, preparingSessionID: UUID? = nil) throws -> CloudSyncOperation {
        try database.write { db in
            var value = try Self.currentCloud(db, expected)
            guard value.claim == nil, !value.phase.isTerminal else { throw CloudJournalError.invalidTransition }
            _ = try Self.requireCloudAccess(db, operation: value, sessionID: preparingSessionID)
            value.claim = UUID(); value.preparingSessionID = preparingSessionID
            try Self.advanceCloud(db, &value)
            return value
        }
    }

    /// After reconciling an obsolete plan, retain its receipts and backups as history, then begin
    /// a fresh attempt. This is not a claim of successful sync and never advances the baseline.
    public func supersedeCloudSync(_ expected: CloudSyncOperation) throws -> CloudSyncOperation {
        try changeCloud(expected) { _, value in
            guard !value.needsLocalRecovery else { throw CloudJournalError.invalidTransition }
            value.phase = .superseded; value.claim = nil; value.preparingSessionID = nil
        }
    }

    /// Call after reading and hashing the final local files and fetching the final remote list.
    /// Equality verification belongs to the coordinator; the journal additionally rejects a
    /// baseline that does not match the staged plan, account, installation or known revisions.
    public func completeCloudSync(_ expected: CloudSyncOperation, baseline: CloudSyncBaseline) throws -> CloudSyncOperation {
        try changeCloud(expected) { db, value in
            try Self.requireExecutable(db, value)
            guard value.phase == .verifying, value.localRecoveries?.isEmpty != false, baseline.gameID == value.gameID,
                  baseline.installationID == value.installationID, baseline.accountKey == value.accountKey,
                  baseline.mapping == value.mapping, let remote = value.remote, let plan = value.plan,
                  baseline.revision >= remote.revision,
                  value.batches.allSatisfy({ baseline.revision >= $0.revision }),
                  try Self.fingerprints(baseline.files) == Self.intendedFiles(plan) else { throw CloudJournalError.invalidTransition }
            let old: [CloudSyncBaseline] = try Self.values(db, table: "cloud_baselines",
                whereSQL: "source = ? AND game = ? AND account = ?", arguments: [value.gameID.source, value.gameID.value, value.accountKey])
            guard old.first.map({ baseline.revision >= $0.revision }) ?? true else { throw CloudJournalError.invalidTransition }
            try db.execute(sql: """
                INSERT INTO cloud_baselines (source, game, account, payload) VALUES (?, ?, ?, ?)
                ON CONFLICT(source, game, account) DO UPDATE SET payload = excluded.payload
                """, arguments: [value.gameID.source, value.gameID.value, value.accountKey, try Self.encode(baseline)])
            try Self.putGame(db, table: "cloud_attachments", id: value.gameID,
                value: CloudAccountAttachment(gameID: value.gameID, installationID: value.installationID, accountKey: value.accountKey))
            value.phase = .completed; value.claim = nil; value.preparingSessionID = nil
            value.needsLocalRecovery = false; value.failure = nil
        }
    }

    private func changeCloud(_ expected: CloudSyncOperation,
                             body: (Database, inout CloudSyncOperation) throws -> Void) throws -> CloudSyncOperation {
        try database.write { db in
            var value = try Self.currentCloud(db, expected)
            guard value.claim != nil, !value.phase.isTerminal else { throw CloudJournalError.invalidTransition }
            _ = try Self.requireCloudAccess(db, operation: value, sessionID: value.preparingSessionID)
            try body(db, &value)
            try Self.advanceCloud(db, &value)
            return value
        }
    }

    private static func currentCloud(_ db: Database, _ expected: CloudSyncOperation) throws -> CloudSyncOperation {
        let records: [CloudSyncOperation] = try values(db, table: "cloud_operations", whereSQL: "id = ?", arguments: [expected.id.uuidString])
        guard let current = records.first, current == expected else { throw CloudJournalError.staleAttempt }
        return current
    }
    private static func advanceCloud(_ db: Database, _ value: inout CloudSyncOperation) throws {
        guard value.version < Int64.max else { throw CloudJournalError.invalidTransition }
        value.version += 1; value.updatedAt = max(value.updatedAt, .now)
        try putCloud(db, value)
    }
    private static func putCloud(_ db: Database, _ value: CloudSyncOperation) throws {
        try putOperation(db, table: "cloud_operations", id: value.id, gameID: value.gameID, value: value)
    }
    private static func attachment(_ db: Database, gameID: GameID) throws -> CloudAccountAttachment? {
        let values: [CloudAccountAttachment] = try values(db, table: "cloud_attachments",
            whereSQL: "source = ? AND game = ?", arguments: [gameID.source, gameID.value])
        return values.first
    }
    static func requireCloudIdle(_ db: Database, gameID: GameID) throws {
        let operations: [CloudSyncOperation] = try values(db, table: "cloud_operations",
            whereSQL: "source = ? AND game = ?", arguments: [gameID.source, gameID.value])
        guard !operations.contains(where: { !$0.phase.isTerminal && ($0.claim != nil || $0.needsLocalRecovery) }) else {
            throw OperationFailure(stage: "Cloud saves", reason: "Finish or recover this game's save sync before playing or changing its files.", output: "")
        }
    }
    private static func requireCloudAccess(_ db: Database, operation: CloudSyncOperation,
                                           sessionID: UUID?) throws -> InstallationRecord {
        let installs: [InstallationRecord] = try values(db, table: "installations", whereSQL: "id = ?", arguments: [operation.installationID.uuidString])
        guard let installed = installs.first, installed.gameID == operation.gameID,
              installed.ownershipToken == operation.ownershipToken else { throw CloudJournalError.identityMismatch }
        let sessions: [PlaySessionRecord] = try values(db, table: "sessions",
            whereSQL: "source = ? AND game = ?", arguments: [operation.gameID.source, operation.gameID.value])
        let active = sessions.filter { $0.endedAt == nil }
        if let sessionID {
            guard active.count == 1, active[0].id == sessionID,
                  active[0].runtime == nil || active[0].runtime?.phase == .exited,
                  active[0].bottleID == installed.bottleID else { throw CloudJournalError.gameBusy }
        } else if !active.isEmpty { throw CloudJournalError.gameBusy }
        let jobs: [JobRecord] = try values(db, table: "jobs",
            whereSQL: "source = ? AND game = ?", arguments: [operation.gameID.source, operation.gameID.value])
        guard installed.needsRepair != true, !jobs.contains(where: { ![.completed, .cancelled].contains($0.state) }) else {
            throw CloudJournalError.gameBusy
        }
        return installed
    }
    private static func requireExecutable(_ db: Database, _ value: CloudSyncOperation) throws {
        guard value.archiveRecoveryInput == nil, let plan = value.plan, value.remote != nil, value.localSnapshotID != nil,
              value.remoteSnapshotID != nil, !plan.hasConflicts, !plan.hasUnavailableFiles else { throw CloudJournalError.invalidTransition }
        if plan.requiresAccountConfirmation || plan.decisions.contains(where: { $0.local != nil || $0.action == .deleteRemote || $0.action == .upload }) {
            let attachment = try attachment(db, gameID: value.gameID)
            guard attachment?.installationID == value.installationID, attachment?.accountKey == value.accountKey else {
                throw CloudJournalError.accountConfirmationRequired
            }
        }
    }
    private static func requireLocalRecoveryAccess(_ db: Database, _ value: CloudSyncOperation) throws {
        // Only the explicitly journaled local archive path can bypass remote account consent.
        // Every remote-writing/final-baseline transition still calls requireExecutable.
        if value.archiveRecoveryInput != nil {
            guard value.needsLocalRecovery else { throw CloudJournalError.invalidTransition }
        } else { try requireExecutable(db, value) }
    }
    private struct Fingerprint: Equatable { let sha1: Data; let bytes: Int64 }
    private static func fingerprints(_ files: [CloudFile]) throws -> [String: Fingerprint] {
        var result: [String: Fingerprint] = [:]
        for file in files {
            guard file.state == .present, file.sha1.count == 20, file.bytes >= 0,
                  result.updateValue(.init(sha1: file.sha1, bytes: file.bytes), forKey: file.name) == nil else {
                throw CloudJournalError.invalidTransition
            }
        }
        return result
    }
    private static func intendedFiles(_ plan: CloudSyncPlan) throws -> [String: Fingerprint] {
        var files: [CloudFile] = []
        for decision in plan.decisions {
            switch decision.action {
            case .upload:
                guard let local = decision.local else { throw CloudJournalError.invalidTransition }
                files.append(.init(name: decision.name, sha1: local.sha1, bytes: local.bytes, modifiedAt: local.modifiedAt))
            case .download:
                guard let remote = decision.remote, remote.state == .present else { throw CloudJournalError.invalidTransition }
                files.append(remote)
            case .unchanged:
                if let remote = decision.remote, remote.state == .present { files.append(remote) }
            case .deleteLocal, .deleteRemote: break
            case .conflict, .unavailable: throw CloudJournalError.invalidTransition
            }
        }
        return try fingerprints(files)
    }
}
