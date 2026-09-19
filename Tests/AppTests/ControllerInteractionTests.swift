import XCTest
@testable import Input
import Catalog
import Domain
@testable import Playden

final class ControllerInteractionTests: XCTestCase {
    @MainActor func testTabShortcutFromContentCanReachPowerWithKeyboardOrController() {
        for controller in [false, true] {
            let model = LibraryModel()
            defer { model.stopServices() }
            model.selectTab(.downloads)
            XCTAssertFalse(model.tabsFocused)
            func send(_ action: InputAction) {
                if controller { model.performController(action) } else { model.perform(action) }
            }
            send(.nextTab)
            XCTAssertEqual(model.tab, .settings)
            send(.move(.right))
            XCTAssertTrue(model.tabsFocused)
            XCTAssertTrue(model.powerFocused)
            var quits = 0
            model.onLauncherQuit = { quits += 1 }
            send(.confirm)
            XCTAssertEqual(quits, 1)
        }
    }

    @MainActor func testNintendoLayoutSettingIsReachableAndPersists() throws {
        let catalog = try CatalogStore()
        let model = LibraryModel(catalog: catalog, preview: false)
        XCTAssertFalse(model.useNintendoButtonLayout)
        model.selectTab(.settings); model.settingsSection = 4; model.settingsRailFocused = false
        model.performController(.move(.down))
        XCTAssertEqual(model.settingsIndex, 1)
        model.performController(.confirm)
        XCTAssertTrue(model.useNintendoButtonLayout)
        XCTAssertEqual(try catalog.preferences().useNintendoButtonLayout, true)
        let restored = LibraryModel(catalog: catalog, preview: false)
        XCTAssertTrue(restored.useNintendoButtonLayout)
        // B now confirms; changing layout must not require the old confirm button.
        model.performController(.back)
        XCTAssertFalse(model.useNintendoButtonLayout)
        XCTAssertEqual(try catalog.preferences().useNintendoButtonLayout, false)
    }

    @MainActor func testNintendoLayoutSwapsControllerActionsAndGlyphsButNotKeyboard() {
        let model = LibraryModel()
        model.useNintendoButtonLayout = true
        model.playStationGlyphs = false
        XCTAssertEqual(model.controllerConfirmGlyph, "B")
        XCTAssertEqual(model.controllerBackGlyph, "A")
        XCTAssertEqual(model.controllerFavoriteGlyph, "Y")
        XCTAssertEqual(model.controllerContextGlyph, "X")
        model.show(.information("Test"))
        model.performController(.confirm) // Physical A is Back.
        XCTAssertNil(model.panel)
        var quitRequests = 0
        model.onLauncherQuit = { quitRequests += 1 }
        model.selectTab(.settings, focusTabs: true)
        model.performController(.move(.right))
        model.performController(.back) // Physical B is Confirm.
        XCTAssertEqual(quitRequests, 1)
        model.perform(.confirm) // Keyboard Enter retains its meaning.
        XCTAssertEqual(quitRequests, 2)
        model.playStationGlyphs = true
        XCTAssertEqual(model.controllerConfirmGlyph, "○")
        XCTAssertEqual(model.controllerBackGlyph, "✕")
        if case .context = model.mappedControllerAction(.favorite) {} else { XCTFail("X should open context") }
        if case .favorite = model.mappedControllerAction(.context) {} else { XCTFail("Y should favorite") }
    }

    @MainActor func testNintendoLayoutButtonTestUsesSouthToCloseAndKeepsRawSamples() {
        let model = LibraryModel()
        model.useNintendoButtonLayout = true
        model.openControllerTest()
        let east = ControllerSnapshot(id: "pad", name: "Fixture", playStation: false, buttons: [.east: 1])
        model.receiveControllers([east], at: 1)
        model.receiveControllers([east], at: 3)
        XCTAssertEqual(model.panel, .controllerTest)
        let south = ControllerSnapshot(id: "pad", name: "Fixture", playStation: false, buttons: [.south: 1])
        model.receiveControllers([south], at: 4)
        XCTAssertEqual(model.controllerTest.lastInput, "A")
        model.receiveControllers([south], at: 5.21)
        XCTAssertNil(model.panel)
    }

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

    @MainActor func testBufferedDpadTapReachesQuitAfterNavigatingAcrossHeader() {
        for nintendo in [false, true] {
            let model = LibraryModel()
            model.useNintendoButtonLayout = nintendo
            model.selectTab(.home, focusTabs: true)
            var input = ControllerMenuInput()
            var time = 0.0
            func tapRight() {
                for action in input.consume(.init(direction: .right), at: time) { model.performController(action) }
                for action in input.consume(.init(), at: time + 0.004) { model.performController(action) }
                time += 0.012
            }
            tapRight(); XCTAssertEqual(model.tab, .library)
            tapRight(); XCTAssertEqual(model.tab, .downloads)
            tapRight(); XCTAssertEqual(model.tab, .settings)
            XCTAssertFalse(model.powerFocused)
            tapRight()
            XCTAssertTrue(model.tabsFocused)
            XCTAssertTrue(model.powerFocused)
            var quits = 0
            model.onLauncherQuit = { quits += 1 }
            for action in input.consume(.init(buttons: [nintendo ? .east : .south]), at: time) {
                model.performController(action)
            }
            XCTAssertEqual(quits, 1)
        }
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
