import XCTest
import Domain
@testable import Catalog

private struct ScannedSource: GameSource {
    let id = "local", displayName = "This Mac"
    var auth: any SourceAuth { NoSourceAuth() }
    var capabilities: SourceCapabilities { SourceCapabilities(account: .none, acquisition: .external) }
    var records: [SourceGameRecord]
    func ownedGames() async throws -> [SourceGameRecord] { records }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { XCTFail("Scanned stores have no remote metadata"); return game }
    func installer(for game: SourceGameRecord) throws -> any Installer { throw SourceFailure.unavailable }
    func externalInstallations(for games: [SourceGameRecord]) async throws -> [InstallationRecord] {
        games.map { ExternalCatalogTests.installation(for: $0) }
    }
}

final class ExternalCatalogTests: XCTestCase {
    static func installation(for game: SourceGameRecord, path: String? = nil) -> InstallationRecord {
        let app = URL(fileURLWithPath: path ?? "/Applications/\(game.title).app")
        var record = InstallationRecord(game: game, location: GameLocation(volumeID: "", lastKnownRoot: app.deletingLastPathComponent(),
            relativePath: app.lastPathComponent), bottleID: "", manifestIDs: [:], templateVersion: "", launchSpec: LaunchSpec(executableRelativePath: app.lastPathComponent),
            installedAt: Date(timeIntervalSince1970: 1_700_000_000), installedBytes: 0)
        record.runtime = .native
        record.external = ExternalLocation(bookmark: nil, lastKnownPath: app, bundleIdentifier: "com.example.\(game.id.value)")
        return record
    }
    private func game(_ value: String) -> SourceGameRecord {
        SourceGameRecord(id: GameID(source: "local", value: value), title: "Game \(value)", metadataUpdatedAt: .now)
    }

    func testScanReplacesOnlyExternalInstallationsAndKeepsTheirIdentity() async throws {
        let store = try CatalogStore()
        let sync = LibrarySyncCoordinator(catalog: store, metadataDelay: .zero)
        _ = try await sync.refresh(source: ScannedSource(records: [game("a"), game("b")]))
        let first = try store.snapshot().entries.compactMap(\.installation)
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first.allSatisfy { $0.isExternal && $0.runtimeBinding == .native })

        _ = try await sync.refresh(source: ScannedSource(records: [game("a")]))
        let second = try store.snapshot().entries
        XCTAssertEqual(second.map(\.id.value), ["a"], "A game that left the scan leaves the library")
        XCTAssertEqual(second.first?.installation?.id, first.first { $0.gameID.value == "a" }?.id, "Rescans keep the installation identity")
    }

    func testExternalReplacementRefusesOwnedRecordsAndNeverOverwritesThem() throws {
        let store = try CatalogStore()
        let owned = game("owned")
        var ownedInstall = Self.installation(for: owned); ownedInstall.external = nil; ownedInstall.runtime = nil
        XCTAssertThrowsError(try store.replaceExternalCatalog(source: "local", games: [owned], installations: [ownedInstall]))
        try store.replaceSourceCatalog(source: "local", games: [owned])
        try store.saveInstallation(ownedInstall)
        try store.replaceExternalCatalog(source: "local", games: [owned], installations: [Self.installation(for: owned)])
        XCTAssertEqual(try store.snapshot().entries.first?.installation?.isExternal, false)
    }

    func testLegacyRecordsDecodeAsWindowsCrossOverInstalls() throws {
        let record = game("legacy")
        let installation = Self.installation(for: record)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(installation)) as? [String: Any])
        json.removeValue(forKey: "runtime"); json.removeValue(forKey: "external")
        let legacy = try JSONDecoder().decode(InstallationRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.runtimeBinding, .crossOver); XCTAssertFalse(legacy.isExternal); XCTAssertTrue(legacy.usesBottle)

        let steam = SourceGameRecord(id: GameID(source: SourceID.steam, value: "1"), title: "Steam game")
        XCTAssertEqual(steam.availablePlatforms, [.windows], "Records from before platforms existed are Windows games")
        let run = RunningGame(bottle: GameBottle(gameID: record.id, name: "b", ownershipToken: UUID()), launcher: ProcessIdentity(pid: 1, startSeconds: 1, startMicroseconds: 1))
        var runJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        runJSON.removeValue(forKey: "native")
        XCTAssertNil(try JSONDecoder().decode(RunningGame.self, from: JSONSerialization.data(withJSONObject: runJSON)).native)
    }

    func testMetadataRefreshKeepsKnownPlatformsWhenAResponseOmitsThem() throws {
        let store = try CatalogStore()
        var record = SourceGameRecord(id: GameID(source: SourceID.steam, value: "2"), title: "Two builds")
        try store.replaceSourceCatalog(source: SourceID.steam, games: [record])
        record.platforms = [.windows, .macOS]; record.metadataUpdatedAt = .now
        XCTAssertTrue(try store.updateMetadata(record))
        var owned = record; owned.platforms = nil; owned.metadataUpdatedAt = nil
        try store.replaceSourceCatalog(source: SourceID.steam, games: [owned])
        XCTAssertEqual(try store.snapshot().entries.first?.source.availablePlatforms, [.windows, .macOS])
    }
}
