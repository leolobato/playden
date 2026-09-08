import Foundation
import Domain

extension SaveStore {
    /// Build a local-only recovery source from a pending upload snapshot, including attempts
    /// that failed before Steam could be read. The empty remote is an internal staging context.
    public func archiveRecoveryInput(_ snapshotID: UUID, gameID: GameID, accountKey: String,
                                     revision: UInt64, requireReview: Bool = false) throws -> CloudArchiveRecoveryInput {
        let local = try verified(snapshotID, gameID: gameID), paths = try CloudSavePaths(mapping: local.mapping)
        guard local.cloud == nil else { throw saveFailure("The pending local save archive is invalid.") }
        let empty = try stageCloud(.init(gameID: gameID, accountKey: accountKey, revision: revision, files: []),
            installationID: local.installationID, mapping: local.mapping, downloads: [])
        let decisions = try local.files.compactMap { file -> CloudSyncDecision? in
            let location = CloudSavePath(root: file.root, path: file.path)
            guard let name = try paths.remoteName(for: location) else { return nil }
            return .init(name: name, location: location, action: .upload,
                local: .init(location: location, sha1: file.sha1, bytes: file.bytes, modifiedAt: file.modifiedAt), remote: nil)
        }
        let plan = CloudSyncPlan(gameID: gameID, installationID: local.installationID, accountKey: accountKey,
            remoteRevision: revision, decisions: decisions, requiresAccountConfirmation: false)
        _ = try cloudContext(plan, localSnapshotID: local.id, remoteSnapshotID: empty.id)
        return .init(plan: plan, localSnapshotID: local.id, remoteSnapshotID: empty.id, requiresReview: requireReview)
    }
    /// Construct a complete local recovery candidate from the authorized copies, including
    /// local uploads that may never have reached Steam. No network access or live writes occur.
    public func stageLocalRecovery(_ plan: CloudSyncPlan, localSnapshotID: UUID, remoteSnapshotID: UUID,
                                   roots: [SaveRoot: URL], requireReview: Bool = false) throws -> CloudLocalRecovery {
        let (original, changes) = try cloudContext(plan, localSnapshotID: localSnapshotID, remoteSnapshotID: remoteSnapshotID)
        var payloads: [CloudUpload] = []
        for decision in plan.decisions {
            guard let location = decision.location else { throw saveFailure("The interrupted save review is incomplete.") }
            let file: CloudFile?, source: UUID
            switch decision.action {
            case .upload:
                file = decision.local.map { .init(name: decision.name, sha1: $0.sha1, bytes: $0.bytes, modifiedAt: $0.modifiedAt) }
                source = localSnapshotID
            case .download, .unchanged:
                file = decision.remote?.state == .present ? decision.remote : nil
                source = remoteSnapshotID
            case .deleteLocal, .deleteRemote: continue
            case .conflict, .unavailable: throw saveFailure("Resolve the interrupted save review before recovery.")
            }
            if let file { payloads.append(.init(file: file, data: try stagedContents(source, gameID: plan.gameID, location: location))) }
        }
        let intended = CloudFileList(gameID: plan.gameID, accountKey: plan.accountKey,
            revision: plan.remoteRevision, files: payloads.map(\.file))
        let candidate = try stageCloud(intended, installationID: plan.installationID, mapping: original.mapping, downloads: payloads)
        let current = try snapshot(gameID: plan.gameID, installationID: plan.installationID, mapping: original.mapping, roots: roots)
        let comparison = try CloudSyncPlanner.plan(installationID: plan.installationID, mapping: original.mapping,
            localFiles: current.files.map { .init(location: .init(root: $0.root, path: $0.path), sha1: $0.sha1, bytes: $0.bytes, modifiedAt: $0.modifiedAt) },
            remote: intended, baseline: nil, attachedAccountKey: plan.accountKey, rootIdentities: current.rootIdentities)
        let expected = Dictionary(uniqueKeysWithValues: changes.map { ($0.location.key, $0) })
        let decisions = comparison.decisions.map { decision -> CloudSyncDecision in
            guard let location = decision.location else { return decision }
            let change = expected[location.key]
            let actual = decision.local.map { Fingerprint(sha1: $0.sha1, bytes: $0.bytes) }
            let wanted = decision.remote.map { Fingerprint(sha1: $0.sha1, bytes: $0.bytes) }
            let before = change?.before.map { Fingerprint(sha1: $0.sha1, bytes: $0.bytes) }
            let sameRoot = current.rootIdentities?[location.root] != nil &&
                current.rootIdentities?[location.root] == original.rootIdentities?[location.root]
            let action: CloudSyncDecision.Action
            if actual == wanted { action = .unchanged }
            else if change != nil && ((sameRoot && actual == before) || (!sameRoot && actual == nil)) {
                action = wanted == nil ? .deleteLocal : .download
            } else { action = .conflict }
            return .init(name: decision.name, location: location, action: action, local: decision.local, remote: decision.remote)
        }
        let review = CloudSyncPlan(gameID: plan.gameID, installationID: plan.installationID, accountKey: plan.accountKey,
            remoteRevision: plan.remoteRevision, decisions: decisions, requiresAccountConfirmation: false)
        return .init(localSnapshotID: current.id, remoteSnapshotID: candidate.id, plan: review, requiresReview: requireReview)
    }
}

private struct Fingerprint: Equatable { let sha1: Data; let bytes: Int64 }
