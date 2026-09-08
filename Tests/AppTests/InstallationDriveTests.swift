import XCTest
import Catalog
import Domain
import Installs
@testable import Playden

private actor FixtureDrives: VolumeManaging {
    var disconnected: Set<String> = []
    var held = false
    var calls: [GamesVolumeSelection] = []
    func setDisconnected(_ values: Set<String>) { disconnected = values }
    func hold(_ value: Bool) { held = value }
    func availableVolumes() async throws -> [GamesVolume] { [] }
    func select(_ volume: GamesVolume) async throws -> GamesVolumeSelection { throw SourceFailure.unavailable }
    func resolve(_ selection: GamesVolumeSelection) async throws -> URL {
        calls.append(selection)
        let unavailable = disconnected.contains(selection.volumeID)
        while held { try await Task.sleep(for: .milliseconds(5)) }
        if unavailable { throw SourceFailure.unavailable }
        return selection.lastKnownRoot
    }
}

final class InstallationDriveTests: XCTestCase {
    private func installation(_ name: String, volume: String) -> InstallationRecord {
        let game = SourceGameRecord(id: .init(source: "fixture", value: name), title: name)
        var location = GameLocation(volumeID: volume, rootBookmark: Data(volume.utf8),
            lastKnownRoot: URL(fileURLWithPath: "/Volumes/\(volume)/games"), relativePath: "gn-fixture-\(name)/game")
        location.relativeRoot = "games"
        return .init(game: game, location: location, bottleID: "gn-fixture-\(name)", manifestIDs: [:],
                     templateVersion: "1", launchSpec: .init(executableRelativePath: "game.exe"), installedBytes: 100)
    }
    @MainActor private func settle(_ model: LibraryModel) async {
        await model.installationDriveTask?.value
    }

    @MainActor func testDisconnectedDriveKeepsInstalledGamesAndFocusAndReconnectsAutomatically() async throws {
        let catalog = try CatalogStore(), drives = FixtureDrives()
        let first = installation("Alpha", volume: "one"), second = installation("Beta", volume: "two")
        try catalog.saveInstallation(first); try catalog.saveInstallation(second)
        let model = LibraryModel(catalog: catalog, preview: false, volumeStore: drives)
        defer { model.stopServices() }
        await settle(model)
        model.selectTab(.library); model.filter = .installed
        model.libraryCursor = .init(index: 1)
        model.gamesVolume = .init(volumeID: "future-downloads", rootBookmark: Data(), lastKnownRoot: URL(fileURLWithPath: "/elsewhere"), relativeRoot: "games")
        await drives.setDisconnected(["two"])
        model.requestInstallationDriveRefresh(); await settle(model)
        XCTAssertEqual(model.filteredGames.count, 2)
        XCTAssertEqual(model.focusedGame?.id, second.gameID)
        XCTAssertEqual(model.focusedGame?.status, .driveDisconnected)
        XCTAssertEqual(model.games.first { $0.id == first.gameID }?.status, .installed)
        XCTAssertEqual(model.rows.first { $0.id == .recentlyInstalled }?.games.count, 2)
        model.openGame(try XCTUnwrap(model.focusedGame))
        XCTAssertEqual(model.detailActions.first, "Drive disconnected")
        XCTAssertFalse(model.detailActionEnabled(at: 0))
        XCTAssertTrue(model.installationDriveMessage?.contains("automatically") == true)
        model.perform(.confirm); XCTAssertNil(model.panel)
        model.perform(.move(.right)); model.perform(.confirm)
        XCTAssertTrue(model.focusedGame?.isFavorite == true)
        model.show(.context); model.panelIndex = 0; model.perform(.confirm)
        XCTAssertEqual(model.panel, .context)
        XCTAssertFalse(model.panelActionEnabled(at: 0))
        model.panel = nil; model.detailAction = 0
        await drives.setDisconnected([])
        model.requestInstallationDriveRefresh(); await settle(model)
        XCTAssertEqual(model.detailID, second.gameID)
        XCTAssertEqual(model.detailActions.first, "Play")
        XCTAssertTrue(model.detailActionEnabled(at: 0))
        XCTAssertNil(model.installationDriveMessage)
        XCTAssertEqual(try catalog.snapshot().entries.first { $0.id == second.gameID }?.installation, second)
        let checked = await drives.calls
        XCTAssertFalse(checked.contains { $0.volumeID == "future-downloads" })
    }

