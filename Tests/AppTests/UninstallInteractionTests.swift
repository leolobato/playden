import XCTest
import Domain
import Catalog
import Installs
@testable import BigScreen

private struct RemovalAuth: SourceAuth {
    func identity() async throws -> SourceIdentity? { nil }
    func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func signIn(accountName: String, password: String, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String, onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func cancelSignIn() async {}
    func signOut() async throws {}
}
private struct RemovalSource: GameSource {
    let id = "fixture", displayName = "Fixture", auth: any SourceAuth = RemovalAuth()
    func ownedGames() async throws -> [SourceGameRecord] { [] }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
    func installer(for game: SourceGameRecord) throws -> any Installer { RemovalInstaller(gameID: game.id) }
}
private struct RemovalInstaller: Installer {
    let gameID: GameID
    func resolve() async throws -> InstallPlan { throw SourceFailure.unavailable }
    func download(_ plan: InstallPlan, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws { throw SourceFailure.unavailable }
    func verifyOriginals(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?) async throws -> VerificationResult { throw SourceFailure.unavailable }
    func postInstall(_ plan: InstallPlan, at directory: URL) async throws -> InstallStaging { throw SourceFailure.unavailable }
    func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging) async throws -> LaunchSpec { throw SourceFailure.unavailable }
    func uninstall(_ plan: InstallPlan, at directory: URL) async throws { throw SourceFailure.unavailable }
    func saveMapping(_ plan: InstallPlan) throws -> SaveMapping { .init(rules: [.init(root: .game, directory: "saves", pattern: "*", cloudPrefix: "saves")], coverage: .metadata) }
}
private actor RemovalQueue: InstallQueuing {
    let catalog: CatalogStore
    var authorizations: [UninstallAuthorization] = []
    init(_ catalog: CatalogStore) { self.catalog = catalog }
    func start() async throws {}
    func shutdown() async {}
    func updates() -> AsyncStream<InstallQueueSnapshot> { AsyncStream { $0.finish() } }
    func offer(for game: SourceGameRecord, volume: GamesVolumeSelection) async throws -> InstallOffer { throw SourceFailure.unavailable }
    func enqueue(_ offer: InstallOffer) async throws -> UUID { throw SourceFailure.unavailable }
    func repair(_ gameID: GameID) async throws -> UUID { throw SourceFailure.unavailable }
    func uninstall(_ authorization: UninstallAuthorization) async throws -> UUID {
        let job = try catalog.beginUninstall(authorization); authorizations.append(authorization); return job.id
    }
    func setPaused(_ paused: Bool, reason: PauseReason, jobID: UUID) async throws {}
    func retry(_ jobID: UUID) async throws {}
    func cancel(_ jobID: UUID) async throws {}
    func move(_ jobID: UUID, before otherID: UUID) async throws {}
    func setGameplayPaused(_ paused: Bool) async throws {}
}
private actor RemovalCloud: CloudSyncManaging {
    let catalog: CatalogStore
    let pending: Bool
    var held: Bool
    var entered = false
    init(_ catalog: CatalogStore, pending: Bool, held: Bool = false) { self.catalog = catalog; self.pending = pending; self.held = held }
    func updates() -> AsyncStream<[GameID: CloudSyncStatus]> { AsyncStream { $0.finish() } }
    func recoverInterruptedOperations() async throws {}
    func synchronize(_ installation: InstallationRecord, mapping: SaveMapping, preparingSessionID: UUID?, authorization: CloudSyncAuthorization?) async -> CloudSyncStatus {
        entered = true
        do {
            while held { try await Task.sleep(for: .milliseconds(10)) }
            let id = installation.gameID, account = "fixture"
            var operation = try catalog.beginCloudSync(installation: installation, accountKey: account, mapping: mapping)
            operation = try catalog.stageCloudSync(operation,
                plan: .init(gameID: id, installationID: installation.id, accountKey: account, remoteRevision: 1, decisions: [], requiresAccountConfirmation: false),
                remote: .init(gameID: id, accountKey: account, revision: 1, files: []), localSnapshotID: UUID(), remoteSnapshotID: UUID())
            if pending {
                operation = try catalog.pauseCloudSync(operation, phase: .pending)
                return .init(gameID: id, state: .pendingUpload, operation: operation, message: "Steam is offline")
            }
            operation = try catalog.markCloudVerifying(operation)
            operation = try catalog.completeCloudSync(operation, baseline: .init(gameID: id, installationID: installation.id, accountKey: account, revision: 1, mapping: mapping, files: []))
            return .init(gameID: id, state: .upToDate, operation: operation, message: "Up to date")
        } catch { return .init(gameID: installation.gameID, state: .failed, message: "Cancelled") }
    }
}

@MainActor final class UninstallInteractionTests: XCTestCase {
    private let id = GameID(source: "fixture", value: "game")
    private func fixture(pending: Bool = false, held: Bool = false) throws -> (LibraryModel, CatalogStore, RemovalQueue, RemovalCloud) {
        let catalog = try CatalogStore(), game = SourceGameRecord(id: id, title: "A Short Hike")
        var installed = InstallationRecord(game: game,
            location: .init(volumeID: "fixture", lastKnownRoot: URL(fileURLWithPath: "/fixture"), relativePath: "gn-fixture-game/game"),
            bottleID: "gn-fixture-game", manifestIDs: [:], templateVersion: "1", launchSpec: .init(executableRelativePath: "game.exe"), installedBytes: 100)
        installed.plan = .init(game: game, manifestIDs: [:], estimate: .init(downloadBytes: 100, installedBytes: 100, requiredBytes: 100), launchSpec: installed.launchSpec, sourcePayload: Data())
        try catalog.saveInstallation(installed)
        let queue = RemovalQueue(catalog), cloud = RemovalCloud(catalog, pending: pending, held: held)
        let model = LibraryModel(catalog: catalog, preview: false, source: RemovalSource(), installQueue: queue, cloud: cloud)
        model.openGame(try XCTUnwrap(model.games.first))
        return (model, catalog, queue, cloud)
    }
    func testOneConfirmationChecksCloudThenQueuesRemoval() async throws {
        let (model, catalog, queue, _) = try fixture()
        model.beginUninstall(id)
        XCTAssertEqual(model.panel, .uninstall(id)); XCTAssertEqual(model.panelIndex, 0)
        XCTAssertTrue(try catalog.jobs().isEmpty)
        model.perform(.move(.right)); model.perform(.confirm)
        await model.uninstallTask?.value
        let sent = await queue.authorizations
        XCTAssertEqual(sent.count, 1); XCTAssertEqual(sent.first?.discardUnsyncedProgress, false)
        XCTAssertEqual(model.tab, .downloads); XCTAssertNil(model.panel)
    }
    func testUnsyncedProgressNeedsSeparateDirectionalDiscardChoice() async throws {
        let (model, catalog, queue, _) = try fixture(pending: true)
        model.beginUninstall(id); model.perform(.move(.right)); model.perform(.confirm)
        await model.uninstallTask?.value
        XCTAssertEqual(model.uninstallPhase, .unsynced); XCTAssertEqual(model.panelIndex, 0)
        XCTAssertTrue(try catalog.jobs().isEmpty)
        let shown = try XCTUnwrap(model.uninstallReview)
        for _ in 0..<10 { model.perform(.move(.right)) }
        XCTAssertEqual(model.uninstallChoices(id)[model.panelIndex], .discard)
        model.perform(.confirm); await model.uninstallTask?.value
        let sent = await queue.authorizations
        XCTAssertEqual(sent.first?.review, shown); XCTAssertEqual(sent.first?.discardUnsyncedProgress, true)
    }
    func testChangedReviewFailsWithoutRefreshingDestructiveConsent() async throws {
        let (model, catalog, queue, _) = try fixture(pending: true)
        model.beginUninstall(id); model.activateUninstall(.remove, id: id); await model.uninstallTask?.value
        let saved = try XCTUnwrap(model.uninstallReview)
        var changed = saved.installation; changed.installedBytes += 1; try catalog.saveInstallation(changed)
        model.activateUninstall(.discard, id: id); await model.uninstallTask?.value
        XCTAssertEqual(model.uninstallPhase, .failed); XCTAssertNil(model.uninstallReview)
        let count = await queue.authorizations.count; XCTAssertEqual(count, 0)
        XCTAssertTrue(try catalog.jobs().isEmpty)
        XCTAssertFalse(model.uninstallChoices(id).contains(.discard))
    }
    func testBackCancelsCloudPreparationWithoutCreatingRemovalJob() async throws {
        let (model, catalog, queue, cloud) = try fixture(held: true)
        model.beginUninstall(id); model.activateUninstall(.remove, id: id)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await cloud.entered), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.uninstallBusy)
        model.perform(.back); await model.uninstallTask?.value
        XCTAssertNil(model.panel); XCTAssertFalse(model.uninstallBusy)
        let count = await queue.authorizations.count; XCTAssertEqual(count, 0)
        XCTAssertTrue(try catalog.jobs().isEmpty)
    }
    func testRemovalPresentationNeverOffersPlayOrDownloadCancellation() throws {
        let (model, _, _, _) = try fixture()
        var job = JobRecord(gameID: id, kind: .uninstall); job.stage = .removeBottle; job.state = .failed
        model.installJobs = [job]; model.applyInstallStatuses()
        XCTAssertEqual(model.detailActions.first, "View removal")
        XCTAssertFalse(model.detailActions.contains("Play")); XCTAssertFalse(model.detailActions.contains("Uninstall"))
        XCTAssertEqual(model.downloadActions(for: id), ["Retry", "Open game", "View logs"])
        XCTAssertEqual(job.statusTitle, "Removal needs attention")
        job.state = .completed; XCTAssertEqual(job.statusTitle, "Uninstalled")
    }
    func testReinstallCannotInheritPreviousInstallCloudStatus() throws {
        let (model, catalog, _, _) = try fixture()
        var installed = try XCTUnwrap(catalog.snapshot().entries.first?.installation)
        model.cloudStatuses[id] = .init(gameID: id, state: .upToDate, message: "Previously synced")
        try catalog.removeInstallation(id: installed.id); model.reloadCatalog()
        XCTAssertNil(model.cloudStatuses[id])
        installed.id = UUID(); installed.ownershipToken = UUID()
        try catalog.saveInstallation(installed); model.reloadCatalog()
        XCTAssertEqual(model.cloudLabel(id), "Not checked")
    }
}
