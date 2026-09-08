import XCTest
import Domain
import Runner
import Catalog
@testable import Playden

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

private actor RuntimeStatusFixture: BottleManaging {
    var current = RuntimeInfo(version: "26.2", templateVersion: "1", templateReady: true)
    var preparations = 0
    var inspections = 0
    func inspect() async -> RuntimeInfo { inspections += 1; return current }
    func setMissing() { current = RuntimeInfo(version: nil, templateVersion: "1", templateReady: false,
        failure: OperationFailure(stage: "Check runtime", reason: "Install CrossOver in Applications, then try again.", output: "fixture")) }
    func prepareTemplate(onProgress: @escaping @Sendable (TemplateStage) -> Void) async throws -> RuntimeInfo {
        preparations += 1; onProgress(.ready); return current
    }
}

extension SetupInteractionTests {
    @MainActor func testRuntimeSettingsRefreshesRealStateWithoutStartingOnboardingOrPreparation() async throws {
        let runtime = RuntimeStatusFixture(), catalog = try CatalogStore()
        var preferences = LibraryPreferences(); preferences.setupCompleted = true
        try catalog.savePreferences(preferences)
        let model = LibraryModel(catalog: catalog, preview: false, runtime: runtime)
        model.selectTab(.settings); model.settingsSection = 1; model.settingsIndex = 3; model.settingsRailFocused = false
        model.runtimeInfo = RuntimeInfo(version: nil, templateVersion: "1", templateReady: false)
        model.templateStage = .creating
        model.activateSetting()
        XCTAssertFalse(model.onboarding)
        XCTAssertTrue(model.runtimeChecking)
        XCTAssertEqual(model.setupActions, ["Back"])
        await model.setupTask?.value
        XCTAssertEqual(model.runtimeInfo?.version, "26.2")
        XCTAssertEqual(model.templateStage, .ready)
        XCTAssertFalse(model.setupBusy)
        XCTAssertEqual(model.setupActions, ["Check again", "Back"])
        let preparations = await runtime.preparations
        XCTAssertEqual(preparations, 0, "Opening a settings row must not run template setup")
        await runtime.setMissing()
        model.perform(.confirm)
        await model.setupTask?.value
        XCTAssertNotNil(model.setupFailure)
        XCTAssertEqual(model.setupActions, ["Retry setup", "Check again", "Back"])
        model.perform(.move(.down)); model.perform(.move(.down)); model.perform(.confirm)
        XCTAssertNil(model.setupScreen)
        XCTAssertEqual(model.tab, .settings)
        XCTAssertEqual(model.settingsIndex, 3)
        XCTAssertTrue(try catalog.preferences().setupCompleted)
    }
}
