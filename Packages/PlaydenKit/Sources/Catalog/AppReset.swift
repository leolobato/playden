import Foundation
import Domain
import GRDB

extension CatalogStore {
    /// The UI checks this before signing out; the final transaction checks again. Paused jobs,
    /// failed jobs and released Cloud recovery attempts are retained, never erased by reset.
    public func checkAppReset() throws { try database.read { try Self.checkAppReset($0) } }

    /// Clears personalization atomically after authentication/refresh tasks have been joined
    /// and the registered source has signed out. Game ownership, operation journals, Cloud
    /// identity/history, play history, diagnostics and all filesystem content remain intact.
    public func resetAppData() throws {
        try database.write { db in
            try Self.checkAppReset(db)
            for table in ["source_games", "source_sync", "game_edits", "collections", "job_history_dismissals", "download_sizes"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            try db.execute(sql: "DELETE FROM preferences WHERE id = 1")
        }
    }

    private static func checkAppReset(_ db: Database) throws {
        let sessions: [PlaySessionRecord] = try values(db, table: "sessions")
        guard sessions.allSatisfy({ $0.endedAt != nil }) else { throw resetIssue("Close the game and let its save sync finish before resetting Playden.") }
        let jobs: [JobRecord] = try values(db, table: "jobs")
        for job in jobs where ![.completed, .cancelled].contains(job.state) {
            guard job.kind != .uninstall else { throw resetIssue("Finish or retry the pending game removal before resetting Playden.") }
            guard job.cancellationRequested != true,
                  job.state == .failed || (job.state == .paused && job.pauseReasons.contains(.user)) else {
                throw resetIssue("Pause each download or file verification in Downloads before resetting Playden.")
            }
        }
        let cloud: [CloudSyncOperation] = try values(db, table: "cloud_operations")
        guard cloud.allSatisfy({ $0.phase.isTerminal || $0.claim == nil }) else {
            throw resetIssue("Let save sync finish before resetting Playden. Pending saves will be kept.")
        }
    }
    private static func resetIssue(_ reason: String) -> OperationFailure {
        .init(stage: "Reset Playden", reason: reason, output: "")
    }
}
