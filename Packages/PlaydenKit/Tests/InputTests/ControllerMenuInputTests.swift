import XCTest
@testable import Input

final class ControllerMenuInputTests: XCTestCase {
    func testBufferedRapidDpadTapsRetainEveryReleaseAndPress() {
        var input = ControllerMenuInput()
        var steps = 0
        // All of these samples can arrive between two UI ticks.
        for index in 0..<5 {
            let time = Double(index) * 0.012
            let actions = input.consume(.init(direction: .right), at: time)
            for action in actions { if case .move(.right) = action { steps += 1 } }
            XCTAssertTrue(input.consume(.init(), at: time + 0.004).isEmpty)
        }
        XCTAssertEqual(steps, 5)
        XCTAssertTrue(input.advance(at: 0.5).isEmpty, "No phantom repeat after release")
    }

    func testBufferedFaceButtonTapsFireOnceEachWithoutTickDuplicates() {
        var input = ControllerMenuInput()
        var confirms = 0
        for index in 0..<4 {
            let time = Double(index) * 0.01
            for action in input.consume(.init(buttons: [.south]), at: time) {
                if case .confirm = action { confirms += 1 }
            }
            XCTAssertTrue(input.advance(at: time + 0.001).isEmpty)
            XCTAssertTrue(input.consume(.init(), at: time + 0.002).isEmpty)
        }
        XCTAssertEqual(confirms, 4)
    }

    func testHeldDirectionRepeatsFasterButRetainsInitialPause() {
        var input = ControllerMenuInput()
        XCTAssertEqual(input.consume(.init(direction: .right), at: 0).count, 1)
        XCTAssertTrue(input.advance(at: 0.399).isEmpty)
        XCTAssertEqual(input.advance(at: 0.4).count, 1)
        XCTAssertTrue(input.advance(at: 0.48).isEmpty)
        XCTAssertEqual(input.advance(at: 0.491).count, 1)
        XCTAssertEqual(input.advance(at: 1.5).count, 1)
        XCTAssertTrue(input.advance(at: 1.54).isEmpty)
        XCTAssertEqual(input.advance(at: 1.551).count, 1)
        XCTAssertTrue(input.consume(.init(), at: 1.56).isEmpty)
        XCTAssertTrue(input.advance(at: 3).isEmpty)
    }

    func testBufferedHomeTapAndHeldHomeRemainDistinct() {
        var input = ControllerMenuInput()
        XCTAssertTrue(input.consume(.init(buttons: [.home]), at: 0).isEmpty)
        let tap = input.consume(.init(), at: 0.05)
        guard tap.count == 1, case .home = tap[0] else { return XCTFail("Expected Home tap") }
        XCTAssertTrue(input.consume(.init(buttons: [.home]), at: 1).isEmpty)
        let hold = input.advance(at: 2)
        guard hold.count == 1, case .holdHome = hold[0] else { return XCTFail("Expected held Home") }
        XCTAssertTrue(input.consume(.init(), at: 3).isEmpty)
    }

    func testDisconnectResetDoesNotKeepDirectionOrHomeHeld() {
        var input = ControllerMenuInput()
        _ = input.consume(.init(direction: .right, buttons: [.home]), at: 0)
        input = .init()
        XCTAssertTrue(input.advance(at: 3).isEmpty)
    }
}
