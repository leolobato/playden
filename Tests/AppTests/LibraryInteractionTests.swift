import XCTest
import Domain
import Focus
import Catalog
@testable import BigScreen

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
    @MainActor func testTriggerPagingReturnsFirstTileBelowHeader() {
        let model = LibraryModel(); model.selectTab(.library)
        for _ in 0..<5 { model.perform(.nextPage) }
        XCTAssertGreaterThan(model.libraryScrollOffset, 0)
        for _ in 0..<5 { model.perform(.previousPage) }
        XCTAssertEqual(model.libraryCursor.index, 0)
        XCTAssertEqual(model.libraryScrollOffset, 0)
        model.perform(.nextPage)
        model.filter = .installed
        XCTAssertEqual(model.libraryScrollOffset, 0)
        XCTAssertEqual(model.libraryCursor.index, 0)
    }
    @MainActor func testDownloadsNavigateAndConfirmSelectedRow() {
        let model = LibraryModel(); model.selectTab(.downloads)
        model.perform(.move(.down))
        XCTAssertEqual(model.focusedGame?.title, "Celeste")
        model.perform(.confirm)
        XCTAssertEqual(model.focusedGame?.title, "Celeste")
        XCTAssertNotNil(model.detailID)
        model.perform(.back); model.perform(.move(.up))
        XCTAssertEqual(model.focusedGame?.title, "TUNIC")
        model.perform(.confirm)
        XCTAssertTrue(model.downloadPaused)
    }

    @MainActor func testHomeUpFocusesTabsAndArrowsSwitchWithoutOpeningAGame() {
        let model = LibraryModel()
        model.perform(.move(.right)); let gameID = model.focusedGame?.id
        model.perform(.move(.up))
        XCTAssertTrue(model.tabsFocused); XCTAssertNil(model.focusedGame)
        model.perform(.favorite); model.perform(.context)
        XCTAssertNil(model.panel)
        model.perform(.move(.right))
        XCTAssertEqual(model.tab, .library); XCTAssertTrue(model.tabsFocused)
        model.perform(.move(.left)); model.perform(.move(.down))
        XCTAssertEqual(model.tab, .home); XCTAssertFalse(model.tabsFocused)
        XCTAssertEqual(model.focusedGame?.id, gameID)
        model.perform(.move(.up)); model.perform(.confirm)
        XCTAssertFalse(model.tabsFocused); XCTAssertNil(model.detailID)
        model.perform(.confirm); XCTAssertEqual(model.detailID, gameID)
    }
    @MainActor func testContinuePlayingEndsAt15GamesAndLibraryCardOpensUnfilteredLibrary() throws {
        let catalog = try CatalogStore()
        let games = (0..<40).map { index in
            SourceGameRecord(id: GameID(source: "fixture", value: String(index)), title: "Game \(index)",
                sourceLastPlayedAt: Date(timeIntervalSince1970: Double(index + 1)))
        }
        try catalog.replaceSourceCatalog(source: "fixture", games: games)
        let model = LibraryModel(catalog: catalog, preview: false)
        XCTAssertEqual(model.rows.first?.games.count, 15)
        XCTAssertEqual(model.rows.first?.games.first?.id, games[39].id)
        XCTAssertEqual(model.rows.first?.games.last?.id, games[25].id)
        XCTAssertEqual(model.rows.first?.itemCount, 16)
        for _ in 0..<100 { model.perform(.move(.right)) }
        XCTAssertEqual(model.homeColumns[0], 15); XCTAssertNil(model.focusedGame)
        XCTAssertGreaterThan(model.homeRowOffsets[0, default: 0], 0)
        let offset = model.homeRowOffsets[0]
        XCTAssertLessThanOrEqual(24 + 15 * 233 + 213 - (offset ?? 0), 1728, "The final card stays inside the TV safe area")
        model.reconcileFocus()
        XCTAssertEqual(model.homeColumns[0], 15); XCTAssertEqual(model.homeRowOffsets[0], offset)
        model.filter = .favorites; model.updateQuery("missing")
        model.perform(.confirm)
        XCTAssertEqual(model.tab, .library); XCTAssertEqual(model.filter, .all)
        XCTAssertTrue(model.query.isEmpty); XCTAssertEqual(model.filteredGames.count, 40)
        XCTAssertNil(model.detailID)
        model.selectTab(.home)
        XCTAssertEqual(model.homeColumns[0], 15)
        model.perform(.move(.left)); XCTAssertEqual(model.focusedGame?.id, games[25].id)
        for _ in 0..<100 { model.perform(.move(.left)) }
        XCTAssertEqual(model.homeColumns[0], 0); XCTAssertEqual(model.homeRowOffsets[0], 0)
    }
    @MainActor func testPagingDoesNotMoveFocusIntoTabsAndEmptyHomeCanReachTabs() {
        let model = LibraryModel()
        for _ in 0..<3 { model.perform(.previousPage) }
        XCTAssertFalse(model.tabsFocused)
        model.games = []; model.collections = []
        model.perform(.move(.up)); XCTAssertTrue(model.tabsFocused)
        model.perform(.move(.right)); model.perform(.move(.right))
        XCTAssertEqual(model.tab, .downloads)
        model.perform(.back); XCTAssertFalse(model.tabsFocused)
    }

}
