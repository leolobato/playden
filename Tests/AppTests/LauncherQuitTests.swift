import XCTest
import AppKit
import Domain
import Sessions
@testable import Playden

@MainActor final class LauncherQuitTests: XCTestCase {
    func testControllerQueueQuitUnwindsAndWaitsForCleanupBeforeTerminating() async {
        let delegate = AppDelegate()
        let cleanupEntered = expectation(description: "Shutdown waits for existing work")
        var releaseCleanup: CheckedContinuation<Void, Never>?
        delegate.model.resetTask = Task {
            await withCheckedContinuation { continuation in
                releaseCleanup = continuation
                cleanupEntered.fulfill()
            }
        }
        await fulfillment(of: [cleanupEntered], timeout: 2)
        let finished = expectation(description: "Final termination requested after cleanup")
        var terminationRequests = 0
        delegate.terminateApplication = { [weak delegate] application in
            terminationRequests += 1
            XCTAssertEqual(delegate?.applicationShouldTerminate(application), .terminateNow)
            finished.fulfill()
        }
        let callbackReturned = expectation(description: "Controller dispatch callback returns")
        DispatchQueue.main.async {
            XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateCancel)
            XCTAssertTrue(delegate.model.launcherQuitting)
            XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateCancel)
            callbackReturned.fulfill()
        }
        await fulfillment(of: [callbackReturned], timeout: 2)
        XCTAssertEqual(terminationRequests, 0)
        releaseCleanup?.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(terminationRequests, 1)
    }

    func testAppTerminationStillRequiresActiveGameApproval() {
        let delegate = AppDelegate()
        delegate.model.session = running()
        delegate.terminateApplication = { _ in XCTFail("Unapproved quit must not terminate") }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateCancel)
        XCTAssertTrue(delegate.model.isConfirmingLauncherQuit)
        XCTAssertFalse(delegate.model.launcherQuitting)
        delegate.model.keepLauncherOpen()
        XCTAssertFalse(delegate.model.isConfirmingLauncherQuit)
        XCTAssertEqual(delegate.model.session.phase, .running)
    }

    private func running() -> SessionSnapshot {
        let game = SourceGameRecord(id: .init(source: "fixture", value: "hike"), title: "A Short Hike")
        return .init(phase: .running, game: game, session: .init(gameID: game.id, bottleID: "fixture"))
    }

    func testPreparationQuitRequiresConfirmationAndCancelKeepsJobRunning() {
        let model = LibraryModel()
        var job = JobRecord(gameID: .init(source: "fixture", value: "install"))
        job.state = .running; job.stage = .stage
        model.installJobs = [job]; model.activeInstallID = job.id
        var requests = 0; model.onLauncherQuit = { requests += 1 }
        XCTAssertFalse(model.hasActiveSession)
        model.quitLauncherFromUI()
        XCTAssertTrue(model.isConfirmingLauncherQuit); XCTAssertEqual(model.exitIndex, 0)
        XCTAssertTrue(model.launcherQuitConsequences.contains("File checks may restart"))
        model.perform(.confirm)
        XCTAssertFalse(model.exitOverlay); XCTAssertEqual(requests, 0)
        XCTAssertEqual(model.installJobs.first?.state, .running)
        model.requestLauncherQuit(); model.perform(.move(.down)); model.perform(.confirm)
        XCTAssertEqual(requests, 1); XCTAssertTrue(model.consumeLauncherQuitApproval())
        XCTAssertFalse(model.consumeLauncherQuitApproval())
        model.requestLauncherQuit()
        model.installJobs[0].state = .completed; model.reconcileLauncherQuitRequest()
        XCTAssertFalse(model.isConfirmingLauncherQuit); XCTAssertFalse(model.exitOverlay)
        XCTAssertFalse(model.requiresLauncherQuitConfirmation)
    }
    func testVisibleAppQuitUsesIdleShutdownAndActiveSessionConfirmation() {
        let model = LibraryModel()
        var requests = 0; model.onLauncherQuit = { requests += 1 }
        model.selectTab(.settings); model.settingsSection = 5; model.settingsRailFocused = true
        model.perform(.move(.down))
        XCTAssertEqual(model.settingsSection, 6); XCTAssertEqual(requests, 0)
        model.perform(.move(.right)); XCTAssertTrue(model.settingsRailFocused)
        model.perform(.confirm); XCTAssertEqual(requests, 1)
        model.session = running()
        model.quitLauncherFromUI()
        XCTAssertEqual(requests, 1); XCTAssertTrue(model.isConfirmingLauncherQuit)
        model.perform(.confirm) // Keep launcher open is selected by default.
        XCTAssertEqual(requests, 1); XCTAssertFalse(model.isConfirmingLauncherQuit)
        model.quitLauncherFromUI(); model.perform(.move(.down)); model.perform(.confirm)
        XCTAssertEqual(requests, 2); XCTAssertTrue(model.consumeLauncherQuitApproval())
    }

    func testQuitRequiresDirectionalConfirmationAndCancelKeepsGameRunning() {
        let model = LibraryModel(); model.session = running()
        var quitRequests = 0
        model.onLauncherQuit = { quitRequests += 1 }
        let sessionID = model.session.session?.id
        model.requestLauncherQuit()
        XCTAssertTrue(model.exitOverlay); XCTAssertTrue(model.isConfirmingLauncherQuit)
        XCTAssertEqual(model.exitIndex, 0)
        XCTAssertFalse(model.consumeLauncherQuitApproval())
        model.perform(.confirm)
        XCTAssertFalse(model.exitOverlay); XCTAssertFalse(model.isConfirmingLauncherQuit)
        XCTAssertEqual(quitRequests, 0)
        XCTAssertEqual(model.session.session?.id, sessionID)
        XCTAssertEqual(model.session.phase, .running)
        model.requestLauncherQuit(); model.perform(.move(.down)); model.perform(.back)
        XCTAssertFalse(model.isConfirmingLauncherQuit)
        XCTAssertEqual(quitRequests, 0)
    }

    func testApprovalIsOneUseAndShutdownTrapsFurtherInput() {
        let model = LibraryModel(); model.session = running()
        var approvals: [Bool] = []
        model.onLauncherQuit = {
            approvals.append(model.consumeLauncherQuitApproval())
            model.launcherQuitting = true
        }
        model.requestLauncherQuit()
        model.performController(.move(.down)); model.performController(.confirm)
        XCTAssertEqual(approvals, [true])
        XCTAssertFalse(model.consumeLauncherQuitApproval())
        model.perform(.confirm); model.perform(.back); model.perform(.holdHome)
        XCTAssertTrue(model.exitOverlay)
        XCTAssertTrue(model.launcherQuitting)
        XCTAssertEqual(approvals, [true])
        model.resetLauncherQuit()
        XCTAssertFalse(model.launcherQuitting)
        XCTAssertFalse(model.isConfirmingLauncherQuit)
    }

    func testSessionReplacementOrNaturalExitInvalidatesPendingApproval() {
        let model = LibraryModel(); model.session = running()
        var requests = 0; model.onLauncherQuit = { requests += 1 }
        model.requestLauncherQuit(); model.confirmLauncherQuit()
        XCTAssertEqual(requests, 1)
        model.receiveSession(running()) // Same title, distinct running session.
        XCTAssertFalse(model.consumeLauncherQuitApproval())
        XCTAssertFalse(model.isConfirmingLauncherQuit)
        XCTAssertFalse(model.exitOverlay)
        model.requestLauncherQuit()
        var ended = model.session; ended.phase = .idle
        ended.session?.endedAt = .now; ended.session?.outcome = .clean
        model.receiveSession(ended)
        XCTAssertFalse(model.isConfirmingLauncherQuit)
        XCTAssertFalse(model.consumeLauncherQuitApproval())
        model.confirmLauncherQuit()
        XCTAssertEqual(requests, 1)
    }

    func testQuitConfirmationTakesPriorityOverCloudAndControllerPanelsAndBusyCancelWorks() {
        let model = LibraryModel(); model.session = running()
        model.panel = .cloudSaves(model.session.game!.id)
        model.requestLauncherQuit(); model.perform(.move(.down))
        XCTAssertEqual(model.exitIndex, 1)
        XCTAssertEqual(model.panelIndex, 0)
        model.perform(.back)
        XCTAssertFalse(model.isConfirmingLauncherQuit)
        model.panel = .controllerTest
        model.requestLauncherQuit(); model.sessionBusy = true
        model.performController(.move(.down)); model.performController(.confirm)
        XCTAssertFalse(model.consumeLauncherQuitApproval())
        model.performController(.back)
        XCTAssertFalse(model.exitOverlay)
        XCTAssertEqual(model.panel, .controllerTest)
    }

    func testIdleLauncherDoesNotRequireGameConfirmation() {
        let model = LibraryModel()
        model.requestLauncherQuit()
        XCTAssertFalse(model.exitOverlay)
        XCTAssertFalse(model.isConfirmingLauncherQuit)
    }
}
