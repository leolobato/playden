import XCTest
import Foundation
import Darwin
import GRDB
import Domain
import Catalog

final class DiagnosticTests: XCTestCase {
    func testCommandTranscriptSurvivesCheckpointsAndMissingLogIsNotResurrected() throws {
        let catalog = try CatalogStore()
        var job = JobRecord(gameID: gameID); job.state = .running; try catalog.saveJob(job)
        let capture = catalog.diagnosticSink(for: job.id)
        capture(.init(tool: "cxstart", exitCode: 0, output: "stdout: runtime ready\nstderr: warning\naccess_token=EXAMPLE_SECRET"))
        job.bytesCompleted = 128; try catalog.saveJob(job)
        job.state = .failed; job.failure = .init(stage: "Verify", reason: "Missing file", output: "Verification details"); try catalog.saveJob(job)
        let log = try XCTUnwrap(catalog.diagnosticLog(job.id))
        XCTAssertTrue(log.text.contains("cxstart · exit 0")); XCTAssertTrue(log.text.contains("runtime ready"))
        XCTAssertTrue(log.text.contains("Verification details")); XCTAssertFalse(log.text.contains("EXAMPLE_SECRET"))
        XCTAssertEqual(log.events.count, 2, "Commands do not cause repeated progress stage entries")
        catalog.diagnosticSink(for: UUID())(.init(tool: "late", exitCode: 0, output: "not retained"))
        XCTAssertEqual(try catalog.diagnosticLogs().count, 1)
    }
    func testDiagnosticWriteFailureDoesNotChangeOperationAndRemainsVisible() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("catalog.sqlite").path, catalog = try CatalogStore(path: root.appendingPathComponent("catalog.sqlite").path)
        let job = JobRecord(gameID: gameID); try catalog.saveJob(job)
        let db = try DatabaseQueue(path: path)
        try db.write { try $0.execute(sql: "CREATE TRIGGER reject_diagnostic BEFORE UPDATE ON diagnostic_logs BEGIN SELECT RAISE(ABORT, 'simulated storage failure'); END") }
        catalog.diagnosticSink(for: job.id)(.init(tool: "test", exitCode: 0, output: "Completed command"))
        XCTAssertNotNil(catalog.diagnosticWriteFailure)
        XCTAssertEqual(try catalog.jobs(), [job])
        try db.write { try $0.execute(sql: "DROP TRIGGER reject_diagnostic") }
        catalog.diagnosticSink(for: job.id)(.init(tool: "test", exitCode: 0, output: "New command"))
        XCTAssertTrue(try XCTUnwrap(catalog.diagnosticLog(job.id)).text.contains("New command"))
        XCTAssertNotNil(catalog.diagnosticWriteFailure, "A later successful write does not claim lost details were recovered")
    }
    private let gameID = GameID(source: "steam", value: "1055540")
    private func temporary() throws -> URL {
        let resolved = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("Playden-diagnostics-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testStagesRetryAndSessionOutputSurviveReopenAndRollback() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("catalog.sqlite").path
        let catalog = try CatalogStore(path: path)
        var job = JobRecord(gameID: gameID)
        try catalog.saveJob(job)
        job.stage = .download; job.state = .running; job.updatedAt.addTimeInterval(1); try catalog.saveJob(job)
        job.bytesCompleted = 100; job.updatedAt.addTimeInterval(1); try catalog.saveJob(job)
        XCTAssertEqual(try catalog.diagnosticLog(job.id)?.events.count, 2, "Progress does not flood the stage timeline")
        job.state = .failed; job.failure = .init(stage: "Download", reason: "Connection lost", output: "access_token=SECRET\nTransfer stopped")
        job.updatedAt.addTimeInterval(1); try catalog.saveJob(job)
        job.state = .queued; job.failure = nil; job.updatedAt.addTimeInterval(1); try catalog.saveJob(job)
        let reopened = try CatalogStore(path: path)
        let log = try XCTUnwrap(reopened.diagnosticLog(job.id))
        XCTAssertEqual(log.events.count, 4); XCTAssertTrue(log.text.contains("Transfer stopped")); XCTAssertFalse(log.text.contains("SECRET"))
        var invalid = job; invalid.gameID = .init(source: "fake", value: "different")
        var fresh = JobRecord(gameID: gameID); fresh.state = .running
        XCTAssertThrowsError(try reopened.saveJobs([fresh, invalid]))
        XCTAssertNil(try reopened.diagnosticLog(fresh.id), "A rolled-back operation cannot leave a diagnostic event")
        var session = PlaySessionRecord(gameID: gameID, bottleID: "test")
        session.failure = .init(stage: "Launch", reason: "Runtime missing", output: "stderr: missing runtime")
        session.endedAt = session.startedAt; session.outcome = .launchFailed
        try reopened.saveSession(session)
        XCTAssertTrue(try XCTUnwrap(reopened.diagnosticLog(session.id)).text.contains("stderr: missing runtime"))
    }
    func testRotationCombinesJobsAndSessionsWithoutDeletingOperationalHistory() throws {
        let catalog = try CatalogStore()
        let start = Date(timeIntervalSince1970: 100)
        var ids: [UUID] = []
        for index in 0..<12 {
            var job = JobRecord(gameID: gameID, createdAt: start.addingTimeInterval(Double(index)))
            job.state = .completed; try catalog.saveJob(job); ids.append(job.id)
        }
        var session = PlaySessionRecord(gameID: gameID, bottleID: "test", startedAt: start.addingTimeInterval(20))
        session.endedAt = session.startedAt; session.outcome = .clean; try catalog.saveSession(session)
        let logs = try catalog.diagnosticLogs(for: gameID)
        XCTAssertEqual(logs.count, 10); XCTAssertEqual(logs.first?.id, session.id)
        XCTAssertNil(try catalog.diagnosticLog(ids[2])); XCTAssertNotNil(try catalog.diagnosticLog(ids[3]))
        XCTAssertEqual(try catalog.jobs().count, 12)
        XCTAssertEqual(try catalog.latestSession(for: gameID), session)
    }
    func testMigratesExistingRecordsAsSnapshotsWithoutInventingEarlierStages() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("catalog.sqlite").path
        let id: UUID
        do {
            let catalog = try CatalogStore(path: path)
            var job = JobRecord(gameID: gameID); job.stage = .finished; job.state = .completed; id = job.id
            try catalog.saveJob(job)
        }
        let database = try DatabaseQueue(path: path)
        try database.write { db in
            try db.execute(sql: "DROP TABLE diagnostic_logs")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v5_diagnostics'")
        }
        let reopened = try CatalogStore(path: path)
        let log = try XCTUnwrap(reopened.diagnosticLog(id))
        XCTAssertEqual(log.events.count, 2)
        XCTAssertTrue(log.text.contains("earlier stage history is unavailable"))
        XCTAssertTrue(log.text.contains("finished · completed"))
        XCTAssertFalse(log.text.contains("download · running"))
    }
    func testBoundsAndRedactsBeforeTruncating() {
        var log = DiagnosticLog(id: UUID(), gameID: gameID, kind: "test", startedAt: .now)
        for index in 0..<600 { log.record("Stage \(index)", at: .now) }
        log.capture("access_token=" + String(repeating: "s", count: 300_000) + "\n" + String(repeating: "line\n", count: 60_000), at: .now)
        XCTAssertEqual(log.events.count, 512); XCTAssertEqual(log.omittedEvents, 88)
        XCTAssertTrue(log.outputTruncated); XCTAssertLessThanOrEqual(log.output.utf8.count, 256 * 1024)
        XCTAssertFalse(log.output.contains("ssss")); XCTAssertTrue(log.text.contains("earlier events omitted"))
        log.capture(String(repeating: "漢", count: 100_000), at: .now)
        XCTAssertLessThanOrEqual(log.output.utf8.count, 256 * 1024)
        XCTAssertFalse(log.output.contains("�"))
    }
    func testArchiveWritesRotatesAndRepairsMissingFiles() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try CatalogStore(), archive = DiagnosticArchive(root: root.appendingPathComponent("logs"))
        var jobs: [JobRecord] = []
        for index in 0..<12 {
            var job = JobRecord(gameID: gameID, createdAt: Date(timeIntervalSince1970: Double(index)))
            job.state = .completed; try catalog.saveJob(job); jobs.append(job)
            try await archive.synchronize(catalog)
        }
        let folder = root.appendingPathComponent("logs/steam-1055540")
        let notes = folder.appendingPathComponent("notes.txt"); try Data("keep".utf8).write(to: notes)
        let log = try XCTUnwrap(catalog.diagnosticLog(jobs.last!.id)), file = try await archive.file(for: log)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), log.text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".log") }.count, 10)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.removeItem(at: file)
        try await archive.synchronize(catalog)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), log.text)
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "keep")
    }
    func testArchiveRejectsSymlinksAndEncodesSourcePaths() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try CatalogStore(), archive = DiagnosticArchive(root: root.appendingPathComponent("logs"))
        let job = JobRecord(gameID: gameID); try catalog.saveJob(job); try await archive.synchronize(catalog)
        let log = try XCTUnwrap(catalog.diagnosticLog(job.id)), file = try await archive.file(for: log)
        let outside = root.appendingPathComponent("untouched.txt"); try Data("untouched".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        do { try await archive.synchronize(catalog); XCTFail("A linked log must be rejected") } catch {}
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
        try FileManager.default.removeItem(at: root.appendingPathComponent("logs/steam-1055540"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("logs/steam-1055540"), withDestinationURL: root)
        do { try await archive.synchronize(catalog); XCTFail("A linked game folder must be rejected") } catch {}
        let unsafe = DiagnosticArchive.folderName(.init(source: "../steam", value: "../../save.dat"))
        XCTAssertFalse(unsafe.contains("/")); XCTAssertFalse(unsafe.contains(".."))
        XCTAssertNotEqual(unsafe, DiagnosticArchive.folderName(.init(source: "steam", value: "save.dat")))
        XCTAssertNotEqual(DiagnosticArchive.folderName(.init(source: "a-b", value: "c")), DiagnosticArchive.folderName(.init(source: "a", value: "b-c")))
    }
}
