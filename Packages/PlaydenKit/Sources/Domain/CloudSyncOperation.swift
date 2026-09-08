import Foundation

/// A durable attempt, scoped to one installation and store account. Snapshot IDs refer to
/// immutable, verified staging copies; no credentials or absolute save paths belong here.
public struct CloudSyncOperation: Codable, Equatable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        case checking, ready, uploading, applyingLocal, verifying
        case pending, conflict, unavailable, failed, completed, superseded
        public var isTerminal: Bool { self == .completed || self == .superseded }
    }
    public let id: UUID
    public let gameID: GameID
    public let installationID: UUID
    public let ownershipToken: UUID
    public let accountKey: String
    public let mapping: SaveMapping
    public let createdAt: Date
    public var version: Int64
    /// Fences callbacks from a previous worker. Never expires based on elapsed time.
    public var claim: UUID?
    /// Session reservation before launch or after verified runtime exit. The historical encoded
    /// name is retained for journals written before post-exit session integration.
    public var preparingSessionID: UUID?
    public var phase: Phase
    public var plan: CloudSyncPlan?
    public var remote: CloudFileList?
    public var localSnapshotID: UUID?
    public var remoteSnapshotID: UUID?
    public var batches: [CloudUploadBatch]
    /// Remains set after failure/restart until local application has been reconciled and verified.
    /// Offline play is safe before application starts, but not midway through replacing saves.
    public var needsLocalRecovery: Bool
    public var localRecoveries: [CloudLocalRecovery]? = nil
    public var archiveRecoveryInput: CloudArchiveRecoveryInput? = nil
    public var reviewPlan: CloudSyncPlan? { needsLocalRecovery ? localRecoveries?.last?.plan ?? plan : plan }
    public var needsRecoveryReview: Bool { needsLocalRecovery && localRecoveries?.last?.requiresReview == true }
    public var failure: OperationFailure?
    public var updatedAt: Date

    public init(installation: InstallationRecord, accountKey: String, mapping: SaveMapping,
                preparingSessionID: UUID? = nil, now: Date = .now) {
        id = UUID(); gameID = installation.gameID; installationID = installation.id
        ownershipToken = installation.ownershipToken; self.accountKey = accountKey; self.mapping = mapping
        createdAt = now; updatedAt = now; version = 0; claim = UUID()
        self.preparingSessionID = preparingSessionID; phase = .checking
        plan = nil; remote = nil; localSnapshotID = nil; remoteSnapshotID = nil
        batches = []; needsLocalRecovery = false; failure = nil
    }
}

public struct CloudAccountAttachment: Codable, Equatable, Sendable {
    public let gameID: GameID
    public let installationID: UUID
    public let accountKey: String
    public init(gameID: GameID, installationID: UUID, accountKey: String) {
        self.gameID = gameID; self.installationID = installationID; self.accountKey = accountKey
    }
}
