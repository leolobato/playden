import Foundation

/// Verified inputs for local-only recovery of an attempt's archived progress. This is separate
/// from its Steam plan: restoring device-owned bytes never authorizes remote writes or attachment.
public struct CloudArchiveRecoveryInput: Codable, Equatable, Sendable {
    public let plan: CloudSyncPlan
    public let localSnapshotID: UUID
    public let remoteSnapshotID: UUID
    public let requiresReview: Bool
    public init(plan: CloudSyncPlan, localSnapshotID: UUID, remoteSnapshotID: UUID, requiresReview: Bool = false) {
        self.plan = plan; self.localSnapshotID = localSnapshotID; self.remoteSnapshotID = remoteSnapshotID
        self.requiresReview = requiresReview
    }
}

/// A local-only publication review. The remote snapshot here is the complete intended result
/// assembled from a previously authorized operation's immutable copies, not a new server read.
/// Every review is retained so replacements and repeated crashes cannot discard earlier copies.
public struct CloudLocalRecovery: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let localSnapshotID: UUID
    public let remoteSnapshotID: UUID
    public let plan: CloudSyncPlan
    public let requiresReview: Bool
    /// Persisted before any local mutation. A later recovery continues this accepted result.
    public var appliedPlan: CloudSyncPlan?
    public init(localSnapshotID: UUID, remoteSnapshotID: UUID, plan: CloudSyncPlan, requiresReview: Bool = false) {
        id = UUID(); self.localSnapshotID = localSnapshotID; self.remoteSnapshotID = remoteSnapshotID
        self.plan = plan; self.requiresReview = requiresReview || plan.hasConflicts; appliedPlan = nil
    }

    public func choosing(_ choice: CloudSyncAuthorization.ConflictChoice?) -> CloudSyncPlan? {
        guard let choice else { return requiresReview ? nil : plan }
        // A recovery choice selects a complete copy, including missing files. It is never an
        // authorization to contact Steam or attach progress to a different account.
        return .init(gameID: plan.gameID, installationID: plan.installationID, accountKey: plan.accountKey,
            remoteRevision: plan.remoteRevision, decisions: plan.decisions.map { decision in
                .init(name: decision.name, location: decision.location,
                    action: choice == .local ? (decision.local == nil ? .deleteRemote : .upload) :
                        (decision.remote?.state == .present ? .download : .deleteLocal),
                    local: decision.local, remote: decision.remote)
            }, requiresAccountConfirmation: false)
    }
}
