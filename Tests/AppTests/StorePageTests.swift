import XCTest
import Domain
@testable import Playden

final class StorePageTests: XCTestCase {
    @MainActor func testSteamGamesOpenStorePageThatScrollsWithoutEscapingModal() throws {
        let model = LibraryModel()
        let id = GameID(source: "steam", value: "17410")
        model.games = [Game(id: id, title: "Mirror's Edge", status: .notInstalled)]
        model.detailID = id
        XCTAssertEqual(model.detailActions.suffix(2), ["Store page", "More"])
        XCTAssertEqual(model.storePageURL(id)?.absoluteString, "https://store.steampowered.com/app/17410/")
        model.detailAction = try XCTUnwrap(model.detailActions.firstIndex(of: "Store page")); model.activateDetail()
        XCTAssertEqual(model.panel, .storePage(id)); let tab = model.tab
        model.perform(.move(.down)); XCTAssertEqual(model.storeScrollRequest.points, 120)
        model.perform(.nextPage); XCTAssertEqual(model.storeScrollRequest.points, 540)
        model.perform(.previousPage); XCTAssertEqual(model.storeScrollRequest.points, -540)
        model.perform(.move(.up)); XCTAssertEqual(model.storeScrollRequest.sequence, 4)
        model.perform(.nextTab); XCTAssertEqual(model.tab, tab); XCTAssertEqual(model.panel, .storePage(id))
        model.perform(.move(.right)); XCTAssertEqual(model.storeActionIndex, 1)
        model.perform(.move(.right)); XCTAssertEqual(model.storeActionIndex, 1)
        model.perform(.move(.left)); model.perform(.confirm); XCTAssertNil(model.panel)
        XCTAssertEqual(model.detailID, id)
        model.show(.storePage(id)); XCTAssertEqual(model.storeScrollRequest.sequence, 0); XCTAssertEqual(model.storeActionIndex, 0)
        model.perform(.back); XCTAssertNil(model.panel); XCTAssertEqual(model.detailID, id)
    }
    @MainActor func testNonSteamGamesHaveNoStorePage() {
        let model = LibraryModel()
        let id = GameID(source: "fixture", value: "1")
        model.games = [Game(id: id, title: "Fixture", status: .installed)]
        model.detailID = id
        XCTAssertNil(model.storePageURL(id))
        XCTAssertFalse(model.detailActions.contains("Store page"))
    }
}
