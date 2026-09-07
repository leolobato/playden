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
}
