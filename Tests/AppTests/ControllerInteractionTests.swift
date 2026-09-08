import XCTest
import Input
@testable import Playden

final class ControllerInteractionTests: XCTestCase {
    @MainActor func testButtonTestTrapsControllerActionsAndRestoresSettings() {
        let model = LibraryModel()
        model.selectTab(.settings); model.settingsSection = 4; model.activateSetting()
        XCTAssertEqual(model.panel, .controllerTest)
        for action: InputAction in [.confirm, .back, .nextTab, .previousTab, .home, .search, .options, .move(.down)] {
            model.performController(action)
            XCTAssertEqual(model.panel, .controllerTest)
            XCTAssertEqual(model.tab, .settings)
        }
        model.perform(.back) // Physical Escape can always close without a controller.
        XCTAssertNil(model.panel)
        XCTAssertEqual(model.settingsSection, 4)
        XCTAssertEqual(model.settingsIndex, 0)
    }
    @MainActor func testHoldBackClosesButDisconnectDoesNotDismissTest() {
        let model = LibraryModel(); model.selectTab(.settings); model.settingsSection = 4
        model.openControllerTest()
        let pressed = ControllerSnapshot(id: "pad", name: "Fixture", playStation: true, buttons: [.east: 1])
        model.receiveControllers([pressed], at: 1)
        model.receiveControllers([], at: 3)
        XCTAssertEqual(model.panel, .controllerTest)
        model.receiveControllers([pressed], at: 4)
        model.receiveControllers([pressed], at: 5.21)
        XCTAssertNil(model.panel)
        XCTAssertEqual(model.tab, .settings)
    }
}
