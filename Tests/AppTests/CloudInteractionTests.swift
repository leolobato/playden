import XCTest
import Domain
import Sessions
import Catalog
import Sources
import Synchronization
import Input
@testable import Playden

private actor CloudSessionFixture: SessionManaging {
    func retryCheckpoint(sessionID: UUID) async throws { throw SourceFailure.unavailable }
    var reviews: [CloudSyncAuthorization?] = []
    var offlineCount = 0, quitCount = 0
    func start(downloadWhilePlaying: Bool) async throws {}
    func updates() -> AsyncStream<SessionSnapshot> { AsyncStream { $0.finish() } }
    func play(_ gameID: GameID) async throws {}
    func retryCloud(authorization: CloudSyncAuthorization?) async throws { reviews.append(authorization) }
    func playOffline() async throws { offlineCount += 1 }
    func quit() async throws { quitCount += 1 }
    func setDownloadWhilePlaying(_ enabled: Bool) async throws {}
    func shutdown() async throws {}
}
private actor CloudUIFixture: CloudSyncManaging {
    func recoverInterruptedOperations() async throws {}
    func updates() -> AsyncStream<[GameID: CloudSyncStatus]> { AsyncStream { $0.finish() } }
    func synchronize(_ installation: InstallationRecord, mapping: SaveMapping, preparingSessionID: UUID?, authorization: CloudSyncAuthorization?) async -> CloudSyncStatus {
        .init(gameID: installation.gameID, state: .upToDate, message: "Up to date")
    }
}

