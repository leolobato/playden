import XCTest
import Domain
import Catalog
import Sessions
@testable import Playden

@MainActor
final class FirstRunFeedbackTests: XCTestCase {
    private let id = GameID(source: "fixture", value: "first-run")
    private func model(_ catalog: CatalogStore? = nil) throws -> LibraryModel {
        if let catalog { try catalog.replaceSourceCatalog(source: id.source, games: [.init(id: id, title: "First game")]) }
        let model = LibraryModel(catalog: catalog, preview: catalog == nil)
        model.games = [Game(id: id, title: "First game", status: .installed)]
        return model
    }
    private func played(outcome: SessionOutcome = .clean, runtime: Bool = true) -> PlaySessionRecord {
        var session = PlaySessionRecord(gameID: id, bottleID: "fixture", startedAt: Date(timeIntervalSince1970: 100))
        session.endedAt = session.startedAt.addingTimeInterval(60)
        session.lastCheckpointAt = session.endedAt!
        session.outcome = outcome
        if runtime {
            let bottle = GameBottle(gameID: id, name: "fixture", ownershipToken: UUID())
            session.runtime = .init(run: .init(bottle: bottle, launcher: .init(pid: 1, startSeconds: 1, startMicroseconds: 0)), phase: .exited, hadWindow: outcome != .launchFailed)
        }
        return session
    }

    func testFirstExitPresentsOnceAndPersistsAcrossRestart() throws {
        let catalog = try CatalogStore(), model = try model(catalog)
        defer { model.stopServices() }
        let completed = played()
        try catalog.saveSession(completed)
        model.session = .init(phase: .running, session: completed)
        model.receiveSession(.init(phase: .idle, session: completed))
        XCTAssertEqual(model.panel, .firstRunFeedback(id))
        XCTAssertEqual(try catalog.preferences().firstRunFeedbackShown, [id])
        model.perform(.back)
        model.receiveSession(.init(phase: .idle, session: completed))
        XCTAssertNil(model.panel)
        let restored = try self.model(catalog)
        defer { restored.stopServices() }
        restored.queueFirstRunFeedback(for: completed)
        XCTAssertNil(restored.panel)
    }

    func testRatingsPersistAndIssuesOfferSettingsForTheRatedGame() throws {
        let catalog = try CatalogStore(), model = try model(catalog)
        defer { model.stopServices() }
        model.queueFirstRunFeedback(for: played())
        model.perform(.move(.down)); model.perform(.confirm)
        XCTAssertEqual(model.firstRunRating, .playable)
        XCTAssertEqual(try catalog.edits(for: id).compatibility, .playable)
        XCTAssertEqual(model.panelIndex, 3)
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .gameSettings(id))
    }

    func testGoodRatingFocusesDoneAndSkipDoesNotChangeRating() throws {
        let model = try model()
        model.queueFirstRunFeedback(for: played())
        model.perform(.confirm)
        XCTAssertEqual(model.games[0].compatibility, .works)
        XCTAssertEqual(model.panelIndex, 4)
        model.perform(.confirm)
        XCTAssertNil(model.panel)
        let skipped = try self.model()
        skipped.queueFirstRunFeedback(for: played())
        skipped.perform(.back)
        XCTAssertEqual(skipped.games[0].compatibility, .untested)
        skipped.queueFirstRunFeedback(for: played())
        XCTAssertNil(skipped.panel)
    }

    func testExistingPlayHistoryAndPrelaunchFailuresAreNotFirstRun() throws {
        let catalog = try CatalogStore(), model = try model(catalog)
        defer { model.stopServices() }
        try catalog.saveSession(played())
        model.queueFirstRunFeedback(for: played()) // A different session UUID.
        XCTAssertNil(model.panel)
        let fresh = try self.model()
        fresh.queueFirstRunFeedback(for: played(outcome: .launchFailed, runtime: false))
        XCTAssertNil(fresh.panel)
        fresh.queueFirstRunFeedback(for: played(outcome: .launchFailed))
        XCTAssertEqual(fresh.panel, .firstRunFeedback(id))
        fresh.panelIndex = 2; fresh.perform(.confirm)
        XCTAssertEqual(fresh.games[0].compatibility, .broken)
    }

    func testCloudReviewIsNotReplacedAndClosingItPresentsCheckIn() async throws {
        let model = try model()
        model.show(.cloudSaves(id))
        model.queueFirstRunFeedback(for: played())
        XCTAssertEqual(model.panel, .cloudSaves(id))
        XCTAssertEqual(model.pendingFirstRunFeedback, id)
        model.panel = nil
        await Task.yield()
        model.presentFirstRunFeedbackIfReady()
        XCTAssertEqual(model.panel, .firstRunFeedback(id))
    }

    func testNeverPromptsWhilePlayingOrQuittingLauncher() throws {
        let model = try model()
        model.session = .init(phase: .running, session: played())
        model.queueFirstRunFeedback(for: played())
        XCTAssertNil(model.panel)
        model.session = .init()
        model.launcherQuitting = true
        model.presentFirstRunFeedbackIfReady()
        XCTAssertNil(model.panel)
    }
}
