import Foundation

/// Captured after stopping the game and attempting Cloud sync. The journal compares the entire
/// review again when claiming removal, so new play, sync or installation changes invalidate consent.
public struct UninstallReview: Codable, Equatable, Sendable {
    public let installation: InstallationRecord
    public let latestSession: PlaySessionRecord?
    public let cloudOperations: [CloudSyncOperation]
    public init(installation: InstallationRecord, latestSession: PlaySessionRecord?, cloudOperations: [CloudSyncOperation]) {
        self.installation = installation; self.latestSession = latestSession; self.cloudOperations = cloudOperations
    }
    public var requiresDiscardConfirmation: Bool {
        guard cloudOperations.allSatisfy({ $0.phase.isTerminal }),
              let latest = cloudOperations.max(by: { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt < $1.updatedAt }),
              latest.phase == .completed, latest.installationID == installation.id,
              latest.ownershipToken == installation.ownershipToken else { return true }
        // Uninstall performs a fresh check after the last session ended. A previously green
        // status cannot authorize discarding progress written by a more recent offline session.
        return latestSession.map { latest.createdAt < $0.lastCheckpointAt } ?? false
    }
}

public struct UninstallAuthorization: Codable, Equatable, Sendable {
    public let review: UninstallReview
    public let discardUnsyncedProgress: Bool
    public init(review: UninstallReview, discardUnsyncedProgress: Bool) {
        self.review = review; self.discardUnsyncedProgress = discardUnsyncedProgress
    }
}
