import XCTest
import Domain
import Catalog
@testable import Playden

@MainActor final class GameSettingsTests: XCTestCase {
    func testControllerOverridePersistsAndOtherEditsPreserveIt() throws {
        let catalog = try CatalogStore(), id = GameID(source: "fixture", value: "controller")
        try catalog.replaceSourceCatalog(source: "fixture", games: [.init(id: id, title: "Controller fixture")])
        let model = LibraryModel(catalog: catalog, preview: false)
        model.openGame(try XCTUnwrap(model.games.first))
        XCTAssertEqual(model.detailActions, ["Install", "Game settings", "Favorite", "More"])
        model.detailAction = 1; model.perform(.confirm)
        XCTAssertEqual(model.panel, .gameSettings(id))
        model.perform(.move(.down)); model.perform(.move(.down)); model.perform(.confirm)
        XCTAssertEqual(model.controllerModeChoice, .native)
        XCTAssertNil(try catalog.snapshot().entries.first?.edits.controllerMode)
        model.panelIndex = 4; model.perform(.confirm)
        model.toggleFavorite()
        let restored = LibraryModel(catalog: catalog, preview: false)
        XCTAssertEqual(restored.controllerModes[id], .native)
        XCTAssertTrue(try XCTUnwrap(catalog.snapshot().entries.first).edits.isFavorite)
        restored.showGameSettings(id)
        restored.panelIndex = 0; restored.perform(.confirm)
        restored.perform(.back)
        XCTAssertEqual(restored.controllerModes[id], .native)
        restored.showGameSettings(id)
        restored.panelIndex = 0; restored.perform(.confirm)
        restored.panelIndex = 4; restored.perform(.confirm)
        XCTAssertNil(try catalog.snapshot().entries.first?.edits.controllerMode)
        XCTAssertEqual(ControllerMode.playdenDefault, .xboxCompatible)
    }
    func testMoreKeepsManagementActionsReachable() throws {
        let model = LibraryModel()
        model.openGame(try XCTUnwrap(model.games.first { $0.status == .installed }))
        XCTAssertEqual(model.detailActions.count, 4)
        model.detailAction = 3; model.perform(.confirm)
        XCTAssertEqual(model.panel, .context)
        for action in ["Game settings", "Add to collection", "Set compatibility", "Hide", "Verify files", "Cloud saves", "Uninstall", "View logs"] {
            XCTAssertTrue(model.panelActions.contains(action), action)
        }
        model.panelIndex = try XCTUnwrap(model.panelActions.firstIndex(of: "Game settings"))
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .gameSettings(try XCTUnwrap(model.detailID)))
    }
    func testOldGameEditsDecodeWithoutControllerOverride() throws {
        let data = try JSONEncoder().encode(GameEdits())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "controllerMode")
        let decoded = try JSONDecoder().decode(GameEdits.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.controllerMode)
    }
}