@MainActor final class CloudInteractionTests: XCTestCase {
    private func model() -> (LibraryModel, CloudSessionFixture) {
        let sessions = CloudSessionFixture()
        let model = LibraryModel(sessions: sessions, cloud: CloudUIFixture())
        model.fixedClock = true; model.configureCloudSnapshot("cloud-conflict")
        return (model, sessions)
    }
    func testCloudActionAndConflictChoicesAreReachableWithDirectionalInput() throws {
        let (model, _) = model(), id = try XCTUnwrap(model.detailID)
        model.panel = nil
        model.detailAction = try XCTUnwrap(model.detailActions.firstIndex(of: "More"))
        model.perform(.confirm)
        model.panelIndex = try XCTUnwrap(model.contextActions.firstIndex(of: "Cloud saves"))
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .cloudSaves(id))
        XCTAssertEqual(model.cloudChoices(id)[model.panelIndex], .close)
        for _ in 0..<10 { model.perform(.move(.left)) }
        XCTAssertEqual(model.cloudChoices(id)[model.panelIndex], .local)
        model.perform(.move(.right))
        XCTAssertEqual(model.cloudChoices(id)[model.panelIndex], .remote)
        model.perform(.move(.down))
        XCTAssertEqual(model.cloudChoices(id)[model.panelIndex], .retry)
    }
    func testSelectedCopyUsesDisplayedReviewEvenIfNewStatusArrives() async throws {
        let (model, sessions) = model(), id = try XCTUnwrap(model.detailID)
        let displayed = try XCTUnwrap(model.cloudReview)
        var newer = displayed; newer.version += 1
        model.cloudStatuses[id] = .init(gameID: id, state: .conflict, operation: newer, message: "New review")
        model.panelIndex = try XCTUnwrap(model.cloudChoices(id).firstIndex(of: .remote))
        model.perform(.confirm)
        await model.sessionCommand?.value
        let sent = await sessions.reviews
        XCTAssertEqual(sent.count, 1); XCTAssertEqual(sent[0]?.operation, displayed)
        XCTAssertEqual(sent[0]?.conflictChoice, .remote); XCTAssertEqual(sent[0]?.attachAccount, true)
        XCTAssertNil(model.panel)
    }
    func testOfflineChoiceIsExplicitAndUnavailableDuringLocalRecovery() async throws {
        let (model, sessions) = model(), id = try XCTUnwrap(model.detailID)
        model.activateCloud(.offline, id: id); await model.sessionCommand?.value
        let count = await sessions.offlineCount; XCTAssertEqual(count, 1)
        let blocked = CloudSyncStatus(gameID: id, state: .failed, message: "Local recovery required", canPlayOffline: false)
        model.session.cloudStatus = blocked; model.cloudStatuses[id] = blocked; model.showCloud(id)
        XCTAssertFalse(model.cloudChoices(id).contains(.offline))
        model.activateCloud(.offline, id: id)
        let unchanged = await sessions.offlineCount; XCTAssertEqual(unchanged, 1)
    }
    func testLocalRecoveryChoicesUseExactReviewAndDoNotAttachSteamAccount() async throws {
        let (model, sessions) = model()
        model.configureCloudSnapshot("cloud-recovery")
        let id = try XCTUnwrap(model.detailID), review = try XCTUnwrap(model.cloudReview)
        XCTAssertEqual(model.cloudChoices(id), [.local, .remote, .retry, .close])
        XCTAssertEqual(model.cloudChoiceTitle(.local, id: id), "Keep current files")
        XCTAssertEqual(model.cloudChoiceTitle(.remote, id: id), "Restore recovered files")
        for _ in 0..<10 { model.perform(.move(.left)) }
        model.perform(.move(.right)); model.perform(.confirm)
        await model.sessionCommand?.value
        let sent = await sessions.reviews
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0]?.operation, review)
        XCTAssertEqual(sent[0]?.conflictChoice, .remote)
        XCTAssertEqual(sent[0]?.attachAccount, false)
        let offline = await sessions.offlineCount; XCTAssertEqual(offline, 0)
    }
    func testBackCancelsWaitingLaunchAndCannotLeaveAnInvisibleReservation() async throws {
        let (model, sessions) = model()
        model.perform(.back); await model.sessionCommand?.value
        XCTAssertNil(model.panel)
        let count = await sessions.quitCount; XCTAssertEqual(count, 1)
    }
    func testPendingArchiveReviewWorksWithoutAnOriginalSteamPlan() async throws {
        let (model, sessions) = model()
        model.configureCloudSnapshot("cloud-recovery")
        let id = try XCTUnwrap(model.detailID)
        var review = try XCTUnwrap(model.cloudReview)
        let original = try XCTUnwrap(review.plan)
        let localOnly = CloudSyncPlan(gameID: original.gameID, installationID: original.installationID,
            accountKey: original.accountKey, remoteRevision: 0, decisions: original.decisions.map {
                .init(name: $0.name, location: $0.location, action: .upload, local: $0.local, remote: nil)
            }, requiresAccountConfirmation: false)
        review.archiveRecoveryInput = .init(plan: localOnly, localSnapshotID: try XCTUnwrap(review.localSnapshotID), remoteSnapshotID: UUID())
        review.plan = nil; review.remote = nil; review.remoteSnapshotID = nil
        model.cloudStatuses[id] = .init(gameID: id, state: .conflict, operation: review, message: "Recover archived progress", canPlayOffline: false)
        model.session.cloudStatus = model.cloudStatuses[id]; model.showCloud(id)
        XCTAssertEqual(model.cloudChoices(id), [.local, .remote, .retry, .close])
        XCTAssertEqual(model.cloudChoiceTitle(.remote, id: id), "Restore recovered files")
        for _ in 0..<10 { model.perform(.move(.left)) }
        model.perform(.move(.right)); model.perform(.confirm)
        await model.sessionCommand?.value
        let sent = await sessions.reviews
        XCTAssertEqual(sent.count, 1); XCTAssertEqual(sent[0]?.operation, review)
        XCTAssertEqual(sent[0]?.conflictChoice, .remote); XCTAssertEqual(sent[0]?.attachAccount, false)
    }
    func testClosingBackgroundReviewKeepsDurableTransferAlive() async throws {
        let (model, _) = model(), id = try XCTUnwrap(model.detailID)
        model.session = .init()
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        model.cloudCommands[id] = task
        model.perform(.back)
        XCTAssertNil(model.panel); XCTAssertFalse(task.isCancelled)
        await model.stopCloudCommands()
        XCTAssertTrue(task.isCancelled); XCTAssertTrue(model.cloudCommands.isEmpty)
    }
    func testUnsupportedMappingIsHonestAndPostExitSyncReturnsToLauncherOnce() throws {
        let (model, _) = model(), id = try XCTUnwrap(model.detailID)
        model.session = .init(); model.cloudStatuses = [:]; model.cloudAvailability[id] = false
        XCTAssertEqual(model.cloudLabel(id), "Unavailable")
        XCTAssertEqual(model.cloudChoices(id), [.close])
        XCTAssertTrue(model.cloudMessage(id).contains("not supported"))
        var returns = 0; model.onGameEnded = { returns += 1 }
        model.configureCloudSnapshot("cloud-syncing")
        let syncing = model.session
        model.session = .init(phase: .running, game: syncing.game, session: syncing.session)
        model.receiveSession(syncing)
        model.perform(.back)
        XCTAssertEqual(model.panel, .cloudSaves(id)); XCTAssertFalse(model.exitOverlay)
        var ended = syncing; ended.phase = .idle; ended.session?.endedAt = .now; ended.session?.outcome = .clean
        model.receiveSession(ended)
        XCTAssertEqual(returns, 1)
    }
}

