import XCTest
import Catalog
import Domain
@testable import Playden

final class StoresInteractionTests: XCTestCase {
    private func externalInstall(_ game: SourceGameRecord, availability: ExternalLocation.Availability) -> InstallationRecord {
        let app = URL(fileURLWithPath: "/Applications/\(game.title).app")
        var record = InstallationRecord(game: game, location: GameLocation(volumeID: "", lastKnownRoot: app.deletingLastPathComponent(), relativePath: app.lastPathComponent),
            bottleID: "", manifestIDs: [:], templateVersion: "", launchSpec: LaunchSpec(executableRelativePath: app.lastPathComponent), installedBytes: 0)
        record.runtime = .native
        record.external = ExternalLocation(bookmark: nil, lastKnownPath: app, availability: availability)
        return record
    }

    @MainActor func testMacAppsShowTheirScannedAvailabilityPlatformAndTitleOverride() throws {
        let catalog = try CatalogStore()
        let games = ["Here", "Gone", "Unplugged"].map { SourceGameRecord(id: GameID(source: SourceID.local, value: $0), title: $0, metadataUpdatedAt: .now) }
        try catalog.replaceExternalCatalog(source: SourceID.local, games: games, installations: [
            externalInstall(games[0], availability: .available), externalInstall(games[1], availability: .missing),
            externalInstall(games[2], availability: .volumeUnavailable),
        ])
        var edits = GameEdits(); edits.titleOverride = "Renamed"
        try catalog.saveEdits(edits, for: games[0].id)
        let model = LibraryModel(catalog: catalog, preview: false)
        let byID = Dictionary(uniqueKeysWithValues: model.games.map { ($0.id, $0) })
        XCTAssertEqual(byID[games[0].id]?.status, .installed)
        XCTAssertEqual(byID[games[0].id]?.title, "Renamed")
        XCTAssertEqual(byID[games[0].id]?.installedPlatform, .macOS)
        XCTAssertEqual(byID[games[0].id]?.isExternal, true)
        XCTAssertEqual(byID[games[1].id]?.status, .missing)
        XCTAssertEqual(byID[games[2].id]?.status, .driveDisconnected)
    }

    @MainActor func testSavingEditsKeepsFieldsOtherScreensOwn() throws {
        let catalog = try CatalogStore()
        let game = SourceGameRecord(id: GameID(source: SourceID.steam, value: "10"), title: "Two builds")
        try catalog.replaceSourceCatalog(source: SourceID.steam, games: [game])
        var edits = GameEdits(); edits.titleOverride = "Mine"; edits.preferredPlatform = .macOS
        try catalog.saveEdits(edits, for: game.id)
        let model = LibraryModel(catalog: catalog, preview: false)
        let loaded = try XCTUnwrap(model.games.first)
        XCTAssertEqual(model.edits(for: loaded).titleOverride, "Mine")
        XCTAssertEqual(model.edits(for: loaded).preferredPlatform, .macOS)
    }
}
