import XCTest
import Domain
import Catalog
@testable import BigScreen

final class DownloadHistoryTests: XCTestCase {
    private func job(_ title: String, state: JobState, time: TimeInterval) -> JobRecord {
        var value = JobRecord(gameID: .init(source: "fake", value: title), createdAt: Date(timeIntervalSince1970: time))
        value.state = state
        return value
    }
    @MainActor func testDismissUsesKeyboardFocusAndPersistsWithoutRevealingOlderHistory() throws {
        let catalog = try CatalogStore()
        let old = job("one", state: .completed, time: 1), latest = job("one", state: .completed, time: 2), other = job("two", state: .completed, time: 3)
        for value in [old, latest, other] { try catalog.saveJob(value) }
        try catalog.replaceSourceCatalog(source: "fake", games: [.init(id: latest.gameID, title: "One"), .init(id: other.gameID, title: "Two")])
        let model = LibraryModel(catalog: catalog, preview: false)
        model.installJobs = [old, latest, other]; model.selectTab(.downloads)
        XCTAssertEqual(model.visibleInstallJobs.map(\.id), [other.id, latest.id])
        model.downloadIndex = 1; model.perform(.confirm)
        XCTAssertEqual(model.panel, .downloadActions(latest.gameID))
        model.downloadIndex = 0
        XCTAssertEqual(model.panelTitle, "One", "Menu title stays bound to the job even when rows move")
        model.perform(.move(.down)); model.perform(.move(.down)); model.perform(.confirm)
        XCTAssertEqual(model.visibleInstallJobs.map(\.id), [other.id])
        XCTAssertEqual(model.downloadIndex, 0); XCTAssertNil(model.panel)
        XCTAssertEqual(model.liveJob(for: latest.gameID), latest, "Game status and logs retain the latest job")
        let reopened = LibraryModel(catalog: catalog, preview: false); reopened.installJobs = try catalog.jobs()
        XCTAssertEqual(reopened.visibleInstallJobs.map(\.id), [other.id])
        reopened.dismissDownloadHistory(other)
        XCTAssertTrue(reopened.downloadGames.isEmpty); XCTAssertTrue(reopened.tabsFocused)
        XCTAssertEqual(reopened.downloadScrollOffset, 0)
    }
    @MainActor func testDismissedFailureRemainsActionableAndRetryMakesItVisible() throws {
        let catalog = try CatalogStore()
        let failed = job("failed", state: .failed, time: 1)
        try catalog.saveJob(failed)
        try catalog.replaceSourceCatalog(source: "fake", games: [.init(id: failed.gameID, title: "Failed game")])
        let model = LibraryModel(catalog: catalog, preview: false); model.installJobs = [failed]; model.applyInstallStatuses()
        model.dismissDownloadHistory(failed)
        XCTAssertTrue(model.visibleInstallJobs.isEmpty); XCTAssertTrue(model.hasDismissedFailedDownloads)
        model.openGame(try XCTUnwrap(model.games.first))
        XCTAssertEqual(model.detailActions.first, "View download")
        model.perform(.confirm)
        XCTAssertEqual(model.tab, .downloads); XCTAssertEqual(model.downloadGames.first?.id, failed.gameID)
        XCTAssertTrue(try catalog.jobHistoryDismissals().isEmpty)
        model.dismissDownloadHistory(failed)
        var retry = failed; retry.state = .queued; retry.updatedAt = retry.updatedAt.addingTimeInterval(1)
        try catalog.saveJob(retry); model.installJobs = [retry]
        XCTAssertEqual(model.visibleInstallJobs.map(\.id), [retry.id])
        XCTAssertFalse(model.downloadActions(for: retry.gameID).contains("Dismiss from history"))
    }
    @MainActor func testOldPanelCannotDismissNewFailure() throws {
        let catalog = try CatalogStore()
        let live = LibraryModel(catalog: catalog, preview: false)
        var failed = job("stale", state: .failed, time: 1)
        try catalog.saveJob(failed); live.installJobs = [failed]; live.show(.downloadActions(failed.gameID))
        failed.updatedAt = failed.updatedAt.addingTimeInterval(1)
        try catalog.saveJob(failed); live.installJobs = [failed]
        live.activateDownloadAction("Dismiss from history", id: failed.gameID)
        XCTAssertTrue(try catalog.jobHistoryDismissals().isEmpty)
        XCTAssertEqual(live.visibleInstallJobs.count, 1)
        guard case .information = live.panel else { return XCTFail("Changed job should stay visible with an actionable explanation") }
    }
}
