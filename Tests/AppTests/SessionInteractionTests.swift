import XCTest
import Domain
import Catalog
import Sessions
import Input
@testable import BigScreen

private actor SessionFixture: SessionManaging {
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
    func testFirstWindowHandsOffOnceAndReturnRestoresGameFocus() {
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
        XCTAssertEqual(exits, 1); XCTAssertEqual(model.detailID, id); XCTAssertEqual(model.detailAction, 0)
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
