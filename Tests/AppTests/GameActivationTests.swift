import XCTest
import Domain
import Runner
@testable import BigScreen

@MainActor
private final class ActivationFixture: GameActivationSystem {
    var state: GameActivationState
    var requests: [GameWindow] = []
    init(_ state: GameActivationState) { self.state = state }
    func state(of window: GameWindow) -> GameActivationState { state }
    func requestActivation(of window: GameWindow) { requests.append(window) }
}

@MainActor
final class GameActivationTests: XCTestCase {
    let window = GameWindow(id: 123, process: .init(pid: 99999, startSeconds: 10, startMicroseconds: 20))

    func testAlreadyForegroundGameDoesNotRequireAnotherActivationRequest() async {
        let system = ActivationFixture(.active)
        let waiter = GameActivationWaiter(system: system, wait: { XCTFail("No delay needed") })
        let result = await waiter.activate(window)
        XCTAssertEqual(result, .active); XCTAssertTrue(system.requests.isEmpty)
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
        XCTAssertEqual(waits, 4); XCTAssertEqual(system.requests, [window])
    }

    func testSendingRequestDoesNotClaimForegroundAndTimeoutIsBounded() async {
        let system = ActivationFixture(.inactive)
        var waits = 0
        let waiter = GameActivationWaiter(system: system, wait: { waits += 1 })
        let result = await waiter.activate(window)
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(waits, 20); XCTAssertEqual(system.requests, [window])
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

    func testNativeInspectionRejectsReusedPIDAndMissingWindow() throws {
        let system = MacGameActivationSystem()
        let current = try XCTUnwrap(RuntimeProcessInspector().identity(of: getpid()))
        let reused = ProcessIdentity(pid: current.pid, startSeconds: current.startSeconds + 1, startMicroseconds: current.startMicroseconds)
        XCTAssertEqual(system.state(of: .init(id: 0, process: reused)), .unavailable)
        XCTAssertEqual(system.state(of: .init(id: 0, process: current)), .unavailable)
    }
}
