import Foundation

/// Presentation-only acknowledgement of one persisted job state, not permission to cancel it.
public struct JobHistoryDismissal: Codable, Equatable, Sendable {
    public let jobID: UUID
    public let state: JobState
    public let updatedAt: Date
    public init(job: JobRecord) { jobID = job.id; state = job.state; updatedAt = job.updatedAt }
    public func hides(_ job: JobRecord) -> Bool {
        job.id == jobID && job.state == state && job.updatedAt == updatedAt && job.canDismissHistory
    }
}
extension JobRecord {
    public var canDismissHistory: Bool { [.completed, .cancelled, .failed].contains(state) }
}
