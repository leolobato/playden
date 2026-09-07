import XCTest
import Domain
import Runner
import Catalog
@testable import BigScreen

private actor SetupVolumes: VolumeManaging {
    func availableVolumes() async throws -> [GamesVolume] {
        [GamesVolume(id: "fixture-disk", name: "Games SSD", mountURL: URL(fileURLWithPath: "/fixture"), gamesRoot: URL(fileURLWithPath: "/fixture/games"), freeBytes: 900_000_000_000, isRecommended: true)]
    }
    func select(_ volume: GamesVolume) async throws -> GamesVolumeSelection {
        GamesVolumeSelection(volumeID: volume.id, rootBookmark: Data("fixture".utf8), lastKnownRoot: volume.gamesRoot, relativeRoot: "games")
    }
    func resolve(_ selection: GamesVolumeSelection) async throws -> URL { selection.lastKnownRoot }
}
private actor SetupRuntime: BottleManaging {
    var fail = true
    func inspect() async -> RuntimeInfo { RuntimeInfo(version: "26.2", templateVersion: "1", templateReady: false) }
    func prepareTemplate(onProgress: @escaping @Sendable (TemplateStage) -> Void) async throws -> RuntimeInfo {
        onProgress(.creating)
        if fail { fail = false; throw OperationFailure(stage: "Create template", reason: "Fixture creation failed.", output: "fixture") }
        onProgress(.ready)
        return RuntimeInfo(version: "26.2", templateVersion: "1", templateReady: true)
    }
}
final class SetupInteractionTests: XCTestCase {
    @MainActor func testOnboardingVolumeFailureRetryAndCompletionPersist() async throws {
        let catalog = try CatalogStore()
        let model = LibraryModel(catalog: catalog, preview: false, runtime: SetupRuntime(), volumeStore: SetupVolumes())
        model.identity = SourceIdentity(sourceID: "fixture", displayName: "Fixture")
        model.startSetupServices()
        XCTAssertEqual(model.setupScreen, .controller)
        model.perform(.nextTab)
        XCTAssertEqual(model.tab, .home)
        model.perform(.confirm)
        await model.setupTask?.value
        XCTAssertEqual(model.setupScreen, .volume)
        model.perform(.confirm)
        await model.setupTask?.value
        await model.setupTask?.value
        XCTAssertEqual(model.setupScreen, .runtime)
        XCTAssertEqual(model.setupFailure?.stage, "Create template")
        model.perform(.confirm)
        await model.setupTask?.value
        XCTAssertTrue(model.runtimeInfo?.templateReady == true)
        model.perform(.confirm)
        XCTAssertNil(model.setupScreen)
        let saved = try catalog.preferences()
        XCTAssertTrue(saved.setupCompleted)
        XCTAssertEqual(saved.gamesVolume?.volumeID, "fixture-disk")
        let restored = LibraryModel(catalog: catalog, preview: false)
        restored.startSetupServices()
        XCTAssertNil(restored.setupScreen)
        XCTAssertEqual(restored.gamesVolume, saved.gamesVolume)
    }
    @MainActor func testChoosingDisplayPreservesOtherPreferencesAndCallsWindowOwner() throws {
        let catalog = try CatalogStore()
        var preferences = LibraryPreferences(); preferences.downloadWhilePlaying = true; preferences.setupCompleted = true
        try catalog.savePreferences(preferences)
        let model = LibraryModel(catalog: catalog, preview: false)
        model.setupScreen = .display
        model.displays = [DisplayChoice(id: 42, name: "TV", resolution: "3840 × 2160")]
        var moved: UInt32?
        model.onDisplaySelected = { moved = $0 }
        model.perform(.confirm)
        XCTAssertEqual(moved, 42)
        XCTAssertNil(model.setupScreen)
        let saved = try catalog.preferences()
        XCTAssertEqual(saved.selectedDisplayID, 42)
        XCTAssertTrue(saved.downloadWhilePlaying)
        XCTAssertTrue(saved.setupCompleted)
    }
    @MainActor func testSkipSetupRetainsLibraryAccessAndDoesNotInventAnInstallation() throws {
        let catalog = try CatalogStore()
        let model = LibraryModel(catalog: catalog, preview: false)
        model.startSetupServices()
        model.perform(.back)
        XCTAssertNil(model.setupScreen)
        XCTAssertTrue(try catalog.preferences().setupCompleted)
        XCTAssertNil(try catalog.preferences().gamesVolume)
        XCTAssertTrue(model.games.isEmpty)
        model.perform(.nextTab)
        XCTAssertEqual(model.tab, .library)
    }
}
