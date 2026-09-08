import XCTest
import Domain
import Catalog
@testable import Playden

final class HomeNavigationTests: XCTestCase {
    @MainActor private func fixture() -> LibraryModel {
        let model = LibraryModel(preview: false)
        model.games = (0..<40).map { index in
            Game(id: .init(source: "fixture", value: String(index)), title: "Game \(index)",
                 isFavorite: true, lastPlayedAt: Date(timeIntervalSince1970: Double(index + 1)))
        }
        model.collections = [
            .init(name: "Favorites", gameIDs: Set(model.games.map(\.id)), isPinned: true),
            .init(name: "Continue playing", gameIDs: Set(model.games.map(\.id)), isPinned: true)
        ]
        return model
    }

    @MainActor func testCollectionNamesDoNotInheritBuiltinLimitOrLibraryCard() {
        let model = fixture()
        defer { model.stopServices() }
        XCTAssertEqual(model.rows.map(\.id), [.continuePlaying, .favorites,
            .collection(model.collections[0].id), .collection(model.collections[1].id)])
        XCTAssertEqual(model.rows[0].itemCount, 16)
        XCTAssertTrue(model.rows[0].showsLibraryCard)
        model.homeRow = 3
        for _ in 0..<50 { model.perform(.move(.right)) }
        XCTAssertEqual(model.rows[3].games.count, 40)
        XCTAssertFalse(model.rows[3].showsLibraryCard)
        XCTAssertEqual(model.homeColumns[3], 39)
        XCTAssertEqual(model.focusedGame?.id, model.games.last?.id)
        XCTAssertTrue(model.homeVisibleColumns(in: 3).contains(39))
    }

    @MainActor func testRowsKeepTheirSelectedGamesWhenDownloadsAppearAndCollectionsMove() throws {
        let model = fixture()
        defer { model.stopServices() }
        model.homeColumns = [0: 15, 1: 18, 2: 31, 3: 24]
        model.homeRow = 2
        let selected = try XCTUnwrap(model.focusedGame?.id)
        let collection = model.collections[0].id
        let expected = model.captureHomeFocus(in: model.rows)
        model.games[0].status = .queued
        XCTAssertEqual(model.homeRow, 3)
        XCTAssertEqual(model.rows[model.homeRow].id, .collection(collection))
        XCTAssertEqual(model.focusedGame?.id, selected)
        for (index, row) in model.rows.enumerated() where expected.rows[row.id] != nil {
            XCTAssertEqual(row.itemID(at: model.homeColumns[index, default: 0]), expected.rows[row.id]?.item)
        }
        model.games.reverse()
        XCTAssertEqual(model.focusedGame?.id, selected)
        model.collections.reverse()
        XCTAssertEqual(model.rows[model.homeRow].id, .collection(collection))
        XCTAssertEqual(model.focusedGame?.id, selected)
        let downloading = try XCTUnwrap(model.games.firstIndex { $0.status == .queued })
        model.games[downloading].status = .notInstalled
        XCTAssertEqual(model.rows[model.homeRow].id, .collection(collection))
        XCTAssertEqual(model.focusedGame?.id, selected)
        for (index, row) in model.rows.enumerated() {
            XCTAssertEqual(row.itemID(at: model.homeColumns[index, default: 0]), expected.rows[row.id]?.item)
            XCTAssertTrue(model.homeVisibleColumns(in: index).contains(model.homeColumns[index, default: 0]))
        }
        XCTAssertTrue(model.homeVisibleRowIndices.contains(model.homeRow))
        model.selectTab(.library); model.selectTab(.home)
        XCTAssertEqual(model.focusedGame?.id, selected)
    }

