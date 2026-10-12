import XCTest
import Domain
import Catalog
import Installs
@testable import Playden

private struct CleanupAuth: SourceAuth {
    func identity() async throws -> SourceIdentity? { nil }
    func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func signIn(accountName: String, password: String, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String, onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func cancelSignIn() async {}
    func signOut() async throws {}
}
private struct CleanupSource: GameSource {
    let id = "fixture", displayName = "Fixture", auth: any SourceAuth = CleanupAuth()
    var capabilities: SourceCapabilities { SourceCapabilities(account: .steam, acquisition: .download, cloudSaves: true) }
    func ownedGames() async throws -> [SourceGameRecord] { [] }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
    func installer(for game: SourceGameRecord) throws -> any Installer { CleanupInstaller(gameID: game.id) }
}
private struct CleanupInstaller: Installer {
    let gameID: GameID
    func resolve() async throws -> InstallPlan { throw SourceFailure.unavailable }
    func download(_ plan: InstallPlan, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws { throw SourceFailure.unavailable }
    func verifyOriginals(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?) async throws -> VerificationResult { throw SourceFailure.unavailable }
    func postInstall(_ plan: InstallPlan, at directory: URL) async throws -> InstallStaging { throw SourceFailure.unavailable }
    func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging) async throws -> LaunchSpec { throw SourceFailure.unavailable }
    func uninstall(_ plan: InstallPlan, at directory: URL) async throws { throw SourceFailure.unavailable }
    func saveMapping(_ plan: InstallPlan) throws -> SaveMapping { .init(rules: [.init(root: .game, directory: "saves", pattern: "*", cloudPrefix: "saves")], coverage: .metadata) }
}
private actor CleanupQueue: InstallQueuing {
    let catalog: CatalogStore
    var removed: [GameID] = []
    init(_ catalog: CatalogStore) { self.catalog = catalog }
    func start() async throws {}
    func shutdown() async {}
    func updates() -> AsyncStream<InstallQueueSnapshot> { AsyncStream { $0.finish() } }
    func offer(for game: SourceGameRecord, volume: GamesVolumeSelection) async throws -> InstallOffer { throw SourceFailure.unavailable }
    func enqueue(_ offer: InstallOffer) async throws -> UUID { throw SourceFailure.unavailable }
    func repair(_ gameID: GameID) async throws -> UUID { throw SourceFailure.unavailable }
    func uninstall(_ authorization: UninstallAuthorization) async throws -> UUID {
        let job = try catalog.beginUninstall(authorization); removed.append(authorization.review.installation.gameID); return job.id
    }
    func setPaused(_ paused: Bool, reason: PauseReason, jobID: UUID) async throws {}
    func retry(_ jobID: UUID) async throws {}
    func cancel(_ jobID: UUID) async throws {}
    func move(_ jobID: UUID, before otherID: UUID) async throws {}
    func setGameplayPaused(_ paused: Bool) async throws {}
}
/// Saves sync for every game except the ones listed as offline.
private actor CleanupCloud: CloudSyncManaging {
    let catalog: CatalogStore
    let offline: Set<GameID>
    init(_ catalog: CatalogStore, offline: Set<GameID>) { self.catalog = catalog; self.offline = offline }
    func updates() -> AsyncStream<[GameID: CloudSyncStatus]> { AsyncStream { $0.finish() } }
    func recoverInterruptedOperations() async throws {}
    func synchronize(_ installation: InstallationRecord, mapping: SaveMapping, preparingSessionID: UUID?, authorization: CloudSyncAuthorization?) async -> CloudSyncStatus {
        let id = installation.gameID, account = "fixture"
        do {
            var operation = try catalog.beginCloudSync(installation: installation, accountKey: account, mapping: mapping)
            operation = try catalog.stageCloudSync(operation,
                plan: .init(gameID: id, installationID: installation.id, accountKey: account, remoteRevision: 1, decisions: [], requiresAccountConfirmation: false),
                remote: .init(gameID: id, accountKey: account, revision: 1, files: []), localSnapshotID: UUID(), remoteSnapshotID: UUID())
            if offline.contains(id) {
                operation = try catalog.pauseCloudSync(operation, phase: .pending)
                return .init(gameID: id, state: .pendingUpload, operation: operation, message: "Steam is offline")
            }
            operation = try catalog.markCloudVerifying(operation)
            operation = try catalog.completeCloudSync(operation, baseline: .init(gameID: id, installationID: installation.id, accountKey: account, revision: 1, mapping: mapping, files: []))
            return .init(gameID: id, state: .upToDate, operation: operation, message: "Up to date")
        } catch { return .init(gameID: id, state: .failed, message: "Failed") }
    }
}

@MainActor final class StorageCleanupTests: XCTestCase {
    private func gameID(_ name: String) -> GameID { .init(source: "fixture", value: name) }
    private func volume(_ id: String) -> GamesVolume {
        .init(id: id, name: id, mountURL: URL(fileURLWithPath: "/Volumes/\(id)"), gamesRoot: URL(fileURLWithPath: "/Volumes/\(id)/games"),
              freeBytes: 1_000, totalBytes: 10_000)
    }
    /// (name, volume, bytes, days since last played)
    private func fixture(_ games: [(String, String, Int64, Int?)], offline: Set<String> = []) throws -> (LibraryModel, CleanupQueue) {
        let catalog = try CatalogStore()
        for (name, volume, bytes, days) in games {
            let game = SourceGameRecord(id: gameID(name), title: name,
                sourceLastPlayedAt: days.map { Date(timeIntervalSince1970: 1_800_000_000 - Double($0) * 86_400) })
            var installed = InstallationRecord(game: game,
                location: .init(volumeID: volume, lastKnownRoot: URL(fileURLWithPath: "/Volumes/\(volume)/games"), relativePath: "playden-fixture-\(name)/game"),
                bottleID: "playden-fixture-\(name)", manifestIDs: [:], templateVersion: "1", launchSpec: .init(executableRelativePath: "game.exe"), installedBytes: bytes)
            installed.plan = .init(game: game, manifestIDs: [:], estimate: .init(downloadBytes: bytes, installedBytes: bytes, requiredBytes: bytes), launchSpec: installed.launchSpec, sourcePayload: Data())
            try catalog.saveInstallation(installed)
        }
        let queue = CleanupQueue(catalog)
        let model = LibraryModel(catalog: catalog, preview: false, source: CleanupSource(), installQueue: queue,
                                 cloud: CleanupCloud(catalog, offline: Set(offline.map(gameID))))
        model.availableVolumes = [volume("external"), volume("internal"), volume("unused")]
        return (model, queue)
    }

