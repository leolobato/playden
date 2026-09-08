import XCTest
import Domain
import Catalog

final class DownloadSizeCacheTests: XCTestCase {
    func testPersistentAccountScopedCacheSurvivesMetadataRefreshAndInvalidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("catalog.sqlite").path
        let catalog = try CatalogStore(path: path)
        let game = SourceGameRecord(id: .init(source: "fixture", value: "1"), title: "Game")
        try catalog.replaceSourceCatalog(source: "fixture", games: [game])
        let size = DownloadSizeEstimate(accountKey: "account-a", bytes: 1000, manifestIDs: ["1": "9"])
        try catalog.saveDownloadSize(size, for: game.id)
        try catalog.replaceSourceCatalog(source: "fixture", games: [game])
        _ = try catalog.updateMetadata(game)
        let reopened = try CatalogStore(path: path)
        XCTAssertEqual(try reopened.downloadSize(for: game.id, accountKey: "account-a"), size)
        XCTAssertNil(try reopened.downloadSize(for: game.id, accountKey: "account-b"))
        try reopened.invalidateDownloadSizes(source: "fixture")
        let stale = try XCTUnwrap(reopened.downloadSize(for: game.id, accountKey: "account-a"))
        XCTAssertFalse(stale.isFresh()); XCTAssertEqual(stale.bytes, 1000)
        try reopened.resetAppData()
        XCTAssertNil(try reopened.downloadSize(for: game.id, accountKey: "account-a"))
    }
    func testPreciseSizeSurvivesSameManifestEstimateButNewVersionReplacesIt() throws {
        let catalog = try CatalogStore(), game = SourceGameRecord(id: .init(source: "fixture", value: "1"), title: "Game")
        try catalog.replaceSourceCatalog(source: "fixture", games: [game])
        let now = Date.now
        try catalog.saveDownloadSize(.init(accountKey: "a", bytes: 900, manifestIDs: ["1": "9"], precise: true, checkedAt: now), for: game.id)
        try catalog.saveDownloadSize(.init(accountKey: "a", bytes: 1000, manifestIDs: ["1": "9"], checkedAt: now.addingTimeInterval(1)), for: game.id)
        XCTAssertEqual(try catalog.downloadSize(for: game.id, accountKey: "a")?.bytes, 900)
        try catalog.saveDownloadSize(.init(accountKey: "a", bytes: 2000, manifestIDs: ["1": "10"], checkedAt: now.addingTimeInterval(2)), for: game.id)
        XCTAssertEqual(try catalog.downloadSize(for: game.id, accountKey: "a")?.bytes, 2000)
        XCTAssertEqual(try catalog.downloadSize(for: game.id, accountKey: "a")?.precise, false)
        try catalog.saveDownloadSize(.init(accountKey: "a", bytes: 500, manifestIDs: [:], checkedAt: now), for: game.id)
        XCTAssertEqual(try catalog.downloadSize(for: game.id, accountKey: "a")?.bytes, 2000)
    }
}