    @MainActor func testRemovedGameAndRowChooseVisibleNeighborsWithoutBorrowingAnotherRowsMemory() {
        let model = fixture()
        defer { model.stopServices() }
        model.homeRow = 3; model.homeColumns[3] = 39
        model.games[39].isHidden = true
        XCTAssertEqual(model.homeColumns[3], 38)
        XCTAssertEqual(model.focusedGame?.id, model.games[38].id)
        model.collections.removeLast()
        XCTAssertEqual(model.homeRow, 2)
        XCTAssertEqual(model.homeColumns[2], 0, "The remaining collection keeps its own child")
        XCTAssertEqual(model.focusedGame?.id, model.games[0].id)
        XCTAssertEqual(model.homeRowOffsets[2], 0)
        XCTAssertNil(model.homeColumns[3]); XCTAssertNil(model.homeRowOffsets[3])
        model.games = []
        XCTAssertTrue(model.rows.isEmpty); XCTAssertEqual(model.homeRow, 0)
        XCTAssertTrue(model.homeColumns.isEmpty)
        XCTAssertEqual(model.homeScrollOffset, 0)
        XCTAssertNil(model.focusedGame)
    }

    @MainActor func testLibraryCardStaysSelectedWhenContinuePlayingShrinksWhileTabsHaveFocus() {
        let model = fixture()
        defer { model.stopServices() }
        model.homeColumns[0] = 15
        model.perform(.move(.up))
        XCTAssertTrue(model.tabsFocused)
        model.games = Array(model.games.prefix(5))
        XCTAssertEqual(model.homeColumns[0], 5)
        XCTAssertTrue(model.tabsFocused)
        model.perform(.move(.down))
        XCTAssertNil(model.focusedGame)
        model.perform(.confirm)
        XCTAssertEqual(model.tab, .library)
        XCTAssertEqual(model.filteredGames.count, 5)
    }

    @MainActor func testCatalogRefreshPreservesNamedCollectionChildAndOtherRowsMemory() throws {
        let catalog = try CatalogStore()
        let records = (0..<40).map { index in
            SourceGameRecord(id: .init(source: "fixture", value: String(index)), title: "Game \(index)",
                sourceLastPlayedAt: Date(timeIntervalSince1970: Double(index + 1)))
        }
        try catalog.replaceSourceCatalog(source: "fixture", games: records)
        var collection = GameCollection(name: "Continue playing", gameIDs: Set(records.map(\.id)), isPinned: true)
        try catalog.saveCollections([collection])
        let model = LibraryModel(catalog: catalog, preview: false)
        defer { model.stopServices() }
        model.homeColumns[0] = 15
        model.homeRow = 1; model.homeColumns[1] = 31
        let selected = try XCTUnwrap(model.focusedGame?.id)
        let offset = model.homeRowOffsets[1]
        collection.name = "Renamed"
        try catalog.saveCollections([collection])
        model.reloadCatalog()
        XCTAssertEqual(model.rows[model.homeRow].id, .collection(collection.id))
        XCTAssertEqual(model.rows[model.homeRow].name, "Renamed")
        XCTAssertEqual(model.focusedGame?.id, selected)
        XCTAssertEqual(model.homeRowOffsets[1], offset)
        XCTAssertEqual(model.homeColumns[0], 15)
        model.homeRow = 0; model.tabsFocused = true
        try catalog.replaceSourceCatalog(source: "fixture", games: Array(records.prefix(5)))
        model.reloadCatalog()
        XCTAssertTrue(model.tabsFocused)
        XCTAssertEqual(model.homeRow, 0); XCTAssertEqual(model.homeColumns[0], 5)
        XCTAssertEqual(model.homeRowOffsets[0], 0)
    }

    @MainActor func testBatchedReplacementRetainsCollectionEvenWhenAllItsOldGamesDisappear() throws {
        let model = fixture()
        defer { model.stopServices() }
        model.homeRow = 3; model.homeColumns[3] = 30
        let selectedRow = model.rows[3].id
        model.preservingHomeFocus {
            model.games = [Game(id: .init(source: "fixture", value: "new"), title: "New game", isFavorite: true)]
            // Neither collection has any members during this intermediate update.
            XCTAssertFalse(model.rows.contains { $0.id == selectedRow })
            for index in model.collections.indices { model.collections[index].gameIDs = Set(model.games.map(\.id)) }
        }
        XCTAssertEqual(model.rows[model.homeRow].id, selectedRow)
        XCTAssertEqual(model.focusedGame?.id, model.games[0].id)
        XCTAssertEqual(model.homeColumns[model.homeRow], 0)
        XCTAssertTrue(model.homeVisibleRowIndices.contains(model.homeRow))
    }
}