    func testListsConnectedVolumesWithGamesSortedBySizeOrLastPlayed() throws {
        let (model, _) = try fixture([("Big", "external", 900, 1), ("Small", "external", 100, 30), ("Never", "external", 500, nil),
                                      ("Inside", "internal", 300, 2), ("Gone", "unplugged", 700, 5)])
        model.showStorageCleanup()
        XCTAssertEqual(model.panel, .storage)
        XCTAssertEqual(model.storageVolumes.map(\.id), ["external", "internal"], "unused and disconnected volumes are not listed")
        XCTAssertEqual(model.storageRows.map(\.title), ["Big", "Never", "Small"])
        XCTAssertEqual(model.storageBytes(on: "external"), 1_500)
        model.perform(.options)
        XCTAssertEqual(model.storageCleanup.sort, .lastPlayed)
        XCTAssertEqual(model.storageRows.map(\.title), ["Never", "Small", "Big"], "never played first, then oldest")
        model.perform(.nextTab)
        XCTAssertEqual(model.storageRows.map(\.title), ["Inside"])
    }

    func testControllerChecksGamesAndSwitchingVolumeClearsSelection() throws {
        let (model, _) = try fixture([("Big", "external", 900, 1), ("Small", "external", 100, 30), ("Inside", "internal", 300, 2)])
        model.showStorageCleanup()
        XCTAssertEqual(model.storageCleanup.focus, .game(0))
        model.perform(.confirm); model.perform(.move(.down)); model.perform(.confirm)
        XCTAssertEqual(model.storageSelectedBytes, 1_000)
        model.perform(.move(.down))
        XCTAssertEqual(model.storageCleanup.focus, .delete, "Delete is offered once games are checked")
        model.perform(.move(.left))
        XCTAssertEqual(model.storageCleanup.focus, .done)
        for _ in 0..<4 { model.perform(.move(.up)) }
        XCTAssertEqual(model.storageCleanup.focus, .volumes)
        model.perform(.move(.right))
        XCTAssertEqual(model.storageVolume?.id, "internal")
        XCTAssertTrue(model.storageCleanup.selection.isEmpty)
        model.perform(.back)
        XCTAssertNil(model.panel)
    }

    func testBatchRemovesSyncedGamesAndAsksAboutUnsyncedOnes() async throws {
        let (model, queue) = try fixture([("Big", "external", 900, 1), ("Offline", "external", 500, 3), ("Kept", "external", 100, 2)],
                                         offline: ["Offline"])
        model.showStorageCleanup()
        model.perform(.confirm); model.perform(.move(.down)); model.perform(.confirm)
        model.perform(.move(.down)); model.perform(.move(.down))
        XCTAssertEqual(model.storageCleanup.focus, .delete)
        model.perform(.confirm)
        XCTAssertTrue(model.storageCleanup.confirming)
        model.perform(.back)
        XCTAssertFalse(model.storageCleanup.confirming, "Back cancels the confirmation")
        let removedBefore = await queue.removed
        XCTAssertTrue(removedBefore.isEmpty)
        model.perform(.confirm); model.perform(.move(.right)); model.perform(.confirm)
        await model.storageCleanupTask?.value
        let removed = await queue.removed
        XCTAssertEqual(removed, [gameID("Big")], "only the game whose saves synced is removed without asking")
        XCTAssertEqual(model.tab, .downloads)
        await Task.yield(); await Task.yield()
        XCTAssertEqual(model.panel, .uninstall(gameID("Offline")))
        XCTAssertEqual(model.uninstallPhase, .unsynced)
        XCTAssertEqual(model.uninstallChoices(gameID("Offline")), [.cancel, .retry, .discard])
    }
}
