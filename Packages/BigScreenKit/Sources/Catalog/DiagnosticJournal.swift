import Foundation
import Domain
import GRDB

public struct DiagnosticLogReference: Sendable {
    public let id: UUID
    public let gameID: GameID
    public let revision: Int64
}

extension CatalogStore {
    public var diagnosticWriteFailure: OperationFailure? { diagnosticFailure.withLock { $0 } }
    public func diagnosticSink(for id: UUID) -> @Sendable (DiagnosticCommand) -> Void {
        { [self] command in mutateDiagnostic(id) { $0.captureCommand(command) } }
    }
    public func captureDiagnosticEvent(for id: UUID, message: String, at date: Date = .now) {
        mutateDiagnostic(id) { $0.record(message, at: date) }
    }
    private func mutateDiagnostic(_ id: UUID, _ mutation: (inout DiagnosticLog) -> Void) {
        do {
            try database.write { db in
                let logs: [DiagnosticLog] = try Self.values(db, table: "diagnostic_logs", whereSQL: "id = ?", arguments: [id.uuidString])
                // A late callback must not resurrect an intentionally rotated diagnostic.
                guard var log = logs.first else { return }
                mutation(&log)
                if log != logs.first { try Self.putDiagnostic(db, log) }
            }
        } catch {
            diagnosticFailure.withLock { $0 = .init(stage: "Save diagnostics", reason: "Some command or stage details could not be saved. New logs are still being recorded.", output: "The diagnostic journal write failed.") }
        }
    }
    public func diagnosticReferences() throws -> [DiagnosticLogReference] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, source, game, revision FROM diagnostic_logs").map { row in
                guard let id = UUID(uuidString: row["id"]) else { throw CatalogError.identityMismatch }
                return DiagnosticLogReference(id: id, gameID: .init(source: row["source"], value: row["game"]), revision: row["revision"])
            }
        }
    }
    public func diagnosticLog(_ id: UUID) throws -> DiagnosticLog? {
        try database.read { db in
            let logs: [DiagnosticLog] = try Self.values(db, table: "diagnostic_logs", whereSQL: "id = ?", arguments: [id.uuidString])
            return logs.first
        }
    }
    public func diagnosticLogs(for gameID: GameID? = nil) throws -> [DiagnosticLog] {
        try database.read { db in
            let logs: [DiagnosticLog] = try Self.values(db, table: "diagnostic_logs",
                whereSQL: gameID == nil ? "1" : "source = ? AND game = ?",
                arguments: gameID.map { [$0.source, $0.value] } ?? [])
            return logs.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString > $1.id.uuidString : $0.updatedAt > $1.updatedAt }
        }
    }
    static func recordDiagnostic<T>(_ db: Database, value: T, imported: Bool = false) throws {
        let id: UUID, gameID: GameID, kind: String, start: Date, time: Date, stage: String, output: String
        let failure: OperationFailure?
        if let job = value as? JobRecord {
            id = job.id; gameID = job.gameID; kind = job.kind.rawValue; start = job.createdAt; time = job.updatedAt
            let reasons = job.pauseReasons.map(\.rawValue).sorted().joined(separator: ", ")
            stage = "\(job.stage.rawValue) · \(job.state.rawValue)" + (reasons.isEmpty ? "" : " · \(reasons)")
            failure = job.failure; output = job.failure?.output ?? ""
        } else if let session = value as? PlaySessionRecord {
            id = session.id; gameID = session.gameID; kind = "play session"; start = session.startedAt; time = session.lastCheckpointAt
            stage = session.outcome.map { "Finished · \($0.rawValue) · \(session.playedSeconds) seconds played" }
                ?? session.runtime.map { "Runtime · \($0.phase.rawValue)" } ?? "Preparing game"
            failure = session.failure ?? session.runtime?.failure
            output = session.runtime?.output ?? session.failure?.output ?? ""
        } else { return }
        let old: [DiagnosticLog] = try values(db, table: "diagnostic_logs", whereSQL: "id = ?", arguments: [id.uuidString])
        var log = old.first ?? DiagnosticLog(id: id, gameID: gameID, kind: kind, startedAt: start)
        guard log.gameID == gameID, log.kind == kind else { throw CatalogError.identityMismatch }
        if imported { log.record("Imported saved snapshot; earlier stage history is unavailable.", at: time) }
        // Repeated progress checkpoints do not repeat the stage. A retry's queued/running
        // transition separates consecutive failures even when their explanations match.
        let signature = stage + (failure.map { " · \($0.stage): \($0.reason)" } ?? "")
        log.record(signature, at: time)
        if !output.isEmpty { log.capture(output, at: time) }
        guard old.first != log else { return }
        try putDiagnostic(db, log)
    }
    private static func putDiagnostic(_ db: Database, _ log: DiagnosticLog) throws {
        let id = log.id, gameID = log.gameID
        try db.execute(sql: "INSERT INTO diagnostic_logs (id, source, game, updated, payload) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET updated = excluded.updated, payload = excluded.payload, revision = diagnostic_logs.revision + 1",
            arguments: [id.uuidString, gameID.source, gameID.value, log.updatedAt.timeIntervalSince1970, try encode(log)])
        try db.execute(sql: "DELETE FROM diagnostic_logs WHERE source = ? AND game = ? AND id NOT IN (SELECT id FROM diagnostic_logs WHERE source = ? AND game = ? ORDER BY updated DESC, id DESC LIMIT 10)",
            arguments: [gameID.source, gameID.value, gameID.source, gameID.value])
    }
}
