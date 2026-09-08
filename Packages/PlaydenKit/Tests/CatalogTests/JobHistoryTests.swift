import XCTest
import Domain
import Catalog

final class JobHistoryTests: XCTestCase {
    func testDismissalSurvivesReopenWithoutMutatingJobOrLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Playden-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("catalog.sqlite").path
        let catalog = try CatalogStore(path: path)
        var job = JobRecord(gameID: .init(source: "fake", value: "one"))
        job.state = .failed; job.stage = .createBottle
        job.failure = .init(stage: "Create bottle", reason: "Runtime unavailable", output: "Preserved diagnostic output")
        try catalog.saveJob(job)
        let dismissal = try catalog.dismissJobHistory(job)
        let reopened = try CatalogStore(path: path)
        XCTAssertEqual(try reopened.jobs(), [job])
        XCTAssertEqual(try reopened.jobHistoryDismissals(), [dismissal])
        XCTAssertTrue(dismissal.hides(job))
        try reopened.revealJobHistory(job.id)
        XCTAssertTrue(try reopened.jobHistoryDismissals().isEmpty)
        XCTAssertEqual(try reopened.jobs().first?.failure?.output, "Preserved diagnostic output")
    }
    func testActiveAndStaleDismissalsAreRejectedAndNewFailureReappears() throws {
        let catalog = try CatalogStore()
        var job = JobRecord(gameID: .init(source: "fake", value: "two"))
        job.state = .running; try catalog.saveJob(job)
        XCTAssertThrowsError(try catalog.dismissJobHistory(job))
        job.state = .failed; try catalog.saveJob(job)
        let old = job, dismissal = try catalog.dismissJobHistory(job)
        job.state = .queued; job.updatedAt = job.updatedAt.addingTimeInterval(1); try catalog.saveJob(job)
        XCTAssertFalse(dismissal.hides(job))
        XCTAssertThrowsError(try catalog.dismissJobHistory(old))
        job.state = .failed; job.updatedAt = job.updatedAt.addingTimeInterval(1); try catalog.saveJob(job)
        XCTAssertFalse(dismissal.hides(job))
        XCTAssertThrowsError(try catalog.dismissJobHistory(old))
        XCTAssertTrue(try catalog.dismissJobHistory(job).hides(job))
    }
}
