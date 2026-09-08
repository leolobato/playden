import XCTest
import Domain
import Catalog
import Installs
@testable import BigScreen

private actor InteractionQueue: InstallQueuing {
    let result: InstallOffer
    var held = false
    var cancelledOffers = 0
    var enqueued: [InstallOffer] = []
    var commands: [String] = []
    var observer: AsyncStream<InstallQueueSnapshot>.Continuation?
    init(_ result: InstallOffer) { self.result = result }
    func start() async throws {}
    func shutdown() async {}
    func setGameplayPaused(_ paused: Bool) async throws {}
    func updates() -> AsyncStream<InstallQueueSnapshot> {
        AsyncStream { observer = $0; $0.yield(.init(jobs: [])) }
    }
    func publish(_ snapshot: InstallQueueSnapshot) { observer?.yield(snapshot) }
    func hold() { held = true }
    func offer(for game: SourceGameRecord, volume: GamesVolumeSelection) async throws -> InstallOffer {
        do { while held { try await Task.sleep(for: .milliseconds(10)) } }
        catch { cancelledOffers += 1; throw error }
        return result
    }
    func enqueue(_ offer: InstallOffer) async throws -> UUID { enqueued.append(offer); return UUID() }
    func uninstall(_ authorization: UninstallAuthorization) async throws -> UUID { throw SourceFailure.unavailable }
    func repair(_ gameID: GameID) async throws -> UUID { throw SourceFailure.unavailable }
    func setPaused(_ paused: Bool, reason: PauseReason, jobID: UUID) async throws { commands.append("\(paused ? "pause" : "resume"):\(reason.rawValue)") }
    func retry(_ jobID: UUID) async throws { commands.append("retry") }
    func cancel(_ jobID: UUID) async throws { commands.append("cancel") }
    func move(_ jobID: UUID, before otherID: UUID) async throws { commands.append("move") }
}
final class InstallInteractionTests: XCTestCase {
    private let id = GameID(source: "fixture", value: "game")
    private func offer(free: Int64 = 10_000) -> InstallOffer {
        let plan = InstallPlan(game: SourceGameRecord(id: id, title: "Fixture game"), manifestIDs: [:],
            estimate: .init(downloadBytes: 100, installedBytes: 200, requiredBytes: 500),
            launchSpec: .init(executableRelativePath: "game.exe"), sourcePayload: Data())
        return .init(plan: plan, volume: .init(volumeID: "fixture", rootBookmark: Data(), lastKnownRoot: URL(fileURLWithPath: "/fixture/games"), relativeRoot: "games"), freeBytes: free, reservedBytes: 0)
    }
    @MainActor private func model(_ queue: InteractionQueue, offer: InstallOffer) throws -> LibraryModel {
        let catalog = try CatalogStore()
        try catalog.replaceSourceCatalog(source: "fixture", games: [offer.plan.game])
        let model = LibraryModel(catalog: catalog, preview: false, installQueue: queue)
        model.gamesVolume = offer.volume
        return model
    }
    @MainActor private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The install interaction did not finish")
    }
    @MainActor func testInstallRequiresResolvedEstimateAndOneConfirmation() async throws {
        let offer = offer(), queue = InteractionQueue(offer)
        let model = try model(queue, offer: offer)
        model.openGame(model.games[0]); model.activateDetail()
        XCTAssertEqual(model.panel, .installOffer(id))
        try await eventually { !model.resolvingInstall }
        XCTAssertEqual(model.panelActions, ["Cancel", "Install"])
        let before = await queue.enqueued.count
        XCTAssertEqual(before, 0)
        model.perform(.move(.right)); model.perform(.confirm)
        try await eventually { model.tab == .downloads && model.panel == nil }
        let submitted = await queue.enqueued
        XCTAssertEqual(submitted.map(\.plan), [offer.plan])
        model.stopServices()
    }
    @MainActor func testLogRecoveryRetriesOnlyTheCurrentFailedJobAndPreservesCancellationIntent() async throws {
        let offer = offer(), queue = InteractionQueue(offer)
        let model = try model(queue, offer: offer)
        var failed = JobRecord(gameID: id); failed.state = .failed
        model.installJobs = [failed]
        model.logDocument = .init(id: failed.id, gameID: id, kind: "install", startedAt: .now)
        XCTAssertEqual(model.logRecovery, .job(failed.id, id, cancellation: false))
        model.logActionIndex = 1; model.activateLogAction()
        try await eventually { await queue.commands == ["retry"] }
        failed.cancellationRequested = true; model.installJobs = [failed]
        XCTAssertEqual(model.logActions, ["Close", "Retry cancellation"])
        model.activateLogAction()
        try await eventually { await queue.commands == ["retry", "cancel"] }
        var newer = JobRecord(gameID: id); newer.createdAt = failed.createdAt.addingTimeInterval(10)
        newer.state = .failed; model.installJobs = [failed, newer]
        XCTAssertNil(model.logRecovery)
        model.performLiveDownloadAction("Retry", id: id, expectedJobID: failed.id)
        let commands = await queue.commands; XCTAssertEqual(commands, ["retry", "cancel"])
        model.stopServices()
    }
    @MainActor func testInsufficientSpaceCannotEnqueue() async throws {
        let offer = offer(free: 499), queue = InteractionQueue(offer)
        let model = try model(queue, offer: offer)
        model.beginInstall(id)
        try await eventually { !model.resolvingInstall }
        XCTAssertEqual(model.panelActions, ["Cancel", "Check space again"])
        model.confirmInstall()
        let count = await queue.enqueued.count
        XCTAssertEqual(count, 0)
        model.stopServices()
    }
    @MainActor func testBackCancelsResolutionWithoutCreatingJob() async throws {
        let offer = offer(), queue = InteractionQueue(offer)
        await queue.hold()
        let model = try model(queue, offer: offer)
        model.beginInstall(id)
        try await Task.sleep(for: .milliseconds(30))
        model.perform(.back)
        try await eventually { await queue.cancelledOffers == 1 }
        XCTAssertNil(model.panel)
        let count = await queue.enqueued.count
        XCTAssertEqual(count, 0)
        model.stopServices()
    }
    @MainActor func testRealQueueNavigationCancelConfirmationAndProgress() async throws {
        let offer = offer(), queue = InteractionQueue(offer)
        let model = try model(queue, offer: offer)
        var active = JobRecord(gameID: id); active.plan = offer.plan; active.state = .running; active.stage = .download
        active.bytesCompleted = 75; active.bytesTotal = 200
        var second = JobRecord(gameID: GameID(source: "fixture", value: "second"), queuePosition: 1)
        second.state = .paused; second.pauseReasons = [.user, .gameplay]
        model.installJobs = [second, active]; model.activeInstallID = active.id; model.applyInstallStatuses()
        model.selectTab(.downloads)
        XCTAssertEqual(model.downloadGames.map(\.id), [id, second.gameID])
        XCTAssertEqual(model.liveJob(for: id)?.displayProgress, 0.375)
        model.perform(.confirm)
        XCTAssertEqual(model.panel, .downloadActions(id))
        model.perform(.move(.down)); model.perform(.confirm)
        XCTAssertEqual(model.panel, .confirmation(.cancelDownload(id)))
        let before = await queue.commands
        XCTAssertTrue(before.isEmpty)
        model.perform(.move(.right)); model.perform(.confirm)
        try await eventually { await queue.commands == ["cancel"] }
        model.perform(.move(.down)); model.perform(.confirm)
        XCTAssertEqual(model.panel, .downloadActions(second.gameID))
        model.perform(.confirm)
        try await eventually { await queue.commands == ["cancel", "resume:user"] }
        model.stopServices()
    }
    @MainActor func testLibraryRefreshPreservesInstallStatusAndPrimaryAction() throws {
        let offer = offer(), queue = InteractionQueue(offer)
        let model = try model(queue, offer: offer)
        var job = JobRecord(gameID: id); job.state = .failed; job.plan = offer.plan
        model.installJobs = [job]; model.reloadCatalog()
        XCTAssertEqual(model.games[0].status, .queued)
        model.openGame(model.games[0])
        XCTAssertEqual(model.detailActions.first, "View download")
        XCTAssertEqual(model.downloadActions(for: id).first, "Retry")
        XCTAssertEqual(job.statusTitle, "Installation failed")
    }
    @MainActor func testRepairHasClearProgressAndNonDestructiveStopConfirmation() throws {
        let offer = offer(), queue = InteractionQueue(offer)
        let model = try model(queue, offer: offer)
        var job = JobRecord(gameID: id, kind: .repair); job.plan = offer.plan; job.state = .running; job.stage = .download
        model.installJobs = [job]; model.activeInstallID = job.id; model.applyInstallStatuses()
        model.openGame(model.games[0])
        XCTAssertEqual(model.detailActions.first, "View verification")
        XCTAssertTrue(model.downloadActions(for: id).contains("Stop verifying…"))
        XCTAssertFalse(model.downloadActions(for: id).contains("Cancel download…"))
        XCTAssertEqual(model.confirmationAction(.cancelDownload(id)), "Stop verifying")
        XCTAssertTrue(model.confirmationMessage(.cancelDownload(id)).contains("files and saves are kept"))
        job.state = .cancelled; model.installJobs = [job]; model.gamesNeedingRepair = [id]
        XCTAssertEqual(model.detailActions.first, "Verify files")
        XCTAssertEqual(job.statusTitle, "Verification stopped")
        job.state = .completed
        XCTAssertEqual(job.statusTitle, "Files verified")
    }
}
