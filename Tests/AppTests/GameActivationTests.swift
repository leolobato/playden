import XCTest
import AppKit
import Domain
import Runner
@testable import Playden

@MainActor
private final class ActivationFixture: GameActivationSystem {
    var state: GameActivationState
    var requests: [GameWindow] = []
    var foreground = true
    func ownsForeground(_ window: GameWindow) -> Bool { foreground }
    init(_ state: GameActivationState) { self.state = state }
    func state(of window: GameWindow) -> GameActivationState { state }
    func requestActivation(of window: GameWindow) { requests.append(window) }
}

@MainActor
final class GameActivationTests: XCTestCase {
    let window = GameWindow(id: 123, process: .init(pid: 99999, startSeconds: 10, startMicroseconds: 20))

    func testAlreadyForegroundGameDoesNotRequireAnotherActivationRequest() async {
        let system = ActivationFixture(.active)
        var waits = 0
        let waiter = GameActivationWaiter(system: system, wait: { waits += 1 })
        let result = await waiter.activate(window)
        XCTAssertEqual(result, .active); XCTAssertTrue(system.requests.isEmpty)
        XCTAssertEqual(waits, 5)
    }

    func testWaitsForWineRegistrationAndObservedActivation() async {
        let system = ActivationFixture(.registering)
        var waits = 0
        let waiter = GameActivationWaiter(system: system, wait: {
            waits += 1
            if waits == 2 { system.state = .inactive }
            if waits == 4 { system.state = .active }
        })
        let result = await waiter.activate(window)
        XCTAssertEqual(result, .active)
        XCTAssertEqual(waits, 9); XCTAssertEqual(system.requests, [window])
    }

    func testSendingRequestDoesNotClaimForegroundAndTimeoutIsBounded() async {
        let system = ActivationFixture(.inactive)
        var waits = 0
        let waiter = GameActivationWaiter(system: system, wait: { waits += 1 })
        let result = await waiter.activate(window)
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(waits, 50); XCTAssertEqual(system.requests, Array(repeating: window, count: 10))
    }

    func testActiveAppOnAnotherSpaceDoesNotCompleteUntilWindowIsVisible() async {
        let system = ActivationFixture(.hidden)
        var waits = 0
        let waiter = GameActivationWaiter(system: system, wait: {
            waits += 1
            if waits == 7 { system.state = .active }
        })
        let result = await waiter.activate(window)
        XCTAssertEqual(result, .active)
        XCTAssertEqual(waits, 12)
        XCTAssertEqual(system.requests, [window, window])
    }

    func testDisappearingOrReplacedTargetCannotCompleteHandoff() async {
        let system = ActivationFixture(.inactive)
        let waiter = GameActivationWaiter(system: system, wait: { system.state = .unavailable })
        let result = await waiter.activate(window)
        XCTAssertEqual(result, .unavailable)
        let initiallyMissing = await waiter.activate(window)
        XCTAssertEqual(initiallyMissing, .unavailable); XCTAssertEqual(system.requests, [window])
    }

    func testOpeningOverlayOrEndingSessionCancelsPendingHandoff() async {
        let system = ActivationFixture(.registering)
        let sleeping = expectation(description: "Activation waiting for registration")
        let waiter = GameActivationWaiter(system: system, wait: {
            sleeping.fulfill()
            try await Task.sleep(for: .seconds(10))
        })
        let task = Task { await waiter.activate(window) }
        await fulfillment(of: [sleeping], timeout: 1)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled); XCTAssertTrue(system.requests.isEmpty)
    }

    func testTransientActivationDoesNotAcknowledgeWindowBehindOtherApps() async {
        let system = ActivationFixture(.active)
        var waits = 0
        let waiter = GameActivationWaiter(system: system, wait: {
            waits += 1
            if waits == 2 { system.state = .obscured }
            if waits == 4 { system.state = .active }
        })
        let result = await waiter.activate(window)
        XCTAssertEqual(result, .active)
        XCTAssertEqual(waits, 9)
        XCTAssertEqual(system.requests, [window])
    }

    func testReplacementStopsAsSoonAsPlayerSwitchesAway() async {
        let system = ActivationFixture(.obscured)
        let waiter = GameActivationWaiter(system: system, wait: { system.foreground = false })
        let result = await waiter.activate(window, preservingForeground: true)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(system.requests, [window])
        system.requests = []
        let alreadyAway = await waiter.activate(window, preservingForeground: true)
        XCTAssertEqual(alreadyAway, .cancelled)
        XCTAssertTrue(system.requests.isEmpty)
    }

    func testOnscreenCoveredWindowIsNotForegroundButOtherDisplaysAndOverlaysAreIgnored() {
        func entry(_ id: UInt32, pid: Int32, rect: CGRect, layer: Int = 0, onscreen: Bool = true) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
             kCGWindowBounds as String: rect.dictionaryRepresentation, kCGWindowLayer as String: layer,
             kCGWindowIsOnscreen as String: onscreen]
        }
        let rect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let game = entry(window.id, pid: window.process.pid, rect: rect)
        let other = entry(456, pid: 12345, rect: CGRect(x: 100, y: 100, width: 600, height: 400))
        XCTAssertTrue(MacGameActivationSystem.isObscured(window, in: [other, game]))
        XCTAssertFalse(MacGameActivationSystem.isObscured(window, in: [game, other]))
        XCTAssertFalse(MacGameActivationSystem.isObscured(window, in: [entry(456, pid: 12345, rect: CGRect(x: 1920, y: 0, width: 800, height: 600)), game]))
        XCTAssertFalse(MacGameActivationSystem.isObscured(window, in: [entry(456, pid: 12345, rect: rect, layer: 3), game]))
        XCTAssertFalse(MacGameActivationSystem.isObscured(window, in: [entry(456, pid: 12345, rect: rect, onscreen: false), game]))
        XCTAssertFalse(MacGameActivationSystem.isObscured(window, in: [entry(456, pid: window.process.pid, rect: rect), game]))
    }

    func testNativeInspectionRejectsReusedPIDAndMissingWindow() throws {
        let system = MacGameActivationSystem()
        let current = try XCTUnwrap(RuntimeProcessInspector().identity(of: getpid()))
        let reused = ProcessIdentity(pid: current.pid, startSeconds: current.startSeconds + 1, startMicroseconds: current.startMicroseconds)
        XCTAssertEqual(system.state(of: .init(id: 0, process: reused)), .unavailable)
        XCTAssertEqual(system.state(of: .init(id: 0, process: current)), .unavailable)
    }
}
