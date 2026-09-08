import XCTest
import Domain
import Catalog
@testable import Playden

final class LibraryFilterTests: XCTestCase {
    @MainActor func testRecentlyAddedSortUsesAccountAcquisitionInsteadOfLocalDiscovery() throws {
        let catalog = try CatalogStore(), discovery = Date(timeIntervalSince1970: 1_700_000_000)
        let old = SourceGameRecord(id: .init(source: "steam", value: "1"), title: "Old purchase",
            firstObservedAt: discovery.addingTimeInterval(100), sourceAcquiredAt: Date(timeIntervalSince1970: 1_400_000_000))
        let recent = SourceGameRecord(id: .init(source: "steam", value: "2"), title: "Recent purchase",
            firstObservedAt: discovery, sourceAcquiredAt: Date(timeIntervalSince1970: 1_600_000_000))
        let unknown = SourceGameRecord(id: .init(source: "steam", value: "3"), title: "A date unknown",
            firstObservedAt: discovery.addingTimeInterval(200))
        try catalog.replaceSourceCatalog(source: "steam", games: [old, unknown, recent])
        let model = LibraryModel(catalog: catalog, preview: false)
        defer { model.stopServices() }
        model.selectTab(.library); model.sort = .recentlyAdded
        XCTAssertEqual(model.filteredGames.map(\.id), [recent.id, old.id, unknown.id])
        XCTAssertNil(model.games.first { $0.id == unknown.id }?.addedAt)
        var backfilled = unknown
        backfilled.sourceAcquiredAt = Date(timeIntervalSince1970: 1_650_000_000)
        try catalog.replaceSourceCatalog(source: "steam", games: [old, backfilled, recent])
        model.reloadCatalog()
        XCTAssertEqual(model.sort, .recentlyAdded)
        XCTAssertEqual(model.filteredGames.map(\.id), [unknown.id, recent.id, old.id])
    }

    @MainActor private func model() -> LibraryModel {
        let model = LibraryModel()
        model.games = [
            Game(id: .init(source: "steam", value: "1"), title: "Alpha", status: .installed, compatibility: .works,
                 hoursPlayed: 10, genres: ["Action"], lastPlayedAt: Date(timeIntervalSince1970: 20), addedAt: Date(timeIntervalSince1970: 10), controllerSupport: .full),
            Game(id: .init(source: "fixture", value: "2"), title: "Beta", status: .driveDisconnected, compatibility: .playable,
                 hoursPlayed: 30, genres: ["Puzzle"], lastPlayedAt: Date(timeIntervalSince1970: 10), addedAt: Date(timeIntervalSince1970: 30), controllerSupport: .partial),
            Game(id: .init(source: "steam", value: "3"), title: "Gamma", compatibility: .untested, genres: ["Action"]),
            Game(id: .init(source: "steam", value: "4"), title: "Secret", genres: ["Action"], isHidden: true)
        ]
        model.selectTab(.library)
        return model
    }
    @MainActor func testEverySortUsesItsOwnMetadataAndPlacesUnknownLast() {
        let model = model()
        model.sort = .name; XCTAssertEqual(model.filteredGames.map(\.title), ["Alpha", "Beta", "Gamma"])
        model.sort = .playtime; XCTAssertEqual(model.filteredGames.map(\.title), ["Beta", "Alpha", "Gamma"])
        model.sort = .recentlyPlayed; XCTAssertEqual(model.filteredGames.map(\.title), ["Alpha", "Beta", "Gamma"])
        model.sort = .recentlyAdded; XCTAssertEqual(model.filteredGames.map(\.title), ["Beta", "Alpha", "Gamma"])
    }
    @MainActor func testFiltersComposeWithScopeSearchAndUnknownMetadata() {
        let model = model()
        model.refinements.installation = .installed
        XCTAssertEqual(model.filteredGames.map(\.title), ["Alpha", "Beta"])
        model.refinements.source = "fixture"
        model.refinements.compatibility = .playable
        model.refinements.controller = .partial
        XCTAssertEqual(model.filteredGames.map(\.title), ["Beta"])
        model.updateQuery("Alpha"); XCTAssertTrue(model.filteredGames.isEmpty)
        model.browseAvailableGames()
        model.refinements.genre = "action"; model.refinements.controller = .unknown
        XCTAssertEqual(model.filteredGames.map(\.title), ["Gamma"])
        model.filter = .hidden
        XCTAssertEqual(model.filteredGames.map(\.title), ["Secret"])
    }
    @MainActor func testEmptyFilterRecoveryAndResetPreserveCollectionScope() {
        let model = model()
        model.filter = .favorites; model.refinements.genre = "Missing"; model.sort = .playtime
        model.activateFilter(.reset)
        XCTAssertEqual(model.filter, .favorites)
        XCTAssertEqual(model.sort, .name)
        XCTAssertFalse(model.refinements.isActive)
        model.refinements.genre = "Missing"
        model.perform(.confirm)
        XCTAssertEqual(model.filter, .all)
        XCTAssertFalse(model.filteredGames.isEmpty)
        XCTAssertFalse(model.refinements.isActive)
    }
    @MainActor func testWrappedChipNavigationStaysVisibleAndModalTrapsTabs() {
        Design.registerFonts()
        let model = model(); model.show(.filters)
        XCTAssertTrue(model.filterLayout.chips.contains { $0.choice == .source("fixture") })
        model.perform(.nextTab); XCTAssertEqual(model.tab, .library)
        for _ in 0..<30 { model.perform(.move(.down)) }
        XCTAssertEqual(model.filterChoiceIndex, model.filterLayout.chips.count)
        XCTAssertGreaterThan(model.filterScrollOffset, 0)
        model.perform(.move(.up))
        let chip = model.filterLayout.chips[model.filterChoiceIndex]
        XCTAssertGreaterThanOrEqual(chip.frame.minY - model.filterScrollOffset, 0)
        XCTAssertLessThanOrEqual(chip.frame.maxY - model.filterScrollOffset, 760)
        for _ in 0..<30 { model.perform(.move(.up)) }
        XCTAssertEqual(model.filterScrollOffset, 0)
        model.perform(.back); XCTAssertNil(model.panel)
        XCTAssertEqual(model.tab, .library)
    }
    @MainActor func testNewPreferencesSurviveRecreationWithoutChangingSetup() throws {
        let catalog = try CatalogStore()
        var preferences = LibraryPreferences(); preferences.setupCompleted = true; preferences.selectedDisplayID = 99
        try catalog.savePreferences(preferences)
        let first = LibraryModel(catalog: catalog)
        first.sort = .recentlyAdded; first.refinements.genre = "Action"; first.refinements.compatibility = .works
        let second = LibraryModel(catalog: catalog)
        XCTAssertEqual(second.sort, .recentlyAdded)
        XCTAssertEqual(second.refinements, first.refinements)
        XCTAssertTrue(try catalog.preferences().setupCompleted)
        XCTAssertEqual(try catalog.preferences().selectedDisplayID, 99)
    }
}
