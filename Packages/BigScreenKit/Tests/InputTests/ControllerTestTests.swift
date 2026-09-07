import XCTest
@testable import Input

final class ControllerTestTests: XCTestCase {
    private func device(_ buttons: [ControllerControl: Float] = [:], id: String = "pad") -> ControllerSnapshot {
        .init(id: id, name: "Test controller", playStation: true, buttons: buttons)
    }
    func testShortBackCanBeTestedAndHoldCloses() {
        var state = ControllerTestState()
        XCTAssertFalse(state.update([device()], at: 1))
        XCTAssertFalse(state.update([device([.east: 1])], at: 2))
        XCTAssertFalse(state.update([device()], at: 2.1))
        XCTAssertTrue(state.tested["pad"]?.contains(.east) == true)
        XCTAssertEqual(state.closeProgress, 0)
        XCTAssertFalse(state.update([device([.east: 1])], at: 3))
        XCTAssertFalse(state.update([device([.east: 1])], at: 3.6))
        XCTAssertEqual(state.closeProgress, 0.5, accuracy: 0.001)
        XCTAssertTrue(state.update([device([.east: 1])], at: 4.21))
    }
    func testDisconnectClearsLiveInputAndRestartsHold() {
        var state = ControllerTestState()
        state.update([device([.east: 1])], at: 1)
        XCTAssertFalse(state.update([], at: 5))
        XCTAssertNil(state.selected)
        XCTAssertEqual(state.closeProgress, 0)
        XCTAssertFalse(state.update([device([.east: 1], id: "replacement")], at: 6))
        XCTAssertEqual(state.selected?.id, "replacement")
        XCTAssertEqual(state.closeProgress, 0)
    }
    func testMostRecentlyUsedPadReceivesReadoutAndOwnHistory() {
        var state = ControllerTestState()
        state.update([device(), device(id: "second")], at: 1)
        state.update([device(), device([.north: 1], id: "second")], at: 2)
        XCTAssertEqual(state.selected?.id, "second")
        XCTAssertEqual(state.lastInput, "△")
        XCTAssertTrue(state.tested["second"]?.contains(.north) == true)
        XCTAssertFalse(state.tested["pad"]?.contains(.north) == true)
        state.update([device([.south: 1]), device(id: "second")], at: 3)
        XCTAssertEqual(state.selected?.id, "pad")
        XCTAssertEqual(state.lastInput, "✕")
    }
    func testInvalidAnalogReadingsAreClampedAndQuantized() {
        let snapshot = ControllerSnapshot(id: "pad", name: "Fixture", playStation: false,
            buttons: [.leftTrigger: .nan, .rightTrigger: 1.5, .south: -1],
            leftStick: .init(x: .infinity, y: -1.5), rightStick: .init(x: 0.3333, y: 0.004))
        XCTAssertEqual(snapshot.buttons[.leftTrigger], 0)
        XCTAssertEqual(snapshot.buttons[.rightTrigger], 1)
        XCTAssertEqual(snapshot.pressed, [.rightTrigger])
        XCTAssertEqual(snapshot.leftStick, .init(x: 0, y: -1))
        XCTAssertEqual(snapshot.rightStick, .init(x: 0.33, y: 0))
    }
}
