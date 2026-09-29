import XCTest
import Domain
import Sessions
@testable import Playden

private actor FailingStartupSessions: SessionManaging {
    func retryCheckpoint(sessionID: UUID) async throws {}
    func start(downloadWhilePlaying: Bool) async throws { throw CocoaError(.coderReadCorrupt) }
    func updates() -> AsyncStream<SessionSnapshot> { AsyncStream { $0.finish() } }
    func play(_ gameID: GameID) async throws {}
    func retryCloud(authorization: CloudSyncAuthorization?) async throws {}
    func playOffline() async throws {}
    func quit() async throws {}
    func setDownloadWhilePlaying(_ enabled: Bool) async throws {}
    func shutdown() async throws {}
}

final class StartupRecoveryInteractionTests: XCTestCase {
    @MainActor func testFailedStartupCheckSaysDownloadsArePaused() async throws {
        let model = LibraryModel(preview: false, sessions: FailingStartupSessions())
        defer { model.stopServices() }
        model.startSessionServices()
        await model.sessionStartup?.value
        XCTAssertEqual(model.sessionIssue?.stage, "Downloads paused")
        XCTAssertTrue(model.sessionIssue?.reason.hasPrefix("Playden couldn’t check whether a game was left running, so downloads are paused.") == true)
        XCTAssertEqual(model.sessionIssueActions.first, "Retry")

        var job = JobRecord(gameID: GameID(source: SourceID.epic, value: "Delores"))
        job.state = .paused; job.pauseReasons = [.gameplay]
        XCTAssertEqual(model.downloadStatusTitle(for: job), "Paused · startup check", "No game is running, so it isn't paused for play")
        job.pauseReasons = [.gameplay, .user]
        XCTAssertEqual(model.downloadStatusTitle(for: job), "Paused")
    }
}
