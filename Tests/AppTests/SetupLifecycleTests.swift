import XCTest
import Domain
import Runner
import Catalog
@testable import Playden

/// Deliberately ignores cancellation to exercise late replies from external runtime work.
private actor DelayedSetupRuntime: BottleManaging {
    var inspectEntered = false
    var preparationCount = 0
    var holdInspection: Bool
    private var inspection: CheckedContinuation<RuntimeInfo, Never>?
    private var preparations: [Int: CheckedContinuation<RuntimeInfo, Never>] = [:]
    private var progress: [Int: @Sendable (TemplateStage) -> Void] = [:]
    init(holdInspection: Bool = false) { self.holdInspection = holdInspection }
    func inspect() async -> RuntimeInfo {
        inspectEntered = true
        if holdInspection { return await withCheckedContinuation { inspection = $0 } }
        return .init(version: "26.2", templateVersion: "1", templateReady: false)
    }
    func finishInspection() {
        inspection?.resume(returning: .init(version: "26.2", templateVersion: "1", templateReady: false))
        inspection = nil
    }
    func prepareTemplate(onProgress: @escaping @Sendable (TemplateStage) -> Void) async throws -> RuntimeInfo {
        preparationCount += 1
        let count = preparationCount
        progress[count] = onProgress; onProgress(.creating)
        return await withCheckedContinuation { preparations[count] = $0 }
    }
    func finishPreparation(_ count: Int) {
        preparations.removeValue(forKey: count)?.resume(returning: .init(version: "26.2", templateVersion: "1", templateReady: true))
    }
    func report(_ stage: TemplateStage, preparation: Int) { progress[preparation]?(stage) }
}

private actor SetupChoiceVolumes: VolumeManaging {
    let choices = ["home", "recommended", "saved"].map {
        GamesVolume(id: $0, name: $0, mountURL: URL(fileURLWithPath: "/fixture/" + $0),
            gamesRoot: URL(fileURLWithPath: "/fixture/" + $0 + "/games"), freeBytes: 900_000_000,
            isRecommended: $0 == "recommended")
    }
    var selected: String?
    func availableVolumes() async throws -> [GamesVolume] { choices }
    func select(_ volume: GamesVolume) async throws -> GamesVolumeSelection {
        selected = volume.id
        return .init(volumeID: volume.id, rootBookmark: Data(), lastKnownRoot: volume.gamesRoot, relativeRoot: "games")
    }
    func resolve(_ selection: GamesVolumeSelection) async throws -> URL { selection.lastKnownRoot }
}

@MainActor final class SetupLifecycleTests: XCTestCase {
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The delayed setup fixture did not reach its expected state")
        throw CancellationError()
    }
    func testStartupInspectionIsJoinedBeforePreparationAndCannotReplaceItsResult() async throws {
        let runtime = DelayedSetupRuntime(holdInspection: true)
        let model = LibraryModel(catalog: try CatalogStore(), preview: false, runtime: runtime)
        model.startSetupServices()
        try await wait { await runtime.inspectEntered }
        model.openRuntimeSetup(firstRun: true)
        let worker = model.setupTask
        let before = await runtime.preparationCount
        XCTAssertEqual(before, 0)
        await runtime.finishInspection()
        try await wait { await runtime.preparationCount == 1 }
        await runtime.finishPreparation(1)
        await worker?.value
        XCTAssertTrue(model.runtimeInfo?.templateReady == true)
        XCTAssertEqual(model.templateStage, .ready)
        XCTAssertNil(model.setupFailure)
        XCTAssertEqual(model.setupActions, ["Let’s play"])
        model.stopServices()
    }
    func testStoppedPreparationCannotReportSuccessAndOldProgressCannotChangeRetry() async throws {
        let runtime = DelayedSetupRuntime()
        let model = LibraryModel(catalog: try CatalogStore(), preview: false, runtime: runtime)
        model.openRuntimeSetup(firstRun: true)
        try await wait { await runtime.preparationCount == 1 }
        let first = model.setupTask
        model.perform(.confirm) // Stop setup
        await runtime.finishPreparation(1)
        await first?.value
        XCTAssertFalse(model.setupBusy)
        XCTAssertFalse(model.runtimeInfo?.templateReady == true)
        XCTAssertTrue(model.setupFailure?.reason.contains("stopped") == true)
        model.perform(.confirm) // Retry
        try await wait { await runtime.preparationCount == 2 }
        try await wait { model.templateStage == .creating }
        await runtime.report(.ready, preparation: 1)
        // Deliver the old callback's MainActor task while the new worker is still active.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.templateStage, .creating)
        XCTAssertTrue(model.setupBusy)
        await runtime.finishPreparation(2)
        await model.setupTask?.value
        XCTAssertNil(model.setupFailure)
        XCTAssertEqual(model.templateStage, .ready)
        model.stopServices()
    }
    func testClosingAndReopeningRuntimeRejectsOldInspection() async throws {
        let runtime = DelayedSetupRuntime(holdInspection: true)
        let model = LibraryModel(catalog: try CatalogStore(), preview: false, runtime: runtime)
        model.openRuntimeSetup()
        try await wait { await runtime.inspectEntered }
        let old = model.setupTask
        model.perform(.back)
        XCTAssertNil(model.setupScreen)
        model.openRuntimeSetup(firstRun: true)
        await runtime.finishInspection()
        await old?.value
        try await wait { await runtime.preparationCount == 1 }
        XCTAssertTrue(model.setupBusy)
        XCTAssertNil(model.runtimeInfo)
        await runtime.finishPreparation(1)
        await model.setupTask?.value
        XCTAssertTrue(model.runtimeInfo?.templateReady == true)
        model.stopServices()
    }
    func testVolumeFocusUsesSavedDriveThenRecommendationAndConfirmationMatchesFocus() async throws {
        for saved in [false, true] {
            let catalog = try CatalogStore(), volumes = SetupChoiceVolumes()
            if saved {
                var preferences = LibraryPreferences()
                preferences.gamesVolume = .init(volumeID: "saved", rootBookmark: Data(),
                    lastKnownRoot: URL(fileURLWithPath: "/fixture/saved/games"), relativeRoot: "games")
                try catalog.savePreferences(preferences)
            }
            let model = LibraryModel(catalog: catalog, preview: false, volumeStore: volumes)
            model.openVolumeSetup()
            await model.setupTask?.value
            XCTAssertEqual(model.setupIndex, saved ? 2 : 1)
            XCTAssertEqual(model.selectedVolumeID, saved ? "saved" : "recommended")
            model.perform(.confirm)
            await model.setupTask?.value
            let selected = await volumes.selected
            XCTAssertEqual(selected, saved ? "saved" : "recommended")
            XCTAssertEqual(try catalog.preferences().gamesVolume?.volumeID, selected)
            model.stopServices()
        }
    }
}
