import XCTest
import Domain
import SteamCore
@testable import Sources

final class SteamDownloadSizeTests: XCTestCase {
    func testSizeCountsOnlyEligibleEntitledCompressedContent() throws {
        let app = AppInfo(appID: 100, name: "Game", depots: [
            .init(id: 1, manifestGID: 9, size: 1000, downloadSize: 400),
            .init(id: 2, manifestGID: 10, downloadSize: 9000),
            .init(id: 3, osList: "macos", manifestGID: 10, downloadSize: 9000),
            .init(id: 4, isDLC: true, dlcAppID: 200, manifestGID: 11, downloadSize: 100)])
        let result = try SteamSource.downloadSize(app: app, owned: .init(appIDs: [100, 200], depotIDs: [1, 3, 4]), accountKey: "a")
        XCTAssertEqual(result.bytes, 500); XCTAssertEqual(result.manifestIDs, ["1": "9", "4": "11"])
        XCTAssertFalse(result.precise)
    }
    func testMissingCompressedSizeDoesNotBecomeZeroOrPartialTotal() throws {
        let app = AppInfo(appID: 100, name: "Game", depots: [.init(id: 1, manifestGID: 9, size: 1000)])
        let result = try SteamSource.downloadSize(app: app, owned: .init(appIDs: [100], depotIDs: [1]), accountKey: "a")
        XCTAssertNil(result.bytes)
        XCTAssertTrue(result.isFresh(at: result.checkedAt.addingTimeInterval(60)))
        XCTAssertFalse(result.isFresh(at: result.checkedAt.addingTimeInterval(901)))
    }
}