    @MainActor func testNewInstallationRejectsOldDriveReadAndCheckingDisablesPlay() async throws {
        let catalog = try CatalogStore(), drives = FixtureDrives()
        let original = installation("Alpha", volume: "old")
        try catalog.saveInstallation(original)
        await drives.hold(true)
        let model = LibraryModel(catalog: catalog, preview: false, volumeStore: drives)
        defer { model.stopServices() }
        model.openGame(model.games[0])
        XCTAssertEqual(model.detailActions.first, "Checking drive…")
        XCTAssertFalse(model.detailActionEnabled(at: 0))
        model.perform(.confirm); XCTAssertNil(model.panel)
        let deadline = ContinuousClock.now + .seconds(2)
        while await drives.calls.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        var replacement = original
        replacement.id = UUID(); replacement.location.volumeID = "new"
        try catalog.removeInstallation(id: original.id)
        try catalog.saveInstallation(replacement)
        await drives.setDisconnected(["new"])
        model.restoreCatalog()
        await drives.hold(false); await settle(model)
        XCTAssertEqual(model.focusedGame?.status, .driveDisconnected)
        XCTAssertEqual(model.installationDriveTargets[original.gameID]?.installationID, replacement.id)
        XCTAssertFalse(model.installationDriveAvailable[original.gameID] ?? true)
    }

    @MainActor func testDisconnectedRepairCannotOfferVerificationButQueueRecoveryStaysReachable() async throws {
        let catalog = try CatalogStore(), drives = FixtureDrives()
        var installed = installation("Alpha", volume: "one"); installed.needsRepair = true
        try catalog.saveInstallation(installed); await drives.setDisconnected(["one"])
        let model = LibraryModel(catalog: catalog, preview: false, volumeStore: drives)
        defer { model.stopServices() }
        await settle(model); model.openGame(model.games[0])
        XCTAssertEqual(model.detailActions.first, "Drive disconnected")
        var job = JobRecord(gameID: installed.gameID, kind: .repair); job.state = .failed
        model.installJobs = [job]; model.applyInstallStatuses()
        XCTAssertEqual(model.detailActions.first, "View verification")
        model.installJobs[0].state = .cancelled; model.applyInstallStatuses()
        XCTAssertEqual(model.focusedGame?.status, .driveDisconnected)
        await drives.setDisconnected([])
        model.requestInstallationDriveRefresh(); await settle(model)
        XCTAssertEqual(model.detailActions.first, "Verify files")
    }

    @MainActor func testRealResolverRejectsAnotherVolumeAtTheRecordedPath() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Playden-drive-read-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = GamesVolumeStore(home: folder)
        let choices = try await store.availableVolumes()
        let selected = try await store.select(try XCTUnwrap(choices.first { $0.name == "This Mac" }))
        let catalog = try CatalogStore()
        var installed = installation("Alpha", volume: selected.volumeID)
        installed.location.rootBookmark = selected.rootBookmark
        installed.location.lastKnownRoot = selected.lastKnownRoot
        installed.location.relativeRoot = selected.relativeRoot
        try catalog.saveInstallation(installed)
        let model = LibraryModel(catalog: catalog, preview: false, volumeStore: store)
        defer { model.stopServices() }
        await settle(model)
        XCTAssertEqual(model.games[0].status, .installed)
        installed.location.volumeID = UUID().uuidString
        try catalog.saveInstallation(installed); model.restoreCatalog(); await settle(model)
        XCTAssertEqual(model.games[0].status, .driveDisconnected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.lastKnownRoot.path))
    }
}
