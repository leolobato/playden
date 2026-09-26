import XCTest
import Catalog
import Domain
import Sources
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

    @MainActor private func mixedLibrary() -> LibraryModel {
        let model = LibraryModel(preview: false)
        var steam = Game(id: GameID(source: SourceID.steam, value: "1"), title: "Two Builds", status: .notInstalled)
        steam.platforms = [.windows, .macOS]
        var windows = Game(id: GameID(source: SourceID.steam, value: "2"), title: "Windows Only", status: .installed)
        windows.platforms = [.windows]; windows.installedPlatform = .windows
        var mac = Game(id: GameID(source: SourceID.local, value: "3"), title: "On This Mac", status: .installed)
        mac.platforms = [.macOS]; mac.installedPlatform = .macOS; mac.isExternal = true
        var missing = Game(id: GameID(source: SourceID.local, value: "4"), title: "Gone Away", status: .missing)
        missing.platforms = [.macOS]; missing.installedPlatform = .macOS; missing.isExternal = true
        model.games = [steam, windows, mac, missing]
        return model
    }

    @MainActor func testStoresAppearInTheRailOnlyWithASecondStore() {
        let model = mixedLibrary()
        XCTAssertEqual(model.libraryFilters.prefix(6), [.installed, .all, .favorites, .hidden, .store(SourceID.steam), .store(SourceID.local)])
        XCTAssertEqual(model.filterTitle(.store(SourceID.local)), "This Mac")
        XCTAssertEqual(model.count(for: .store(SourceID.local)), 2)
        model.filter = .store(SourceID.local)
        XCTAssertEqual(model.filteredGames.map(\.title), ["Gone Away", "On This Mac"])
        XCTAssertFalse(model.filterLayout.headings.contains { $0.title == "Store" }, "A store scope makes the Store filter redundant")
        model.games.removeAll { $0.id.source == SourceID.local }
        XCTAssertFalse(model.libraryFilters.contains(.store(SourceID.steam)), "One store needs no store entries")
        XCTAssertFalse(model.showsStores)
    }

    @MainActor func testPlatformAndMissingFilters() {
        let model = mixedLibrary()
        let headings = model.filterLayout.headings.map(\.title)
        XCTAssertTrue(headings.contains("Store")); XCTAssertTrue(headings.contains("Platform"))
        XCTAssertTrue(model.filterLayout.chips.contains { $0.choice == .installation(.missing) })
        model.refinements.platform = .macOS
        XCTAssertEqual(Set(model.filteredGames.map(\.title)), ["Two Builds", "On This Mac", "Gone Away"], "Not installed games match any build they offer")
        model.refinements = .init(); model.refinements.installation = .missing
        XCTAssertEqual(model.filteredGames.map(\.title), ["Gone Away"])
        model.refinements = .init(); model.refinements.source = SourceID.local
        XCTAssertEqual(FilterChoice.source(SourceID.local).title, "This Mac")
    }

    @MainActor func testMacAppsOfferRenameAndRemoveInsteadOfInstallTools() {
        let model = mixedLibrary()
        model.detailID = GameID(source: SourceID.local, value: "3")
        XCTAssertEqual(model.detailActions.first, "Play")
        XCTAssertFalse(model.detailActions.contains("Game settings"), "CrossOver profiles don't apply to Mac apps")
        XCTAssertTrue(model.contextActions.contains("Rename")); XCTAssertTrue(model.contextActions.contains("Remove from library"))
        XCTAssertFalse(model.contextActions.contains("Uninstall")); XCTAssertFalse(model.contextActions.contains("Verify files"))
        model.show(.confirmation(.removeFromLibrary(GameID(source: SourceID.local, value: "3"))))
        XCTAssertEqual(model.panelActions, ["Cancel", "Remove from library"])
        XCTAssertEqual(model.confirmationTitle(.removeFromLibrary(GameID(source: SourceID.local, value: "3"))), "Remove On This Mac from Playden?")
        model.panel = nil
        model.detailID = GameID(source: SourceID.local, value: "4")
        XCTAssertEqual(model.detailActions.first, "Locate game")
        XCTAssertEqual(model.runsAsLabel(model.focusedGame!), "macOS")
    }

    @MainActor func testTwoBuildGamesPreferTheMacVersionAndOfferTheOther() {
        let model = mixedLibrary()
        let id = GameID(source: SourceID.steam, value: "1")
        XCTAssertEqual(model.defaultInstallPlatform(id), .macOS)
        model.preferMacVersions = false
        XCTAssertEqual(model.defaultInstallPlatform(id), .windows)
        model.storedEdits[id] = { var edits = GameEdits(); edits.preferredPlatform = .macOS; return edits }()
        XCTAssertEqual(model.defaultInstallPlatform(id), .macOS, "The player's last choice wins over the preference")
        model.installPlatform = .macOS
        XCTAssertEqual(model.otherPlatform(for: id), .windows)
        XCTAssertNil(model.otherPlatform(for: GameID(source: SourceID.steam, value: "2")), "One build, no choice")
        XCTAssertEqual(model.runsAsLabel(model.games[0]), "macOS or Windows")
    }

    @MainActor func testStoresSettingsListEveryStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StoresSettings-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let local = LocalSource(store: LocalLibraryStore(file: root.appendingPathComponent("local.json")), suggestionRoots: [])
        let model = LibraryModel(catalog: try CatalogStore(), preview: false, otherSources: [local])
        XCTAssertEqual(model.storeSettingsRows, [.thisMac, .folders])
        model.settingsSection = 0
        XCTAssertEqual(SettingsScreen(model: model).settings.map(\.0), ["This Mac", "Watched folders"])
        XCTAssertTrue(model.needsGames)
        XCTAssertEqual(model.addGamesTitle, "Add games")
        model.startAddingGames()
        XCTAssertEqual(model.tab, .settings); XCTAssertEqual(model.settingsSection, 0)
    }

    @MainActor func testFirstRunCanFinishWithOnlyThisMac() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StoresSetup-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let local = LocalSource(store: LocalLibraryStore(file: root.appendingPathComponent("local.json")), suggestionRoots: [])
        let catalog = try CatalogStore()
        let model = LibraryModel(catalog: catalog, preview: false, otherSources: [local])
        model.onboarding = true; model.setupScreen = .permissions; model.setupIndex = 0
        model.activateSetup()
        XCTAssertEqual(model.setupScreen, .games)
        XCTAssertEqual(model.setupActions, ["Sign in to Steam", "Add games on this Mac", "Skip for now"])
        model.setupIndex = 2; model.activateSetup()
        XCTAssertNil(model.setupScreen, "No games drive or CrossOver is needed without a download store")
        XCTAssertTrue(try catalog.preferences().setupCompleted)
    }
}
