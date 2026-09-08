import Foundation
import Domain
import Catalog

/// Coordinates verified copies and transport under a durable game claim. The caller owns the
/// task lifetime (session preparation or an app-owned retry task), never a transient game view.
/// Root access must verify ownership and that the game's writer has stopped. Upload validation
/// is mandatory and source/title-specific, including handling crash/forced-exit save formats.
public actor CloudSyncService: CloudSyncManaging {
    public typealias RootAccess = @Sendable (InstallationRecord) async throws -> [SaveRoot: URL]
    public typealias UploadValidation = @Sendable (InstallationRecord, [CloudUpload], [String]) async throws -> Void
    private let catalog: CatalogStore
    private let saves: SaveStore
    private let reader: any CloudReading
    private let writer: any CloudWriting
    private let roots: RootAccess
    private let validateUploads: UploadValidation
    private var busy = Set<GameID>()
    private var active: [GameID: CloudSyncOperation] = [:]
    private var statuses: [GameID: CloudSyncStatus] = [:]
    private var observers: [UUID: AsyncStream<[GameID: CloudSyncStatus]>.Continuation] = [:]

    public init(catalog: CatalogStore, saves: SaveStore = SaveStore(), reader: any CloudReading,
                writer: any CloudWriting, roots: @escaping RootAccess,
                validateUploads: @escaping UploadValidation) {
        self.catalog = catalog; self.saves = saves; self.reader = reader; self.writer = writer
        self.roots = roots; self.validateUploads = validateUploads
    }
    public func updates() -> AsyncStream<[GameID: CloudSyncStatus]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { stream in
            observers[id] = stream; stream.yield(statuses)
            stream.onTermination = { @Sendable _ in Task { await self.removeObserver(id) } }
        }
    }
    /// Startup only, after session/process recovery and after establishing the old app worker is
    /// gone. Claims never expire on a timer. A resumed game defers its Cloud recovery until exit.
    public func recoverInterruptedOperations() throws {
        guard busy.isEmpty else { throw CloudJournalError.gameBusy }
        for saved in try catalog.cloudOperations() where !saved.phase.isTerminal {
            var operation = saved
            if saved.claim != nil {
                do { operation = try catalog.recoverInterruptedCloudSync(saved) }
                catch CloudJournalError.gameBusy { continue }
            }
            publish(status(operation, state: operation.phase == .conflict ? .conflict : .pendingUpload,
                message: "Save sync needs attention. Retry to check both copies."))
        }
    }

    /// Used before launch, after exit, and by Retry. `preparingSessionID` is the caller's owned
    /// session reservation: either no process has launched or its runtime has verified exit.
    /// Post-exit callers keep this reservation unfinished until sync has released its claim.
    public func synchronize(_ installation: InstallationRecord, mapping: SaveMapping,
                            preparingSessionID: UUID? = nil,
                            authorization: CloudSyncAuthorization? = nil) async -> CloudSyncStatus {
        let gameID = installation.gameID
        guard busy.insert(gameID).inserted else {
            return statuses[gameID] ?? .init(gameID: gameID, state: .syncing, message: "Syncing saves…")
        }
        defer { busy.remove(gameID); active[gameID] = nil }
        publish(.init(gameID: gameID, state: .syncing, message: "Checking saved progress…"))
        do {
            _ = try CloudSavePaths(mapping: mapping)
            let previous = try catalog.cloudOperations(for: gameID).last { !$0.phase.isTerminal }
            if let authorization, authorization.operation != previous { throw CloudJournalError.staleAttempt }
            // A local recovery choice is consumed locally. It never authorizes a subsequent
            // account attachment or resolves a new disagreement with the live Steam account.
            var consent = previous?.needsLocalRecovery == true ? nil : authorization
            let attachment = try catalog.cloudAttachment(for: gameID, installationID: installation.id)
            if let previous {
                guard previous.installationID == installation.id, previous.mapping == mapping else {
                    throw issue("Save sync from the previous installation or recipe needs recovery first.")
                }
                active[gameID] = try catalog.resumeCloudSync(previous, preparingSessionID: preparingSessionID)
            } else {
                active[gameID] = try catalog.beginCloudSync(installation: installation,
                    accountKey: attachment?.accountKey ?? "unattached", mapping: mapping, preparingSessionID: preparingSessionID)
            }
            let locations = try await roots(installation)
            try Task.checkCancellation()
            if previous != nil, try await recoverArchiveIfRootChanged(installation, locations: locations) { consent = nil }

            // Complete an interrupted local publication using its already authorized, verified
            // copies before interpreting a changed remote list or accepting an offline launch.
            if let pending = active[gameID], pending.needsLocalRecovery {
                if let review = try await recoverLocal(installation, locations: locations, authorization: authorization) { return review }
            }
            // Never reuse a previous attempt's local bytes as if they reflected later offline play.
            // The old immutable copy remains in history; this fresh snapshot detects new progress.
            let local = try await saves.snapshot(gameID: gameID, installationID: installation.id,
                                                  mapping: mapping, roots: roots(installation))
            if previous != nil, try await recoverArchiveIfRootChanged(installation, locations: locations, currentSnapshot: local) {
                throw issue("The save folder changed before its checkpoint was saved. Retry to restore the archived progress.")
            }
            if previous != nil {
                active[gameID] = try catalog.replaceCloudSync(current(gameID), installation: installation, localSnapshotID: local.id)
            } else if try current(gameID).localSnapshotID == nil {
                active[gameID] = try catalog.recordCloudLocalSnapshot(current(gameID), snapshotID: local.id)
            }
            let remote = try await reader.files(for: gameID)
            guard remote.gameID == gameID else { throw issue("Steam returned saves for a different game.") }
            try Task.checkCancellation()

            if let authorization = consent {
                guard let originalLocalID = authorization.operation.localSnapshotID,
                      authorization.operation.remote == remote else { return try await replanChangedReview(installation, mapping: mapping, local: local, remote: remote) }
                let reviewed = try await saves.verified(originalLocalID, gameID: gameID)
                if fingerprints(reviewed) != fingerprints(local) || reviewed.rootIdentities != local.rootIdentities {
                    return try await replanChangedReview(installation, mapping: mapping, local: local, remote: remote)
                }
            }
            if try current(gameID).accountKey != remote.accountKey {
                active[gameID] = try catalog.replaceCloudSync(current(gameID), installation: installation,
                    localSnapshotID: local.id, accountKey: remote.accountKey)
            }
            return try await stageAndExecute(installation, mapping: mapping, local: local,
                                              remote: remote, consent: consent)
        } catch {
            return fail(gameID, error: error)
        }
    }

    private func archiveInput(_ accepted: CloudLocalRecovery) throws -> CloudArchiveRecoveryInput {
        guard let plan = accepted.appliedPlan else { throw CloudJournalError.invalidTransition }
        return .init(plan: plan, localSnapshotID: accepted.localSnapshotID, remoteSnapshotID: accepted.remoteSnapshotID)
    }

    /// Losing a physical root is not evidence that the player deleted its pending upload.
    /// Retain and recover that local archive before reading Steam or retiring the attempt.
    private func recoverArchiveIfRootChanged(_ installation: InstallationRecord, locations: [SaveRoot: URL],
                                           currentSnapshot: SaveSnapshot? = nil) async throws -> Bool {
        let pending = try current(installation.gameID)
        guard !pending.needsLocalRecovery else { return false }
        let accepted = pending.localRecoveries?.last(where: { $0.appliedPlan != nil })
        guard let snapshotID = accepted?.localSnapshotID ?? pending.localSnapshotID else { return false }
        let archived = try await saves.verified(snapshotID, gameID: installation.gameID)
        guard archived.installationID == installation.id, archived.mapping == pending.mapping, archived.cloud == nil else {
            throw issue("The pending save archive does not match this installation. Its files have been kept.")
        }
        let now: SaveSnapshot
        if let currentSnapshot { now = currentSnapshot }
        else { now = try await saves.snapshot(gameID: installation.gameID, installationID: installation.id,
            mapping: pending.mapping, roots: locations) }
        let cloudRoots = Set(pending.mapping.rules.filter { $0.cloudPrefix != nil }.map(\.root))
        let knownRoots = cloudRoots.allSatisfy { archived.rootIdentities?[$0] != nil }
        let changed = cloudRoots.contains { archived.rootIdentities?[$0] != now.rootIdentities?[$0] }
        guard changed || (!knownRoots && fingerprints(archived) != fingerprints(now)) else { return false }
        let input: CloudArchiveRecoveryInput
        if let accepted { input = try archiveInput(accepted) }
        else {
            guard !localFiles(archived).isEmpty else { return false }
            input = try await saves.archiveRecoveryInput(snapshotID, gameID: installation.gameID,
                accountKey: pending.accountKey, revision: pending.plan?.remoteRevision ?? 0, requireReview: !knownRoots)
        }
        active[installation.gameID] = try catalog.requireCloudArchiveRecovery(pending, input: input)
        return true
    }

    private func recoverLocal(_ installation: InstallationRecord, locations: [SaveRoot: URL],
                              authorization: CloudSyncAuthorization?) async throws -> CloudSyncStatus? {
        let gameID = installation.gameID, pending = try current(gameID)
        let accepted = pending.localRecoveries?.last(where: { $0.appliedPlan != nil })
        guard let plan = accepted?.appliedPlan ?? pending.archiveRecoveryInput?.plan ?? pending.plan,
              let localID = accepted?.localSnapshotID ?? pending.archiveRecoveryInput?.localSnapshotID ?? pending.localSnapshotID,
              let remoteID = accepted?.remoteSnapshotID ?? pending.archiveRecoveryInput?.remoteSnapshotID ?? pending.remoteSnapshotID else {
            throw issue("The interrupted save review is incomplete. Existing files have been kept.")
        }
        var recovery = try await saves.stageLocalRecovery(plan, localSnapshotID: localID, remoteSnapshotID: remoteID, roots: locations,
            requireReview: accepted == nil && pending.archiveRecoveryInput?.requiresReview == true)
        var choice: CloudSyncAuthorization.ConflictChoice?
        if let authorization, let requested = authorization.conflictChoice,
           let reviewed = authorization.operation.localRecoveries?.last, reviewed.requiresReview, reviewed.appliedPlan == nil {
            let before = try await saves.verified(reviewed.localSnapshotID, gameID: gameID)
            let now = try await saves.verified(recovery.localSnapshotID, gameID: gameID)
            if reviewed.plan == recovery.plan && fingerprints(before) == fingerprints(now) && before.rootIdentities == now.rootIdentities {
                choice = requested
            } else {
                recovery = .init(localSnapshotID: recovery.localSnapshotID, remoteSnapshotID: recovery.remoteSnapshotID,
                    plan: recovery.plan, requiresReview: true)
            }
        }
        active[gameID] = try catalog.stageCloudLocalRecovery(current(gameID), recovery: recovery)
        if recovery.requiresReview && choice == nil {
            active[gameID] = try catalog.pauseCloudSync(current(gameID), phase: .conflict)
            return publish(status(try current(gameID), state: .conflict,
                message: "Saved progress changed during an interrupted sync. Choose the files to keep on this Mac, then Big Screen will check Steam Cloud. Both copies are backed up."))
        }
        active[gameID] = try catalog.authorizeCloudLocalRecovery(current(gameID), choice: choice)
        guard let execution = try current(gameID).localRecoveries?.last?.appliedPlan else { throw CloudJournalError.invalidTransition }
        let destinations = try await roots(installation)
        _ = try await saves.applyCloud(execution, localSnapshotID: recovery.localSnapshotID,
            remoteSnapshotID: recovery.remoteSnapshotID, roots: destinations)
        try await saves.verifyCloudRoots(recovery.localSnapshotID, gameID: gameID, roots: roots(installation))
        active[gameID] = try catalog.markCloudLocalApplied(current(gameID))
        return nil
    }

    private func replanChangedReview(_ installation: InstallationRecord, mapping: SaveMapping,
                                     local: SaveSnapshot, remote: CloudFileList) async throws -> CloudSyncStatus {
        let gameID = installation.gameID
        active[gameID] = try catalog.replaceCloudSync(current(gameID), installation: installation,
            localSnapshotID: local.id, accountKey: remote.accountKey)
        // Do not carry the old consent into changed data. A new review must be explicit even if
        // a three-way planner would otherwise see a one-sided change as automatically safe.
        return try await stageAndExecute(installation, mapping: mapping, local: local, remote: remote,
                                         consent: nil, requireReview: true)
    }

    private func stageAndExecute(_ installation: InstallationRecord, mapping: SaveMapping, local: SaveSnapshot,
                                 remote: CloudFileList, consent: CloudSyncAuthorization?, requireReview: Bool = false) async throws -> CloudSyncStatus {
        let gameID = installation.gameID
        let attachment = try catalog.cloudAttachment(for: gameID, installationID: installation.id)
        let originalPlan = try CloudSyncPlanner.plan(installationID: installation.id, mapping: mapping,
            localFiles: localFiles(local), remote: remote,
            baseline: catalog.cloudBaseline(for: gameID, accountKey: remote.accountKey), attachedAccountKey: attachment?.accountKey,
            rootIdentities: local.rootIdentities)
        if originalPlan.hasUnavailableFiles {
            active[gameID] = try catalog.pauseCloudSync(current(gameID), phase: .unavailable)
            return publish(status(try current(gameID), state: .unavailable, message: "Some Cloud save locations are unsupported. Your local progress has been kept."))
        }
        var downloads: [CloudUpload] = [], total: Int64 = 0
        for file in remote.files where file.state == .present {
            guard file.bytes >= 0, file.bytes <= 64 * 1024 * 1024, total <= 512 * 1024 * 1024 - file.bytes else { throw issue("This Cloud save set is too large to stage.") }
            total += file.bytes
            downloads.append(.init(file: file, data: try await reader.download(file, from: remote)))
        }
        let downloaded = try await saves.stageCloud(remote, installationID: installation.id, mapping: mapping, downloads: downloads)
        guard try await reader.files(for: gameID) == remote else { throw issue("Cloud saves changed while downloading. Retry to review the latest copies.") }
        let plan = try resolved(originalPlan, choice: consent?.conflictChoice)
        active[gameID] = try catalog.stageCloudSync(current(gameID), plan: plan, remote: remote,
                                                   localSnapshotID: local.id, remoteSnapshotID: downloaded.id)
        if plan.hasConflicts || requireReview || (plan.requiresAccountConfirmation && consent?.attachAccount != true) {
            active[gameID] = try catalog.pauseCloudSync(current(gameID), phase: .conflict)
            return publish(status(try current(gameID), state: .conflict,
                message: requireReview ? "Saves changed since your last review. Review both copies again." :
                    plan.hasConflicts ? "Local and Cloud progress differ. Choose which copy to use." : "Confirm which Steam account should receive this local progress."))
        }
        if consent?.attachAccount == true { active[gameID] = try catalog.confirmCloudAccount(current(gameID)) }
        let paths = try CloudSavePaths(mapping: mapping)
        var uploads: [CloudUpload] = []
        for decision in plan.decisions where decision.action == .upload {
            guard let location = decision.location, let localFile = decision.local, try paths.remoteName(for: location) != nil else { throw issue("The upload review is incomplete.") }
            uploads.append(.init(file: .init(name: decision.name, sha1: localFile.sha1, bytes: localFile.bytes, modifiedAt: localFile.modifiedAt),
                data: try await saves.stagedContents(local.id, gameID: gameID, location: location)))
        }
        let deletes = plan.decisions.filter { $0.action == .deleteRemote }.map(\.name)
        if !uploads.isEmpty || !deletes.isEmpty { try await validateUploads(installation, uploads, deletes) }
        // Recheck ownership/idle writer and the entire local set before any remote write.
        let locations = try await roots(installation)
        let beforeWrite = try await saves.snapshot(gameID: gameID, installationID: installation.id, mapping: mapping, roots: locations)
        guard fingerprints(beforeWrite) == fingerprints(local), beforeWrite.rootIdentities == local.rootIdentities else {
            throw issue("Local progress or its save folder changed before upload. Retry to review it.")
        }
        var finalRemote = remote
        if !uploads.isEmpty || !deletes.isEmpty {
            try Task.checkCancellation()
            let operationID = try current(gameID).id
            finalRemote = try await writer.upload(uploads, deleting: deletes, basedOn: remote,
                clientID: catalog.cloudClientID(), buildID: 0) { batch in
                try await self.recordBatch(batch, gameID: gameID, operationID: operationID)
            }
        }
        guard try await reader.files(for: gameID) == finalRemote else { throw issue("Cloud progress changed before local saves could be applied. Retry to reconcile it.") }
        try Task.checkCancellation()
        let finalLocations = try await roots(installation)
        try await saves.verifyCloudRoots(local.id, gameID: gameID, roots: finalLocations)
        active[gameID] = try catalog.markCloudApplying(current(gameID))
        let applied = try await saves.applyCloud(plan, localSnapshotID: local.id, remoteSnapshotID: downloaded.id, roots: finalLocations)
        active[gameID] = try catalog.markCloudLocalApplied(current(gameID))
        guard try await reader.files(for: gameID) == finalRemote, try matchesResult(plan, local: applied, remote: finalRemote, mapping: mapping) else {
            throw issue("Save sync could not verify the final copies. Both backups have been kept; retry to reconcile.")
        }
        try await saves.verifyCloudRoots(local.id, gameID: gameID, roots: roots(installation))
        return try finish(gameID, mapping: mapping, remote: finalRemote, rootIdentities: local.rootIdentities)
    }

    private func resolved(_ plan: CloudSyncPlan, choice: CloudSyncAuthorization.ConflictChoice?) throws -> CloudSyncPlan {
        guard let choice else { return plan }
        let decisions = plan.decisions.map { decision -> CloudSyncDecision in
            guard decision.action == .conflict else { return decision }
            let action: CloudSyncDecision.Action = choice == .local ? (decision.local == nil ? .deleteRemote : .upload) :
                (decision.remote?.state == .present ? .download : .deleteLocal)
            return .init(name: decision.name, location: decision.location, action: action, local: decision.local, remote: decision.remote)
        }
        return .init(gameID: plan.gameID, installationID: plan.installationID, accountKey: plan.accountKey,
                     remoteRevision: plan.remoteRevision, decisions: decisions, requiresAccountConfirmation: plan.requiresAccountConfirmation)
    }
    private func recordBatch(_ batch: CloudUploadBatch, gameID: GameID, operationID: UUID) throws {
        let operation = try current(gameID)
        guard operation.id == operationID else { throw CloudJournalError.staleAttempt }
        active[gameID] = try catalog.recordCloudBatch(operation, batch: batch)
    }
    private func finish(_ gameID: GameID, mapping: SaveMapping, remote: CloudFileList,
                        rootIdentities: [SaveRoot: SaveRootIdentity]?) throws -> CloudSyncStatus {
        let operation = try current(gameID)
        active[gameID] = try catalog.completeCloudSync(operation,
            baseline: .init(gameID: gameID, installationID: operation.installationID, accountKey: operation.accountKey,
                            revision: remote.revision, mapping: mapping, files: remote.files.filter { $0.state == .present },
                            rootIdentities: rootIdentities))
        return publish(status(try current(gameID), state: .upToDate, message: "Up to date"))
    }
    private func fail(_ gameID: GameID, error: Error) -> CloudSyncStatus {
        let failure = error as? OperationFailure ?? issue(error is CancellationError ? "Save sync was interrupted. Retry to continue." :
            error is CloudJournalError ? "Save sync needs to be retried after the current game operation finishes." : "Steam Cloud is unavailable. Your local progress has been kept.")
        if let operation = active[gameID], operation.claim != nil {
            do { active[gameID] = try catalog.pauseCloudSync(operation, phase: .pending, failure: failure) }
            catch { return publish(status(operation, state: .failed, message: "The save-sync checkpoint could not be stored. Retry before playing.")) }
        }
        if let operation = active[gameID] { return publish(status(operation, state: .pendingUpload, message: failure.reason)) }
        if let pending = try? catalog.cloudOperations(for: gameID).last(where: { !$0.phase.isTerminal }) {
            return publish(status(pending, state: .failed, message: failure.reason))
        }
        return publish(.init(gameID: gameID, state: .unavailable, message: failure.reason, canPlayOffline: error is OperationFailure))
    }
    private func current(_ gameID: GameID) throws -> CloudSyncOperation {
        guard let value = active[gameID] else { throw CloudJournalError.staleAttempt }
        return value
    }
    private func status(_ operation: CloudSyncOperation, state: CloudSyncStatus.State, message: String) -> CloudSyncStatus {
        .init(gameID: operation.gameID, state: state, operation: operation, message: message,
              canPlayOffline: operation.claim == nil && !operation.needsLocalRecovery)
    }
    @discardableResult private func publish(_ value: CloudSyncStatus) -> CloudSyncStatus {
        statuses[value.gameID] = value
        for observer in observers.values { observer.yield(statuses) }
        return value
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func localFiles(_ snapshot: SaveSnapshot) -> [CloudLocalFile] {
        snapshot.files.map { .init(location: .init(root: $0.root, path: $0.path), sha1: $0.sha1, bytes: $0.bytes, modifiedAt: $0.modifiedAt) }
    }
    private struct Fingerprint: Equatable { let sha1: Data; let bytes: Int64 }
    private func fingerprints(_ snapshot: SaveSnapshot) -> [String: Fingerprint] {
        Dictionary(uniqueKeysWithValues: snapshot.files.map { (CloudSavePath(root: $0.root, path: $0.path).key, .init(sha1: $0.sha1, bytes: $0.bytes)) })
    }
    private func matchesResult(_ plan: CloudSyncPlan, local: [CloudLocalFile], remote: CloudFileList, mapping: SaveMapping) throws -> Bool {
        guard remote.accountKey == plan.accountKey, remote.gameID == plan.gameID, remote.revision >= plan.remoteRevision else { return false }
        var intended: [String: Fingerprint] = [:], locations: [String: Fingerprint] = [:]
        for decision in plan.decisions {
            let value: Fingerprint?
            switch decision.action {
            case .upload: value = decision.local.map { .init(sha1: $0.sha1, bytes: $0.bytes) }
            case .download, .unchanged: value = decision.remote.flatMap { $0.state == .present ? .init(sha1: $0.sha1, bytes: $0.bytes) : nil }
            case .deleteLocal, .deleteRemote: value = nil
            case .conflict, .unavailable: return false
            }
            if let value, let location = decision.location { intended[decision.name] = value; locations[location.key] = value }
        }
        var remoteHashes: [String: Fingerprint] = [:]
        for file in remote.files where file.state == .present {
            guard remoteHashes.updateValue(.init(sha1: file.sha1, bytes: file.bytes), forKey: file.name) == nil else { return false }
        }
        let paths = try CloudSavePaths(mapping: mapping)
        let mapped = try local.filter { try paths.remoteName(for: $0.location) != nil }
        guard Set(mapped.map { $0.location.key }).count == mapped.count else { return false }
        let localHashes = Dictionary(uniqueKeysWithValues: mapped.map { ($0.location.key, Fingerprint(sha1: $0.sha1, bytes: $0.bytes)) })
        return intended == remoteHashes && locations == localHashes
    }
    private func issue(_ message: String) -> OperationFailure { .init(stage: "Cloud saves", reason: message, output: "") }
}
