import XCTest
import Input
@testable import Playden

final class ControllerInteractionTests: XCTestCase {
    @MainActor func testSettingsTabNavigatesToPowerAndBack() {
        let model = LibraryModel()
        defer { model.stopServices() }
        model.selectTab(.settings, focusTabs: true)
        model.performController(.move(.right))
        XCTAssertTrue(model.tabsFocused)
        XCTAssertTrue(model.powerFocused)
        XCTAssertEqual(model.tab, .settings)
        model.performController(.move(.right))
        XCTAssertTrue(model.powerFocused)
        model.performController(.move(.left))
        XCTAssertFalse(model.powerFocused)
        XCTAssertTrue(model.tabsFocused)
        XCTAssertEqual(model.tab, .settings)
        model.performController(.move(.left))
        XCTAssertEqual(model.tab, .downloads)
    }

    @MainActor func testPowerConfirmUsesLauncherQuitAction() {
        let model = LibraryModel()
        defer { model.stopServices() }
        var quitRequests = 0
        model.onLauncherQuit = { quitRequests += 1 }
        model.selectTab(.settings, focusTabs: true)
        model.performController(.move(.right))
        XCTAssertEqual(quitRequests, 0)
        model.performController(.confirm)
        XCTAssertEqual(quitRequests, 1)
    }

    @MainActor func testLeavingHeaderClearsPowerFocus() {
        let model = LibraryModel()
        defer { model.stopServices() }
        for action: InputAction in [.move(.down), .back, .nextTab, .previousTab, .home] {
            model.selectTab(.settings, focusTabs: true)
            model.performController(.move(.right))
            XCTAssertTrue(model.powerFocused)
            model.performController(action)
            XCTAssertFalse(model.powerFocused)
        }
    }

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
