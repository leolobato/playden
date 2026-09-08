import Foundation
import GRDB
import Domain

extension CatalogStore {
    /// Compare the displayed job with durable state, so a late click cannot hide a new attempt.
    public func dismissJobHistory(_ expected: JobRecord) throws -> JobHistoryDismissal {
        try database.write { db in
            let jobs: [JobRecord] = try Self.values(db, table: "jobs", whereSQL: "id = ?", arguments: [expected.id.uuidString])
            guard let current = jobs.first, current == expected, current.canDismissHistory else {
                throw OperationFailure(stage: "Downloads", reason: "This job has changed. Review its current status before dismissing it.", output: "")
            }
            let dismissal = JobHistoryDismissal(job: current)
            try db.execute(sql: "INSERT OR REPLACE INTO job_history_dismissals (id, payload) VALUES (?, ?)",
                arguments: [current.id.uuidString, try JSONEncoder().encode(dismissal)])
            return dismissal
        }
    }
    public func jobHistoryDismissals() throws -> [JobHistoryDismissal] {
        try database.read { try Self.values($0, table: "job_history_dismissals") }
    }
    public func revealJobHistory(_ id: UUID) throws {
        try database.write { try $0.execute(sql: "DELETE FROM job_history_dismissals WHERE id = ?", arguments: [id.uuidString]) }
    }
}
