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
    var snapshot = SessionSnapshot()
    var observer: AsyncStream<SessionSnapshot>.Continuation?
    let game: SourceGameRecord
    init(_ game: SourceGameRecord) { self.game = game }
    func start(downloadWhilePlaying: Bool) async throws {}
    func updates() -> AsyncStream<SessionSnapshot> { AsyncStream { observer = $0; $0.yield(snapshot) } }
    func play(_ id: GameID) async throws {
        plays.append(id)
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
        model.sessionIssue = .init(stage: "Game closed unexpectedly", reason: "Test failure", output: "")
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
    func testTileBadgesDistinguishRunningAndUserCompatibility() {
        var game = Game(id: id, title: "A Short Hike", status: .installed, compatibility: .works)
        XCTAssertEqual(GameTile(game: game, focused: false).badge?.0, "Works")
        XCTAssertEqual(GameTile(game: game, focused: false, running: true).badge?.0, "Running")
        game.compatibility = .playable
        XCTAssertEqual(GameTile(game: game, focused: false).badge?.0, "Playable")
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
}
