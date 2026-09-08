import XCTest
import Domain
import Sessions
import Input
@testable import BigScreen

private actor CloudSessionFixture: SessionManaging {
    var reviews: [CloudSyncAuthorization?] = []
    var offlineCount = 0, quitCount = 0
    func start(downloadWhilePlaying: Bool) async throws {}
    func updates() -> AsyncStream<SessionSnapshot> { AsyncStream { $0.finish() } }
    func play(_ gameID: GameID) async throws {}
    func retryCloud(authorization: CloudSyncAuthorization?) async throws { reviews.append(authorization) }
    func playOffline() async throws { offlineCount += 1 }
    func quit() async throws { quitCount += 1 }
    func setDownloadWhilePlaying(_ enabled: Bool) async throws {}
    func shutdown() async throws {}
}
private actor CloudUIFixture: CloudSyncManaging {
    func recoverInterruptedOperations() async throws {}
    func updates() -> AsyncStream<[GameID: CloudSyncStatus]> { AsyncStream { $0.finish() } }
    func synchronize(_ installation: InstallationRecord, mapping: SaveMapping, preparingSessionID: UUID?, authorization: CloudSyncAuthorization?) async -> CloudSyncStatus {
        .init(gameID: installation.gameID, state: .upToDate, message: "Up to date")
    }
}

@MainActor final class CloudInteractionTests: XCTestCase {
    private func model() -> (LibraryModel, CloudSessionFixture) {
        let sessions = CloudSessionFixture()
        let model = LibraryModel(sessions: sessions, cloud: CloudUIFixture())
        model.fixedClock = true; model.configureCloudSnapshot("cloud-conflict")
        return (model, sessions)
    }
    func testCloudActionAndConflictChoicesAreReachableWithDirectionalInput() throws {
        let (model, _) = model(), id = try XCTUnwrap(model.detailID)
        model.panel = nil
        model.detailAction = try XCTUnwrap(model.detailActions.firstIndex(of: "Cloud saves"))
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .cloudSaves(id))
        XCTAssertEqual(model.cloudChoices(id)[model.panelIndex], .close)
        for _ in 0..<10 { model.perform(.move(.left)) }
        XCTAssertEqual(model.cloudChoices(id)[model.panelIndex], .local)
        model.perform(.move(.right))
        XCTAssertEqual(model.cloudChoices(id)[model.panelIndex], .remote)
        model.perform(.move(.down))
        XCTAssertEqual(model.cloudChoices(id)[model.panelIndex], .retry)
    }
    func testSelectedCopyUsesDisplayedReviewEvenIfNewStatusArrives() async throws {
        let (model, sessions) = model(), id = try XCTUnwrap(model.detailID)
        let displayed = try XCTUnwrap(model.cloudReview)
        var newer = displayed; newer.version += 1
        model.cloudStatuses[id] = .init(gameID: id, state: .conflict, operation: newer, message: "New review")
        model.panelIndex = try XCTUnwrap(model.cloudChoices(id).firstIndex(of: .remote))
        model.perform(.confirm)
        await model.sessionCommand?.value
        let sent = await sessions.reviews
        XCTAssertEqual(sent.count, 1); XCTAssertEqual(sent[0]?.operation, displayed)
        XCTAssertEqual(sent[0]?.conflictChoice, .remote); XCTAssertEqual(sent[0]?.attachAccount, true)
        XCTAssertNil(model.panel)
    }
    func testOfflineChoiceIsExplicitAndUnavailableDuringLocalRecovery() async throws {
        let (model, sessions) = model(), id = try XCTUnwrap(model.detailID)
        model.activateCloud(.offline, id: id); await model.sessionCommand?.value
        let count = await sessions.offlineCount; XCTAssertEqual(count, 1)
        let blocked = CloudSyncStatus(gameID: id, state: .failed, message: "Local recovery required", canPlayOffline: false)
        model.session.cloudStatus = blocked; model.cloudStatuses[id] = blocked; model.showCloud(id)
        XCTAssertFalse(model.cloudChoices(id).contains(.offline))
        model.activateCloud(.offline, id: id)
        let unchanged = await sessions.offlineCount; XCTAssertEqual(unchanged, 1)
    }
    func testLocalRecoveryChoicesUseExactReviewAndDoNotAttachSteamAccount() async throws {
        let (model, sessions) = model()
        model.configureCloudSnapshot("cloud-recovery")
        let id = try XCTUnwrap(model.detailID), review = try XCTUnwrap(model.cloudReview)
        XCTAssertEqual(model.cloudChoices(id), [.local, .remote, .retry, .close])
        XCTAssertEqual(model.cloudChoiceTitle(.local, id: id), "Keep current files")
        XCTAssertEqual(model.cloudChoiceTitle(.remote, id: id), "Restore recovered files")
        for _ in 0..<10 { model.perform(.move(.left)) }
        model.perform(.move(.right)); model.perform(.confirm)
        await model.sessionCommand?.value
        let sent = await sessions.reviews
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0]?.operation, review)
        XCTAssertEqual(sent[0]?.conflictChoice, .remote)
        XCTAssertEqual(sent[0]?.attachAccount, false)
        let offline = await sessions.offlineCount; XCTAssertEqual(offline, 0)
    }
    func testBackCancelsWaitingLaunchAndCannotLeaveAnInvisibleReservation() async throws {
        let (model, sessions) = model()
        model.perform(.back); await model.sessionCommand?.value
        XCTAssertNil(model.panel)
        let count = await sessions.quitCount; XCTAssertEqual(count, 1)
    }
    func testClosingBackgroundReviewKeepsDurableTransferAlive() async throws {
        let (model, _) = model(), id = try XCTUnwrap(model.detailID)
        model.session = .init()
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        model.cloudCommands[id] = task
        model.perform(.back)
        XCTAssertNil(model.panel); XCTAssertFalse(task.isCancelled)
        await model.stopCloudCommands()
        XCTAssertTrue(task.isCancelled); XCTAssertTrue(model.cloudCommands.isEmpty)
    }
    func testUnsupportedMappingIsHonestAndPostExitSyncReturnsToLauncherOnce() throws {
        let (model, _) = model(), id = try XCTUnwrap(model.detailID)
        model.session = .init(); model.cloudStatuses = [:]; model.cloudAvailability[id] = false
        XCTAssertEqual(model.cloudLabel(id), "Unavailable")
        XCTAssertEqual(model.cloudChoices(id), [.close])
        XCTAssertTrue(model.cloudMessage(id).contains("not supported"))
        var returns = 0; model.onGameEnded = { returns += 1 }
        model.configureCloudSnapshot("cloud-syncing")
        let syncing = model.session
        model.session = .init(phase: .running, game: syncing.game, session: syncing.session)
        model.receiveSession(syncing)
        model.perform(.back)
        XCTAssertEqual(model.panel, .cloudSaves(id)); XCTAssertFalse(model.exitOverlay)
        var ended = syncing; ended.phase = .idle; ended.session?.endedAt = .now; ended.session?.outcome = .clean
        model.receiveSession(ended)
        XCTAssertEqual(returns, 1)
    }
}
