import XCTest
import Domain
import Focus
@testable import GameNative_Big_Screen

final class LibraryInteractionTests: XCTestCase {
    @MainActor func testModalTrapsNavigationAndRestoresGridFocus() {
        let model = LibraryModel()
        model.selectTab(.library)
        model.perform(.move(.right)); model.perform(.move(.down))
        let game = model.focusedGame?.id
        model.perform(.options)
        model.perform(.nextTab)
        XCTAssertEqual(model.tab, .library)
        model.perform(.move(.down))
        XCTAssertEqual(model.focusedGame?.id, game)
        model.perform(.back)
        XCTAssertNil(model.panel)
        XCTAssertEqual(model.focusedGame?.id, game)
    }
    @MainActor func testGamePageBackRestoresOrigin() {
        let model = LibraryModel()
        model.selectTab(.library)
        model.perform(.move(.right)); model.perform(.move(.right))
        let game = model.focusedGame?.id
        model.perform(.confirm)
        XCTAssertEqual(model.detailID, game)
        model.perform(.move(.right))
        model.perform(.back)
        XCTAssertNil(model.detailID)
        XCTAssertEqual(model.tab, .library)
        XCTAssertEqual(model.focusedGame?.id, game)
    }
    @MainActor func testEmptySearchHasControllerRecovery() {
        let model = LibraryModel()
        model.perform(.search)
        model.updateQuery("not-a-real-game")
        XCTAssertTrue(model.filteredGames.isEmpty)
        model.perform(.back)
        XCTAssertNil(model.panel)
        model.perform(.confirm)
        XCTAssertFalse(model.filteredGames.isEmpty)
        XCTAssertTrue(model.query.isEmpty)
    }
    @MainActor func testHidingLastFavoriteClampsFocus() {
        let model = LibraryModel()
        model.selectTab(.library); model.filter = .favorites
        model.libraryCursor = GridCursor(index: model.filteredGames.count - 1)
        let hiddenID = model.focusedGame?.id
        model.show(.context); model.panelIndex = 3; model.activatePanel()
        XCTAssertFalse(model.filteredGames.contains { $0.id == hiddenID })
        XCTAssertNotNil(model.focusedGame)
        model.filter = .hidden
        XCTAssertTrue(model.filteredGames.contains { $0.id == hiddenID })
    }
    @MainActor func testAllHiddenHomeStillHasARecoverableAction() {
        let model = LibraryModel()
        for index in model.games.indices { model.games[index].isHidden = true }
        XCTAssertTrue(model.rows.isEmpty)
        model.perform(.confirm)
        XCTAssertEqual(model.tab, .library)
        XCTAssertEqual(model.filter, .hidden)
        XCTAssertEqual(model.filteredGames.count, model.games.count)
    }
    @MainActor func testSearchKeyboardCanTypeWithoutPhysicalKeyboard() {
        let model = LibraryModel()
        model.perform(.search)
        model.keyRow = 1; model.keyColumn = 0
        model.perform(.confirm)
        XCTAssertEqual(model.query, "q")
        model.perform(.context)
        XCTAssertEqual(model.query, "q ")
        model.perform(.favorite)
        XCTAssertEqual(model.query, "q")
        model.keyRow = 4; model.keyColumn = 1
        model.perform(.confirm)
        XCTAssertNil(model.panel)
    }
    @MainActor func testRailShortcutsDontModifyUnfocusedGame() {
        let model = LibraryModel()
        model.selectTab(.library); model.railFocused = true
        let before = model.games
        model.perform(.favorite); model.perform(.context)
        XCTAssertEqual(before, model.games)
        XCTAssertNil(model.panel)
    }
    @MainActor func testNavigationMemorySurvivesTabSwitch() {
        let model = LibraryModel()
        model.perform(.move(.right)); model.perform(.move(.right))
        let game = model.focusedGame?.id
        model.perform(.nextTab); model.perform(.previousTab)
        XCTAssertEqual(model.focusedGame?.id, game)
    }
}