private final class CloudCapabilitySource: GameSource, Sendable {
    let id = "steam", displayName = "Fixture"
    let steam = SteamSource()
    let lookups = Mutex(0)
    var auth: any SourceAuth { steam.auth }
    func ownedGames() async throws -> [SourceGameRecord] { [] }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
    func installer(for game: SourceGameRecord) throws -> any Installer {
        lookups.withLock { $0 += 1 }
        return try steam.installer(for: game)
    }
}

extension CloudInteractionTests {
    func testCloudCapabilityCachesUnchangedPlansAndInvalidatesChangedOrRemovedPlans() throws {
        let catalog = try CatalogStore(), source = CloudCapabilitySource()
        let game = SourceGameRecord(id: .init(source: "steam", value: "100"), title: "Fixture")
        let planID = UUID()
        func plan(quota: Int) -> InstallPlan {
            .init(id: planID, game: game, manifestIDs: [:],
                estimate: .init(downloadBytes: 0, installedBytes: 0, requiredBytes: 0),
                launchSpec: .init(executableRelativePath: "game.exe"),
                sourcePayload: Data("{\"version\":1,\"app\":{\"appID\":100,\"ufs\":{\"quota\":\(quota),\"maxNumFiles\":0,\"saveFilePatterns\":[]}}}".utf8), launchOptions: [])
        }
        var installed = InstallationRecord(game: game,
            location: .init(volumeID: "disconnected", lastKnownRoot: URL(fileURLWithPath: "/fixture"), relativePath: "game"),
            bottleID: "fixture", manifestIDs: [:], templateVersion: "1",
            launchSpec: .init(executableRelativePath: "game.exe"), installedBytes: 0)
        installed.plan = plan(quota: 1)
        try catalog.saveInstallation(installed)
        let model = LibraryModel(catalog: catalog, preview: false, source: source, sessions: CloudSessionFixture(), cloud: CloudUIFixture())
        defer { model.stopServices() }
        XCTAssertEqual(model.cloudAvailability[game.id], true)
        let initial = source.lookups.withLock { $0 }
        for _ in 0..<10 { model.reloadCatalog() }
        XCTAssertEqual(source.lookups.withLock { $0 }, initial)
        installed.plan = plan(quota: 0) // Even a changed payload with the same plan ID invalidates the cache.
        try catalog.saveInstallation(installed)
        model.reloadCatalog()
        XCTAssertEqual(model.cloudAvailability[game.id], false)
        XCTAssertEqual(source.lookups.withLock { $0 }, initial + 1)
        try catalog.removeInstallation(id: installed.id)
        model.reloadCatalog()
        XCTAssertNil(model.cloudAvailability[game.id])
        XCTAssertNil(model.cloudAvailabilityCache[game.id])
    }
}
