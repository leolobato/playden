import XCTest
import Domain
import Catalog
import Sessions
import Input
@testable import BigScreen

private actor SessionFixture: SessionManaging {
    func retryCloud(authorization: CloudSyncAuthorization?) async throws { throw SourceFailure.unavailable }
    func playOffline() async throws { throw SourceFailure.unavailable }
    var plays: [GameID] = []
    var quitCount = 0
    var startCount = 0
    var failStart = false
    var failPlay = false
    func failNextStart() { failStart = true }
    func failNextPlay() { failPlay = true }
    var snapshot = SessionSnapshot()
    var observer: AsyncStream<SessionSnapshot>.Continuation?
    let game: SourceGameRecord
    init(_ game: SourceGameRecord) { self.game = game }
    func start(downloadWhilePlaying: Bool) async throws {
        startCount += 1
        if failStart { failStart = false; throw SourceFailure.unavailable }
    }
    func updates() -> AsyncStream<SessionSnapshot> { AsyncStream { observer = $0; $0.yield(snapshot) } }
    func play(_ id: GameID) async throws {
        plays.append(id)
        if failPlay { failPlay = false; throw OperationFailure(stage: "Check files", reason: "Reconnect the games drive.", output: "Fixture") }
        snapshot = .init(phase: .preparing, game: game, session: .init(gameID: id, bottleID: "test"))
        observer?.yield(snapshot)
    }
    func quit() async throws {
        quitCount += 1; snapshot.phase = .idle
        snapshot.session?.endedAt = .now; snapshot.session?.outcome = .clean
        observer?.yield(snapshot)
    }
    func setDownloadWhilePlaying(_ enabled: Bool) async throws {}
    func shutdown() async throws {}
}
@MainActor
final class SessionInteractionTests: XCTestCase {
    private let id = GameID(source: "fixture", value: "play")
    private func snapshot(phase: SessionPhase = .running) -> SessionSnapshot {
        let game = SourceGameRecord(id: id, title: "A Short Hike")
        let bottle = GameBottle(gameID: id, name: "fixture", ownershipToken: UUID())
        let identity = ProcessIdentity(pid: 99999, startSeconds: 1, startMicroseconds: 0)
        var played = PlaySessionRecord(gameID: id, bottleID: bottle.name)
        played.runtime = .init(run: .init(bottle: bottle, launcher: identity), phase: .running, window: .init(id: 1, process: identity), hadWindow: true)
        return .init(phase: phase, game: game, session: played)
    }
    func testVisibleQuitActionsOpenConfirmationAndDisappearWhenSessionEnds() throws {
        let model = LibraryModel()
        model.games = [Game(id: id, title: "A Short Hike", status: .installed)]
        model.detailID = id
        model.receiveSession(snapshot())
        XCTAssertTrue(model.canShowGameControls)
        XCTAssertEqual(Array(model.detailActions.prefix(2)), ["Return to game", "Quit game"])
        model.detailAction = 1; model.activateDetail()
        XCTAssertTrue(model.exitOverlay); XCTAssertEqual(model.exitIndex, 0)
        model.setExitOverlay(false)
        model.show(.context); model.panelIndex = try XCTUnwrap(model.contextActions.firstIndex(of: "Quit game"))
        model.activatePanel()
        XCTAssertNil(model.panel); XCTAssertTrue(model.exitOverlay)
        model.receiveSession(.init())
        XCTAssertFalse(model.canShowGameControls)
        XCTAssertFalse(model.detailActions.contains("Quit game"))
        model.showGameControls(); XCTAssertFalse(model.exitOverlay)
    }
    func testFirstWindowHandsOffOnceAndExitReturnsHome() {
        let model = LibraryModel()
        var handoffs = 0, exits = 0
        model.onGameWindow = { _ in handoffs += 1 }; model.onGameEnded = { exits += 1 }
        model.sessionOrigin = .library
        var running = snapshot()
        model.receiveSession(running); model.receiveSession(running)
        XCTAssertEqual(handoffs, 1)
        model.perform(.holdHome); XCTAssertTrue(model.exitOverlay); XCTAssertEqual(model.exitIndex, 0)
        model.perform(.move(.down)); XCTAssertEqual(model.exitIndex, 1)
        model.perform(.back); XCTAssertFalse(model.exitOverlay); XCTAssertEqual(handoffs, 2)
        running.phase = .idle; running.session?.endedAt = .now; running.session?.outcome = .clean
        model.receiveSession(running)
        XCTAssertEqual(exits, 1); XCTAssertEqual(model.tab, .home); XCTAssertNil(model.detailID); XCTAssertEqual(model.detailAction, 0)
    }
    func testStartupWindowReplacementRetriesUntilAcknowledgedWithoutStealingLaterFocus() throws {
        let model = LibraryModel()
        var targets: [GameWindow] = []
        model.onGameWindow = { targets.append($0) }
        var running = snapshot()
        let first = try XCTUnwrap(running.session?.runtime?.window)
        model.receiveSession(running); model.receiveSession(running)
        XCTAssertEqual(targets, [first])
        let replacement = GameWindow(id: 2, process: first.process)
        running.session?.runtime?.window = replacement
        model.receiveSession(running)
        XCTAssertEqual(targets, [first, replacement])
        model.recordGameWindowHandoff(first); XCTAssertFalse(model.gameWindowHandedOff)
        model.recordGameWindowHandoff(replacement); XCTAssertTrue(model.gameWindowHandedOff)
        running.session?.runtime?.window = .init(id: 3, process: first.process)
        model.receiveSession(running)
        XCTAssertEqual(targets.count, 2)
        running.phase = .idle; running.session?.endedAt = .now; running.session?.outcome = .clean
        model.receiveSession(running); XCTAssertFalse(model.gameWindowHandedOff)
        let next = snapshot()
        model.receiveSession(next); XCTAssertEqual(targets.count, 3)
    }
    func testLaunchingTrapsNavigationAndOverlayRemainsEscapeHatch() {
        let model = LibraryModel(); model.session = snapshot(phase: .launching)
        model.tab = .library
        model.perform(.nextTab); model.perform(.home)
        XCTAssertEqual(model.tab, .library)
        model.perform(.back); XCTAssertTrue(model.exitOverlay)
        model.perform(.nextTab); XCTAssertEqual(model.tab, .library)
        model.perform(.confirm); XCTAssertFalse(model.exitOverlay)
    }
    func testNotificationActionsHaveTheirOwnFocusAndDoNotStealSortFilter() {
        let model = LibraryModel(); model.tab = .library
        model.session = snapshot(phase: .idle)
        model.reportSessionIssue(.init(stage: "Game closed unexpectedly", reason: "Test failure", output: ""), gameID: id)
        model.perform(.options)
        XCTAssertEqual(model.panel, .filters)
        model.perform(.back)
        let cursor = model.libraryCursor
        model.perform(.context)
        XCTAssertTrue(model.sessionIssueFocused); XCTAssertEqual(model.sessionIssueIndex, 0)
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .logs(id))
        model.perform(.back); model.perform(.context); model.perform(.move(.right))
        XCTAssertEqual(model.sessionIssueIndex, 1)
        XCTAssertEqual(model.libraryCursor, cursor)
        model.perform(.confirm)
        XCTAssertNil(model.sessionIssue); XCTAssertFalse(model.sessionIssueFocused)
    }
    func testNotificationFocusDoesNotInterceptOtherPanelsAndFocusWarningEndsWithGame() {
        let model = LibraryModel(); model.session = snapshot(phase: .idle)
        model.sessionIssue = .init(stage: "Test", reason: "Test", output: "")
        model.show(.search); model.perform(.context)
        XCTAssertFalse(model.sessionIssueFocused); XCTAssertEqual(model.panel, .search)
        model.panel = nil; model.session = snapshot()
        model.sessionIssue = .init(stage: "Return to game", reason: "Focus declined", output: "")
        var ended = snapshot(phase: .idle); ended.session?.endedAt = .now; ended.session?.outcome = .clean
        model.receiveSession(ended)
        XCTAssertNil(model.sessionIssue)
    }
    func testHomeExitReturnsHomeButEarlyFailureReturnsGamePage() {
        for failed in [false, true] {
            let model = LibraryModel(); model.sessionOrigin = .home
            var value = snapshot(phase: .idle)
            value.session?.endedAt = .now; value.session?.outcome = failed ? .launchFailed : .clean
            model.receiveSession(value)
            XCTAssertEqual(model.tab, .home)
            XCTAssertEqual(model.detailID, failed ? id : nil)
        }
    }
    func testExitFromLibraryFocusesPlayedGameOrVisibleHomeFallbackWithoutChangingRating() {
        for hidden in [false, true] {
            let model = LibraryModel(preview: false)
            let other = GameID(source: "fixture", value: "other")
            model.games = [Game(id: other, title: "Other", lastPlayedAt: Date(timeIntervalSince1970: 3)),
                           Game(id: id, title: "A Short Hike", status: .installed, compatibility: .works,
                                isHidden: hidden, lastPlayedAt: Date(timeIntervalSince1970: 2))]
            model.sessionOrigin = .library; model.tab = .library
            var value = snapshot()
            model.receiveSession(value)
            XCTAssertTrue(model.isGameRunning(id)); XCTAssertFalse(model.isGameRunning(other))
            value.phase = .idle; value.session?.endedAt = .now; value.session?.outcome = .crash
            model.receiveSession(value)
            XCTAssertEqual(model.tab, .home); XCTAssertNil(model.detailID)
            XCTAssertEqual(model.focusedGame?.id, hidden ? other : id)
            XCTAssertEqual(model.games.first { $0.id == id }?.compatibility, .works)
            XCTAssertFalse(model.isGameRunning(id))
            XCTAssertNotNil(model.sessionIssue)
            model.stopServices()
        }
    }
    func testLaunchFailureFromLibraryKeepsGameDetails() {
        let model = LibraryModel(); model.sessionOrigin = .library
        var value = snapshot(phase: .idle)
        value.session?.endedAt = .now; value.session?.outcome = .launchFailed
        model.receiveSession(value)
        XCTAssertEqual(model.tab, .library); XCTAssertEqual(model.detailID, id)
    }
    func testTileBadgesShowRunningAndBrokenWithoutCoveringArtForOtherRatings() {
        var game = Game(id: id, title: "A Short Hike", status: .installed, compatibility: .works)
        XCTAssertNil(GameTile(game: game, focused: false).badge)
        XCTAssertEqual(GameTile(game: game, focused: false, running: true).badge?.0, "Running")
        game.compatibility = .playable
        XCTAssertNil(GameTile(game: game, focused: false).badge)
        game.status = .notInstalled
        XCTAssertTrue(GameTile(game: game, focused: false).showsDownloadMark)
        XCTAssertFalse(GameTile(game: game, focused: false, running: true).showsDownloadMark)
        game.compatibility = .broken
        XCTAssertEqual(GameTile(game: game, focused: false).badge?.0, "Broken")
        XCTAssertFalse(GameTile(game: game, focused: false).showsDownloadMark)
    }
    func testPlayUsesServiceAndSecondGameRequiresConfirmation() async throws {
        let game = SourceGameRecord(id: id, title: "A Short Hike"), catalog = try CatalogStore()
        try catalog.replaceSourceCatalog(source: id.source, games: [game])
        let service = SessionFixture(game), model = LibraryModel(catalog: catalog, preview: false, sessions: service)
        model.startSessionServices()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !model.sessionReady && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        model.beginPlay(id)
        await model.sessionCommand?.value
        while !model.hasActiveSession && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let plays = await service.plays; XCTAssertEqual(plays, [id])
        model.session.phase = .running
        let second = GameID(source: id.source, value: "other")
        model.beginPlay(second)
        XCTAssertEqual(model.panel, .confirmation(.switchGame(second)))
        model.perform(.back)
        let quits = await service.quitCount; XCTAssertEqual(quits, 0)
        model.stopServices()
    }
    func testFailureRetryUsesFailedGameAfterNavigatingElsewhere() async throws {
        let service = SessionFixture(.init(id: id, title: "A Short Hike"))
        let model = LibraryModel(preview: false, sessions: service)
        model.sessionReady = true
        var failed = snapshot(phase: .idle)
        failed.session?.endedAt = .now; failed.session?.outcome = .launchFailed
        failed.failure = .init(stage: "Prepare game", reason: "Preparation failed.", output: "Fixture")
        model.receiveSession(failed)
        XCTAssertEqual(model.sessionIssueActions, ["Retry", "View logs", "Dismiss"])
        let other = GameID(source: "fixture", value: "other")
        model.games = [.init(id: other, title: "Other")]; model.detailID = other
        model.perform(.context); model.perform(.confirm)
        await model.sessionCommand?.value
        let plays = await service.plays
        XCTAssertEqual(plays, [id]); XCTAssertNil(model.sessionIssue)
        model.stopServices()
    }
    func testRejectedPlayDoesNotUsePreviousSessionsGameOrLogIdentity() async throws {
        let requested = GameID(source: "fixture", value: "new")
        let service = SessionFixture(.init(id: requested, title: "Requested"))
        let model = LibraryModel(preview: false, sessions: service)
        model.sessionReady = true; model.session = snapshot(phase: .idle)
        await service.failNextPlay()
        model.beginPlay(requested); await model.sessionCommand?.value
        XCTAssertEqual(model.sessionIssueGameID, requested)
        model.sessionIssueIndex = 1; model.activateSessionIssue()
        XCTAssertEqual(model.panel, .logs(requested))
        model.panel = nil; model.sessionIssueIndex = 0; model.activateSessionIssue()
        await model.sessionCommand?.value
        let plays = await service.plays; XCTAssertEqual(plays, [requested, requested])
        model.stopServices()
    }
    func testRecoveryRetryRestartsRecoveryWithoutLaunchingPreviousGame() async throws {
        let service = SessionFixture(.init(id: id, title: "A Short Hike"))
        await service.failNextStart()
        let model = LibraryModel(preview: false, sessions: service)
        model.startSessionServices(); await model.sessionStartup?.value
        XCTAssertFalse(model.sessionReady)
        XCTAssertEqual(model.sessionIssueActions, ["Retry", "Dismiss"])
        model.retrySessionIssue(); await model.sessionCommand?.value
        XCTAssertTrue(model.sessionReady); XCTAssertNil(model.sessionIssue)
        let starts = await service.startCount, plays = await service.plays
        XCTAssertEqual(starts, 2); XCTAssertTrue(plays.isEmpty)
        model.stopServices()
    }
    func testLogRetryMatchesFailureIdentityAndHonorsSessionAndResetGuards() async throws {
        let service = SessionFixture(.init(id: id, title: "A Short Hike"))
        let catalog = try CatalogStore()
        let model = LibraryModel(catalog: catalog, preview: false, sessions: service)
        model.sessionReady = true
        var failed = snapshot(phase: .idle)
        failed.session?.endedAt = .now; failed.session?.outcome = .crash
        model.receiveSession(failed)
        let sessionID = try XCTUnwrap(failed.session?.id)
        model.logDocument = .init(id: UUID(), gameID: id, kind: "play session", startedAt: .now)
        XCTAssertNil(model.logRecovery)
        try catalog.saveSession(try XCTUnwrap(failed.session))
        model.show(.logs(id))
        XCTAssertEqual(model.logDocument?.id, sessionID)
        XCTAssertEqual(model.logActions, ["Close", "Retry"])
        model.resetBusy = true; model.retrySessionIssue(); XCTAssertNil(model.logRecovery)
        model.resetBusy = false; model.session.phase = .running
        model.retrySessionIssue(); XCTAssertNil(model.logRecovery)
        model.session.phase = .idle
        let before = await service.plays; XCTAssertTrue(before.isEmpty)
        model.logActionIndex = 1; model.activateLogAction(); await model.sessionCommand?.value
        let after = await service.plays; XCTAssertEqual(after, [id])
        model.stopServices()
    }
    func testUnrelatedFailureClearsOldRetryAndLogContext() {
        let model = LibraryModel()
        model.reportSessionIssue(.init(stage: "Launch", reason: "Failed", output: ""), gameID: id, recovery: .play(id))
        model.sessionIssue = .init(stage: "Other action", reason: "Failed", output: "")
        XCTAssertNil(model.sessionIssueRecovery); XCTAssertNil(model.sessionIssueGameID)
        XCTAssertEqual(model.sessionIssueActions, ["Dismiss"])
    }
    func testReopenedFailureLogOffersRetryButCannotReplaySupersededSession() async throws {
        let catalog = try CatalogStore()
        var failed = snapshot(phase: .idle)
        failed.session?.endedAt = .now; failed.session?.outcome = .launchFailed
        try catalog.saveSession(try XCTUnwrap(failed.session))
        let service = SessionFixture(.init(id: id, title: "A Short Hike"))
        let model = LibraryModel(catalog: catalog, preview: false, sessions: service)
        model.sessionReady = true; model.show(.logs(id))
        XCTAssertNil(model.sessionIssue)
        XCTAssertEqual(model.logActions, ["Close", "Retry"])
        var newer = PlaySessionRecord(gameID: id, bottleID: "fixture", startedAt: Date.now.addingTimeInterval(1))
        newer.endedAt = newer.startedAt.addingTimeInterval(1); newer.outcome = .clean
        try catalog.saveSession(newer)
        model.logActionIndex = 1; model.activateLogAction()
        let plays = await service.plays; XCTAssertTrue(plays.isEmpty)
        model.refreshLogView(id); XCTAssertEqual(model.logActions, ["Close"])
        model.stopServices()
    }
}
