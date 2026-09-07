import XCTest
import Catalog
import Domain
import Input
@testable import BigScreen

final class LibraryPersistenceTests: XCTestCase {
    @MainActor func testPreviewEditsCollectionsAndPreferencesSurviveRecreation() throws {
        let catalog = try CatalogStore()
        let first = LibraryModel(catalog: catalog)
        let gameID = try XCTUnwrap(first.focusedGame?.id)
        first.toggleFavorite()
        let expectedFavorite = first.focusedGame!.isFavorite
        first.beginText(.compatibilityNote(gameID)); first.insertText("1080p works well 🎮"); first.finishText()
        first.beginText(.newCollection(gameID)); first.insertText("Weekends"); first.finishText()
        let collection = try XCTUnwrap(first.collections.last)
        first.show(.collectionOptions(collection.id)); first.panelIndex = 1; first.perform(.confirm)
        first.filter = .collection(collection.id)
        first.reducedMotion = true; first.downloadWhilePlaying = true
        let second = LibraryModel(catalog: catalog)
        XCTAssertNil(second.persistenceError)
        XCTAssertEqual(second.games.first { $0.id == gameID }?.isFavorite, expectedFavorite)
        XCTAssertEqual(second.compatibilityNotes[gameID], "1080p works well 🎮")
        XCTAssertEqual(second.collections.last?.name, "Weekends")
        XCTAssertTrue(second.collections.last!.isPinned)
        XCTAssertEqual(second.filter, .collection(collection.id))
        XCTAssertTrue(second.reducedMotion); XCTAssertTrue(second.downloadWhilePlaying)
        XCTAssertTrue(try catalog.snapshot().entries.allSatisfy { $0.installation == nil })
    }
    @MainActor func testDeletingAllPreviewCollectionsDoesNotReseedThem() throws {
        let catalog = try CatalogStore()
        let first = LibraryModel(catalog: catalog)
        for collection in first.collections { first.confirm(.deleteCollection(collection.id)) }
        XCTAssertTrue(first.collections.isEmpty)
        XCTAssertTrue(LibraryModel(catalog: catalog).collections.isEmpty)
    }
    @MainActor func testProductionModelNeverInjectsPreviewData() throws {
        let catalog = try CatalogStore()
        let empty = LibraryModel(catalog: catalog, preview: false)
        XCTAssertTrue(empty.games.isEmpty)
        XCTAssertTrue(empty.collections.isEmpty)
        XCTAssertTrue(empty.downloadGames.isEmpty)
        XCTAssertNil(try catalog.lastSync(for: "steam"))
        let id = GameID(source: "fixture", value: "distinct-id")
        try catalog.replaceSourceCatalog(source: "fixture", games: [SourceGameRecord(id: id, title: "A real catalog entry")])
        let populated = LibraryModel(catalog: catalog, preview: false)
        XCTAssertEqual(populated.games.map(\.id), [id])
        populated.selectTab(.library); populated.toggleFavorite()
        XCTAssertTrue(LibraryModel(catalog: catalog, preview: false).games[0].isFavorite)
    }
    @MainActor func testInvalidPersistenceCanBeRetriedWithoutDroppingExistingData() throws {
        let catalog = try CatalogStore()
        let model = LibraryModel(catalog: catalog)
        let original = model.collections
        model.collections.append(GameCollection(name: original[0].name))
        XCTAssertNotNil(model.persistenceError)
        XCTAssertEqual(model.panel, .persistenceFailure)
        XCTAssertEqual(try catalog.snapshot().collections, original)
        model.collections.removeLast(); model.retryPersistence()
        XCTAssertNil(model.persistenceError)
        XCTAssertNil(model.panel)
        XCTAssertEqual(try catalog.snapshot().collections, original)
    }
}
