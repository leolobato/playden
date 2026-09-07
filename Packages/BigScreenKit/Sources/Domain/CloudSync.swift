import Foundation

public struct CloudSavePath: Codable, Equatable, Hashable, Sendable {
    public let root: SaveRoot
    public let path: String
    public init(root: SaveRoot, path: String) { self.root = root; self.path = path }
    public var key: String { root.rawValue + "/" + path.lowercased() }
}

public struct CloudLocalFile: Codable, Equatable, Sendable {
    public let location: CloudSavePath
    public let sha1: Data
    public let bytes: Int64
    public let modifiedAt: Date
    public init(location: CloudSavePath, sha1: Data, bytes: Int64, modifiedAt: Date) {
        self.location = location; self.sha1 = sha1; self.bytes = bytes; self.modifiedAt = modifiedAt
    }
}

/// Committed only once both sides have been verified equal. Reinstallation and mapping changes
/// invalidate deletion inference; an old baseline must not turn absent new local files into deletions.
public struct CloudSyncBaseline: Codable, Equatable, Sendable {
    public let gameID: GameID
    public let installationID: UUID
    public let accountKey: String
    public let revision: UInt64
    public let mapping: SaveMapping
    public let files: [CloudFile]
    public let synchronizedAt: Date
    public init(gameID: GameID, installationID: UUID, accountKey: String, revision: UInt64,
                mapping: SaveMapping, files: [CloudFile], synchronizedAt: Date = .now) {
        self.gameID = gameID; self.installationID = installationID; self.accountKey = accountKey
        self.revision = revision; self.mapping = mapping; self.files = files; self.synchronizedAt = synchronizedAt
    }
}

public struct CloudSyncDecision: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case unchanged, upload, download, deleteLocal, deleteRemote, conflict, unavailable
    }
    public let name: String
    public let location: CloudSavePath?
    public let action: Action
    public let local: CloudLocalFile?
    public let remote: CloudFile?
    public init(name: String, location: CloudSavePath?, action: Action, local: CloudLocalFile?, remote: CloudFile?) {
        self.name = name; self.location = location; self.action = action; self.local = local; self.remote = remote
    }
}

public struct CloudSyncPlan: Codable, Equatable, Sendable {
    public let gameID: GameID
    public let installationID: UUID
    public let accountKey: String
    public let remoteRevision: UInt64
    public let decisions: [CloudSyncDecision]
    /// No remote mutation is permitted until the player explicitly attaches local progress to
    /// this account. Never infer that consent from elapsed time, timestamps, or an empty Cloud.
    public let requiresAccountConfirmation: Bool
    public var hasConflicts: Bool { decisions.contains { $0.action == .conflict } }
    public var hasUnavailableFiles: Bool { decisions.contains { $0.action == .unavailable } }
    public var canApplyAutomatically: Bool { !requiresAccountConfirmation && !hasConflicts && !hasUnavailableFiles }
    public var isUpToDate: Bool { canApplyAutomatically && decisions.allSatisfy { $0.action == .unchanged } }
    public init(gameID: GameID, installationID: UUID, accountKey: String, remoteRevision: UInt64,
                decisions: [CloudSyncDecision], requiresAccountConfirmation: Bool) {
        self.gameID = gameID; self.installationID = installationID; self.accountKey = accountKey
        self.remoteRevision = remoteRevision; self.decisions = decisions
        self.requiresAccountConfirmation = requiresAccountConfirmation
    }
}
