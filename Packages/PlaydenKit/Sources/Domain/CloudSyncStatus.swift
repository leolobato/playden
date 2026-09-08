import Foundation

public protocol CloudSyncManaging: Sendable {
    func recoverInterruptedOperations() async throws
    func updates() async -> AsyncStream<[GameID: CloudSyncStatus]>
    func synchronize(_ installation: InstallationRecord, mapping: SaveMapping,
                     preparingSessionID: UUID?, authorization: CloudSyncAuthorization?) async -> CloudSyncStatus
}

public struct CloudSyncStatus: Equatable, Sendable {
    public enum State: String, Sendable { case syncing, upToDate, pendingUpload, conflict, unavailable, failed }
    public let gameID: GameID
    public let state: State
    public let operation: CloudSyncOperation?
    public let message: String
    public let canPlayOffline: Bool
    public init(gameID: GameID, state: State, operation: CloudSyncOperation? = nil, message: String,
                canPlayOffline: Bool = false) {
        self.gameID = gameID; self.state = state; self.operation = operation
        self.message = message; self.canPlayOffline = canPlayOffline
    }
}

/// Consent refers to an exact displayed attempt. The coordinator invalidates it if either side
/// changes before execution; it must not become a standing permission to overwrite later saves.
public struct CloudSyncAuthorization: Sendable {
    public enum ConflictChoice: Sendable { case local, remote }
    public let operation: CloudSyncOperation
    public let conflictChoice: ConflictChoice?
    public let attachAccount: Bool
    public init(operation: CloudSyncOperation, conflictChoice: ConflictChoice? = nil, attachAccount: Bool = false) {
        self.operation = operation; self.conflictChoice = conflictChoice; self.attachAccount = attachAccount
    }
}
