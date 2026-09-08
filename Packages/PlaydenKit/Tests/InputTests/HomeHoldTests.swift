import XCTest
@testable import Input

final class HomeHoldTests: XCTestCase {
    func testRequiresFullSecondAndOnlyFiresOnceUntilRelease() {
        var hold = HomeHold()
        XCTAssertFalse(hold.update(pressed: true, at: 10))
        XCTAssertFalse(hold.update(pressed: true, at: 10.99))
        XCTAssertTrue(hold.update(pressed: true, at: 11))
        XCTAssertFalse(hold.update(pressed: true, at: 15))
        XCTAssertFalse(hold.update(pressed: false, at: 16))
        XCTAssertFalse(hold.update(pressed: true, at: 17))
        XCTAssertTrue(hold.update(pressed: true, at: 18))
    }
    func testShortPressAndControllerResetCannotCompleteOldHold() {
        var hold = HomeHold()
        XCTAssertFalse(hold.update(pressed: true, at: 10))
        XCTAssertFalse(hold.update(pressed: false, at: 10.5))
        XCTAssertFalse(hold.update(pressed: true, at: 11))
        hold = .init()
        XCTAssertFalse(hold.update(pressed: true, at: 12))
        XCTAssertFalse(hold.update(pressed: true, at: 12.9))
    }
    func testTapIsEmittedOnlyOnReleaseAndHoldNeverEmitsTap() {
        var hold = HomeHold()
        XCTAssertNil(hold.event(pressed: true, at: 0))
        XCTAssertNil(hold.event(pressed: true, at: 0.5))
        XCTAssertEqual(hold.event(pressed: false, at: 0.9), .tap)
        XCTAssertNil(hold.event(pressed: false, at: 1))
        XCTAssertNil(hold.event(pressed: true, at: 2))
        XCTAssertEqual(hold.event(pressed: true, at: 3), .hold)
        XCTAssertNil(hold.event(pressed: true, at: 4))
        XCTAssertNil(hold.event(pressed: false, at: 5))
    }

    func testDelayedReleaseAndControllerReplacementDoNotEmitSpuriousTaps() {
        var hold = HomeHold()
        XCTAssertNil(hold.event(pressed: true, at: 10))
        XCTAssertEqual(hold.event(pressed: false, at: 11.2), .hold)
        XCTAssertNil(hold.event(pressed: true, at: 12))
        hold = .init()
        XCTAssertNil(hold.event(pressed: false, at: 12.5))
    }

}
