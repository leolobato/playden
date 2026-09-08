import XCTest
import Domain
import Catalog
import Sessions
import Input
@testable import BigScreen

private actor LaunchChoiceSession: SessionManaging {
    var choices: [String?] = []
    func start(downloadWhilePlaying: Bool) async throws {}
    func updates() -> AsyncStream<SessionSnapshot> { AsyncStream { $0.finish() } }
    func play(_ id: GameID) async throws { choices.append(nil) }
    func play(_ id: GameID, launchOptionID: String) async throws { choices.append(launchOptionID) }
    func retryCloud(authorization: CloudSyncAuthorization?) async throws {}
    func playOffline() async throws {}
    func quit() async throws {}
    func setDownloadWhilePlaying(_ enabled: Bool) async throws {}
    func shutdown() async throws {}
}

@MainActor
final class LaunchOptionsTests: XCTestCase {
    private let id = GameID(source: "fixture", value: "launch-options")
    private var options: [LaunchOption] {
        [.init(id: "0", title: "Play", spec: .init(executableRelativePath: "Game.exe")),
         .init(id: "1", title: "DirectX 11", spec: .init(executableRelativePath: "Game.exe", arguments: ["-dx11"]))]
    }
    private func seed(_ catalog: CatalogStore, options: [LaunchOption]) throws {
        let game = SourceGameRecord(id: id, title: "Fixture")
        var installed = InstallationRecord(game: game, location: .init(volumeID: "fixture", lastKnownRoot: URL(fileURLWithPath: "/fixture"), relativePath: "game"),
            bottleID: "fixture", manifestIDs: [:], templateVersion: "1", launchSpec: options[0].spec, installedBytes: 1)
        if let existing = try catalog.snapshot().entries.first(where: { $0.id == id })?.installation { installed.id = existing.id }
        installed.plan = .init(game: game, manifestIDs: [:], estimate: .init(downloadBytes: 1, installedBytes: 1, requiredBytes: 1),
            launchSpec: options[0].spec, sourcePayload: Data(), launchOptions: options)
        try catalog.saveInstallation(installed)
    }
    func testChooseOnceCancelAndControllerNavigation() async throws {
        let catalog = try CatalogStore(), service = LaunchChoiceSession()
        try seed(catalog, options: options)
        let model = LibraryModel(catalog: catalog, preview: false, sessions: service); model.sessionReady = true
        model.beginPlay(id)
        XCTAssertEqual(model.panel, .launchOptions(id))
        model.perform(.back)
        let initial = await service.choices; XCTAssertTrue(initial.isEmpty)
        model.beginPlay(id)
        model.perform(.move(.down)); model.perform(.confirm)
        XCTAssertEqual(model.launchChoiceIndex, 1)
        model.panelIndex = options.count + 2; model.perform(.confirm)
        await model.sessionCommand?.value
        let choices = await service.choices; XCTAssertEqual(choices, ["1"])
        XCTAssertNil(try catalog.snapshot().entries.first?.edits.preferredLaunchOption)
        model.beginPlay(id); XCTAssertEqual(model.panel, .launchOptions(id))
    }
    func testAlwaysUseSurvivesRestartOtherEditsAndCanBeCleared() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("catalog.sqlite").path
        let catalog = try CatalogStore(path: path), service = LaunchChoiceSession()
        try seed(catalog, options: options)
        let model = LibraryModel(catalog: catalog, preview: false, sessions: service); model.sessionReady = true
        model.beginPlay(id)
        model.launchChoiceIndex = 1
        model.panelIndex = options.count; model.perform(.confirm)
        model.panelIndex = options.count + 2; model.perform(.confirm)
        await model.sessionCommand?.value
        model.detailID = id; model.toggleFavorite()
        let reopened = try CatalogStore(path: path)
        XCTAssertEqual(try reopened.snapshot().entries.first?.edits.preferredLaunchOption, options[1])
        XCTAssertEqual(try reopened.snapshot().entries.first?.edits.isFavorite, true)
        let next = LibraryModel(catalog: reopened, preview: false, sessions: service); next.sessionReady = true
        next.beginPlay(id); await next.sessionCommand?.value
        XCTAssertNil(next.panel)
        let choices = await service.choices; XCTAssertEqual(choices, ["1", "1"])
        next.detailID = id; next.show(.context)
        next.panelIndex = try XCTUnwrap(next.contextActions.firstIndex(of: "Launch options")); next.perform(.confirm)
        XCTAssertEqual(next.panel, .launchOptions(id)); XCTAssertTrue(next.launchAlwaysUse)
        next.panelIndex = options.count; next.perform(.confirm)
        next.panelIndex = options.count + 2; next.perform(.confirm)
        XCTAssertNil(try reopened.snapshot().entries.first?.edits.preferredLaunchOption)
        next.beginPlay(id); XCTAssertEqual(next.panel, .launchOptions(id))
    }
    func testChangedRememberedOptionPromptsAgainAndSingleOptionDoesNot() async throws {
        let catalog = try CatalogStore(), service = LaunchChoiceSession()
        try seed(catalog, options: options)
        var edits = GameEdits(); edits.preferredLaunchOption = .init(id: "1", title: "Old mode", spec: .init(executableRelativePath: "Old.exe"))
        try catalog.saveEdits(edits, for: id)
        let model = LibraryModel(catalog: catalog, preview: false, sessions: service); model.sessionReady = true
        model.beginPlay(id); XCTAssertEqual(model.panel, .launchOptions(id)); XCTAssertFalse(model.launchAlwaysUse)
        try seed(catalog, options: [options[0]])
        model.restoreCatalog(); model.panel = nil
        model.beginPlay(id); await model.sessionCommand?.value
        XCTAssertNil(model.panel)
        let choices = await service.choices; XCTAssertEqual(choices.count, 1); XCTAssertNil(choices[0])
    }
}
