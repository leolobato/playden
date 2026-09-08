import XCTest
import QuartzCore
import Domain
import Observation
@testable import BigScreen

final class LibraryNavigationPerformanceTests: XCTestCase {
    @MainActor func testWarmDerivedListsStillNotifyViewsAndUpdateAfterEdits() {
        let model = LibraryModel(preview: false)
        let a = GameID(source: "fixture", value: "a"), b = GameID(source: "fixture", value: "b")
        model.games = [Game(id: a, title: "Beta", status: .installed, hoursPlayed: 1, genres: ["Action"], isFavorite: true),
                       Game(id: b, title: "Alpha", hoursPlayed: 5, genres: ["Puzzle"])]
        model.collections = []
        XCTAssertEqual(model.filteredGames.map(\.id), [b, a])
        _ = model.filteredGames; _ = model.rows
        let libraryChanged = expectation(description: "Warm library read remains observable")
        let homeChanged = expectation(description: "Warm home read remains observable")
        withObservationTracking { _ = model.filteredGames } onChange: { libraryChanged.fulfill() }
        withObservationTracking { _ = model.rows } onChange: { homeChanged.fulfill() }
        model.games[0].title = "Aardvark"
        wait(for: [libraryChanged, homeChanged], timeout: 0.2)
        XCTAssertEqual(model.filteredGames.map(\.id), [a, b])
        XCTAssertEqual(model.rows.first?.games.first?.title, "Aardvark")
        model.filter = .installed
        XCTAssertEqual(model.filteredGames.map(\.id), [a])
        model.games[1].status = .installed
        XCTAssertEqual(model.filteredGames.count, 2)
        model.refinements.genre = "Puzzle"
        XCTAssertEqual(model.filteredGames.map(\.id), [b])
        model.refinements = .init(); model.sort = .playtime
        XCTAssertEqual(model.filteredGames.map(\.id), [b, a])
        model.games[0].hoursPlayed = 10
        XCTAssertEqual(model.filteredGames.map(\.id), [a, b])
        model.query = "Alpha"
        XCTAssertEqual(model.filteredGames.map(\.id), [b])
        model.query = ""
        model.collections = [.init(name: "Weekend", gameIDs: [a], isPinned: true)]
        model.filter = .collection(model.collections[0].id)
        XCTAssertEqual(model.filteredGames.map(\.id), [a])
        XCTAssertEqual(model.rows.last?.games.map(\.id), [a])
        model.collections[0].gameIDs = [b]
        model.collections[0].name = "New name"
        XCTAssertEqual(model.filteredGames.map(\.id), [b])
        XCTAssertEqual(model.rows.last?.name, "New name")
        XCTAssertEqual(model.rows.last?.games.map(\.id), [b])
        model.games[1].isHidden = true
        XCTAssertTrue(model.filteredGames.isEmpty)
        XCTAssertFalse(model.rows.contains { $0.games.contains { $0.id == b } })
        model.filter = .hidden
        XCTAssertEqual(model.filteredGames.map(\.id), [b])
        model.stopServices()
    }

    @MainActor func testHomeKeepsOnlyNearbyTilesWhileEveryCollectionItemRemainsReachable() throws {
        let model = LibraryModel(preview: false)
        model.games = (0..<720).map { index in
            Game(id: .init(source: "fixture", value: String(index)), title: "Game \(index)",
                 isFavorite: true, lastPlayedAt: Date(timeIntervalSince1970: Double(index)))
        }
        model.collections = (0..<12).map { .init(name: "Collection \($0)", gameIDs: Set(model.games.map(\.id)), isPinned: true) }
        XCTAssertEqual(model.rows.count, 14)
        XCTAssertEqual(model.rows.first?.itemCount, 16)
        for _ in 0..<20 { model.perform(.move(.right)) }
        XCTAssertEqual(model.homeColumns[0], 15)
        XCTAssertTrue(model.homeVisibleColumns(in: 0).contains(15), "The final Library card must be constructed")
        model.perform(.move(.down))
        XCTAssertEqual(model.homeRow, 1)
        for _ in 0..<720 {
            model.perform(.move(.right))
            XCTAssertTrue(model.homeVisibleColumns(in: 1).contains(model.homeColumns[1, default: 0]))
            XCTAssertLessThanOrEqual(model.homeVisibleColumns(in: 1).count, 13)
        }
        XCTAssertEqual(model.focusedGame?.id, model.games.last?.id)
        for _ in 0..<720 { model.perform(.move(.left)) }
        XCTAssertEqual(model.focusedGame?.id, model.games.first?.id)
        XCTAssertEqual(model.homeRowOffsets[1], 0)
        for _ in 0..<12 {
            model.perform(.move(.down))
            let rows = model.homeVisibleRowIndices
            XCTAssertTrue(rows.contains(model.homeRow))
            XCTAssertLessThanOrEqual(rows.count, 5)
            XCTAssertLessThanOrEqual(rows.reduce(0) { $0 + model.homeVisibleColumns(in: $1).count }, 65)
        }
        XCTAssertEqual(model.homeRow, 13)
        model.homeColumns[13] = 719
        XCTAssertTrue(model.homeVisibleColumns(in: 13).contains(719))
        model.games = []; model.collections = []
        model.reconcileFocus()
        XCTAssertTrue(model.homeVisibleRowIndices.isEmpty)
        XCTAssertTrue(model.homeVisibleColumns(in: 0).isEmpty)
        model.stopServices()
    }

    @MainActor func testLargeLibraryNavigationPreservesFocusAndRecordsCPUCost() {
        let model = LibraryModel(preview: false)
        model.games = (0..<720).map { index in
            Game(id: .init(source: "fixture", value: String(index)), title: "Game \(720 - index)",
                 status: .installed, isFavorite: true, lastPlayedAt: Date(timeIntervalSince1970: Double(index)),
                 installedAt: Date(timeIntervalSince1970: Double(index)))
        }
        model.selectTab(.library)
        let ordered = model.filteredGames.map(\.id)
        var milliseconds: [Double] = []
        for step in 0..<120 {
            let start = CACurrentMediaTime()
            model.perform(step < 60 ? .nextPage : .previousPage)
            let visible = model.libraryVisibleIndices
            let focused = model.focusedGame?.id
            let games = model.filteredGames
            let rows = model.rows
            milliseconds.append((CACurrentMediaTime() - start) * 1000)
            XCTAssertEqual(focused, ordered[model.libraryCursor.index])
            XCTAssertTrue(visible.contains(model.libraryCursor.index))
            XCTAssertLessThanOrEqual(visible.count, 48)
            XCTAssertEqual(games.count, 720)
            XCTAssertEqual(rows.first?.itemCount, 16)
        }
        XCTAssertEqual(model.libraryCursor.index, 0)
        milliseconds.sort()
        print("Library navigation CPU: 720 games, 120 paging actions, mean \(milliseconds.reduce(0, +) / Double(milliseconds.count)) ms, p95 \(milliseconds[113]) ms, max \(milliseconds.last!) ms. Excludes rendering/GPU.")
        model.stopServices()
    }
}
