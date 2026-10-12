import XCTest
import Foundation
import Domain
@testable import Catalog
import GRDB
import Runner
@testable import Installs

private actor FixtureVolumes: VolumeManaging {
    let root: URL
    init(root: URL) { self.root = root }
    func availableVolumes() async throws -> [GamesVolume] { [] }
    func select(_ volume: GamesVolume) async throws -> GamesVolumeSelection { selection }
    func resolve(_ selection: GamesVolumeSelection) async throws -> URL { root }
    var selection: GamesVolumeSelection { .init(volumeID: "fixture-volume", rootBookmark: Data([1]), lastKnownRoot: root, relativeRoot: "games") }
}
private struct OfflineAuth: SourceAuth {
    func identity() async throws -> SourceIdentity? { nil }
    func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func signIn(accountName: String, password: String, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String, onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func cancelSignIn() async {}
    func signOut() async throws {}
}
private actor OfflineContent {
    var events: [String] = []
    var held = Set<String>()
    var failures = Set<String>()
    var verificationFixture = false
    var beforeRepairPreparation: (@Sendable () async -> Void)?
    func setRepairPreparationHook(_ hook: @escaping @Sendable () async -> Void) { beforeRepairPreparation = hook }
    var downloadReports: [String: @Sendable (InstallProgress) -> Void] = [:]
    func saveDownloadReport(_ id: String, report: @escaping @Sendable (InstallProgress) -> Void) { downloadReports[id] = report }
    func sendDownloadReport(_ id: String, value: InstallProgress) { downloadReports[id]?(value) }
    var stageVerificationFixture = false
    var verificationReports: [String: @Sendable (InstallFileVerification) -> Void] = [:]
    func enableStageVerificationFixture() { stageVerificationFixture = true }
    func saveReport(_ key: String, report: @escaping @Sendable (InstallFileVerification) -> Void) { verificationReports[key] = report }
    func sendLateReport(_ key: String) { verificationReports[key]?(.init(file: "old", bytesChecked: 7, bytesTotal: 8, scope: .installation)) }
    func enableVerificationFixture() { verificationFixture = true }
    func hold(_ id: String) { held.insert(id) }
    func release(_ id: String) { held.remove(id) }
    func failOnce(_ step: String) { failures.insert(step) }
    func record(_ event: String) throws {
        events.append(event)
        if failures.remove(event) != nil { throw OperationFailure(stage: "Fixture", reason: "Injected failure", output: "Fixture only") }
    }
    func wait(_ id: String) async throws {
        while held.contains(id) { try await Task.sleep(for: .milliseconds(10)) }
    }
}
private struct ExternalFixtureSource: GameSource {
    let id = "externalfixture", displayName = "This Mac"
    let auth: any SourceAuth = NoSourceAuth()
    var capabilities: SourceCapabilities { SourceCapabilities(account: .none, acquisition: .external) }
    func ownedGames() async throws -> [SourceGameRecord] { [] }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
    func installer(for game: SourceGameRecord) throws -> any Installer { XCTFail("External stores have no installer"); throw SourceFailure.unavailable }
}
/// A store with no sign-in, no numeric IDs, no depots and no Steam emulation. The same queue runs it.
private struct OfflineSource: GameSource {
    let id = "offlinefixture", displayName = "Offline files"
    let auth: any SourceAuth = OfflineAuth()
    let content: OfflineContent
    func ownedGames() async throws -> [SourceGameRecord] { [] }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
    func installer(for game: SourceGameRecord) throws -> any Installer { OfflineInstaller(game: game, content: content) }
}
private struct SteamSpaceSource: GameSource {
    let id = "steam", displayName = "Steam space fixture"
    let auth: any SourceAuth = OfflineAuth()
    let content: OfflineContent
    func ownedGames() async throws -> [SourceGameRecord] { [] }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
    func installer(for game: SourceGameRecord) throws -> any Installer { OfflineInstaller(game: game, content: content) }
}
private actor SpaceFixtureStorage: InstallStorageManaging {
    let base: InstallStorage
    var available: Int64 = 100000
    init(_ base: InstallStorage) { self.base = base }
    func setFree(_ value: Int64) { available = value }
    private var holdNext = false
    private var heldRead: CheckedContinuation<Int64, Never>?
    private var heldObservers: [CheckedContinuation<Void, Never>] = []
    func holdNextRead() { holdNext = true }
    func waitForHeldRead() async {
        if heldRead != nil { return }
        await withCheckedContinuation { heldObservers.append($0) }
    }
    func releaseHeldRead(_ free: Int64) { heldRead?.resume(returning: free); heldRead = nil }
    func freeBytes(on volume: GamesVolumeSelection) async throws -> Int64 {
        guard holdNext else { return available }
        holdNext = false
        return await withCheckedContinuation { continuation in
            heldRead = continuation
            heldObservers.forEach { $0.resume() }; heldObservers.removeAll()
        }
    }
    func prepare(gameID: GameID, owner: UUID, on volume: GamesVolumeSelection) async throws -> GameLocation { try await base.prepare(gameID: gameID, owner: owner, on: volume) }
    func directory(_ location: GameLocation, gameID: GameID, owner: UUID) async throws -> URL { try await base.directory(location, gameID: gameID, owner: owner) }
    func remove(_ location: GameLocation, gameID: GameID, owner: UUID) async throws { try await base.remove(location, gameID: gameID, owner: owner) }
}
private struct OfflineInstaller: Installer {
    let game: SourceGameRecord
    let content: OfflineContent
    var gameID: GameID { game.id }
    func resolve() async throws -> InstallPlan {
        try await content.record("resolve:" + gameID.value)
        return .init(game: game, manifestIDs: [:], estimate: .init(downloadBytes: 8, installedBytes: 8, requiredBytes: 1024),
            launchSpec: .init(executableRelativePath: "game.exe"), sourcePayload: Data("offline-content-v1".utf8))
    }
    func resolve(platform: GamePlatform) async throws -> InstallPlan {
        guard platform == .macOS else { return try await resolve() }
        try await content.record("resolve-mac:" + gameID.value)
        return .init(game: game, manifestIDs: [:], estimate: .init(downloadBytes: 8, installedBytes: 8, requiredBytes: 1024),
            launchSpec: .init(executableRelativePath: "Game.app"), sourcePayload: Data("offline-content-v1".utf8), platform: .macOS)
    }
    func download(_ plan: InstallPlan, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        try await content.record("download:" + gameID.value)
        await content.saveDownloadReport(gameID.value, report: progress)
        try Data("part".utf8).write(to: directory.appendingPathComponent("partial"))
        if await content.verificationFixture {
            progress(.init(bytesCompleted: 4, bytesTotal: 8, currentFile: "game.exe", downloadedBytes: 4,
                freshlyWrittenBytes: 4, verification: .init(file: "game.exe", bytesChecked: 2, bytesTotal: 4), sequence: 2))
            // Same assembled bytes, but an older event must not clear verification.
            progress(.init(bytesCompleted: 4, bytesTotal: 8, currentFile: "game.exe", downloadedBytes: 4,
                freshlyWrittenBytes: 4, sequence: 1))
        } else { progress(.init(bytesCompleted: 4, bytesTotal: 8, currentFile: "game.exe")) }
        try await content.wait(gameID.value)
        try Data("complete".utf8).write(to: directory.appendingPathComponent("game.exe"))
    }
    func repair(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?,
                reserve: @escaping @Sendable (Int64, Int64, InstallRepairReservationPhase) async throws -> Void,
                progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        guard let beforePreparation = await content.beforeRepairPreparation else {
            try await reserve(plan.estimate.requiredBytes, 0, .transfer)
            try await repair(plan, at: directory, staging: staging, progress: progress)
            return
        }
        try await reserve(1280, 0, .transfer)
        await content.saveDownloadReport(gameID.value, report: progress)
        await beforePreparation()
        try await reserve(256, 0, .preparation)
    }
    func verifyOriginals(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?) async throws -> VerificationResult {
        try await content.record("verify:" + gameID.value)
        return .init(invalidFiles: (try? Data(contentsOf: directory.appendingPathComponent("game.exe"))) == Data("complete".utf8) ? [] : ["game.exe"])
    }
    func verifyOriginals(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?,
                         progress: @escaping @Sendable (InstallFileVerification) -> Void) async throws -> VerificationResult {
        if await content.stageVerificationFixture {
            await content.saveReport("verify", report: progress)
            progress(.init(file: "game.exe", bytesChecked: 2, bytesTotal: 8, scope: .installation))
            try await content.wait("verify:" + gameID.value)
        }
        return try await verifyOriginals(plan, at: directory, staging: staging)
    }
    func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging,
                  progress: @escaping @Sendable (InstallFileVerification) -> Void) async throws -> LaunchSpec {
        if await content.stageVerificationFixture {
            progress(.init(file: "game.exe", bytesChecked: 4, bytesTotal: 8, scope: .installation))
            try await content.wait("validate:" + gameID.value)
        }
        return try await validate(plan, at: directory, staging: staging)
    }
    func postInstall(_ plan: InstallPlan, at directory: URL, in bottle: GameBottle,
                     progress: @escaping @Sendable (InstallPreparationProgress) -> Void) async throws -> InstallStaging {
        if await content.stageVerificationFixture {
            let check = InstallFileVerification(file: "game.exe", bytesChecked: 6, bytesTotal: 8, scope: .installation)
            progress(.init(step: .verifying(check), sequence: 1))
            try await content.wait("stage:" + gameID.value)
            progress(.init(step: .applyingSettings, sequence: 3))
            progress(.init(step: .verifying(check), sequence: 2)) // Out-of-order callback must not restore the old phase.
            try await content.wait("settings:" + gameID.value)
        }
        return try await postInstall(plan, at: directory)
    }
    func postInstall(_ plan: InstallPlan, at directory: URL) async throws -> InstallStaging {
        try await content.record("stage:" + gameID.value)
        try Data("offline-ready".utf8).write(to: directory.appendingPathComponent("offline.recipe"))
        return .init()
    }
    func preparePrerequisites(_ plan: InstallPlan, at directory: URL, in bottle: GameBottle) async throws {
        XCTAssertEqual(bottle.gameID, gameID)
        try await content.record("prerequisites:" + gameID.value)
    }
    func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging) async throws -> LaunchSpec {
        try await content.record("validate:" + gameID.value)
        guard try Data(contentsOf: directory.appendingPathComponent("offline.recipe")) == Data("offline-ready".utf8) else { throw SourceFailure.unavailable }
        return plan.launchSpec
    }
    func uninstall(_ plan: InstallPlan, at directory: URL) async throws { try await content.record("cleanup:" + gameID.value) }
}
private actor FixtureBottles: GameBottleManaging {
    var ready: [String: GameBottle] = [:]
    var removalBlocked = false, failRemoval = false, holdRemoval = false
    var removals = 0
    var preparations = 0, acknowledgments = 0
    var failAcknowledgment = false
    func failAcknowledgmentOnce() { failAcknowledgment = true }
    func setRemoval(blocked: Bool = false, fail: Bool = false, held: Bool = false) { removalBlocked = blocked; failRemoval = fail; holdRemoval = held }
    func checkRemoval(_ bottle: GameBottle, previousRuntime: RunSnapshot?) async throws {
        if removalBlocked { throw OperationFailure(stage: "Game runtime", reason: "A game is still running", output: "") }
    }
    func verifyRemoved(_ bottle: GameBottle) async throws {
        if ready[bottle.name] != nil { throw SourceFailure.unavailable }
    }
    func prepare(_ bottle: GameBottle) async throws { preparations += 1; ready[bottle.name] = bottle }
    func completeSourcePreparation(_ bottle: GameBottle) async throws {
        guard ready[bottle.name] == bottle else { throw SourceFailure.unavailable }
        acknowledgments += 1
        if failAcknowledgment { failAcknowledgment = false; throw OperationFailure(stage: "Game runtime", reason: "Retry preparation acknowledgment", output: "fixture") }
    }
    func isReady(_ bottle: GameBottle) async throws -> Bool { ready[bottle.name] == bottle }
    func remove(_ bottle: GameBottle) async throws {
        removals += 1
        while holdRemoval { try await Task.sleep(for: .milliseconds(10)) }
        if failRemoval { failRemoval = false; throw OperationFailure(stage: "Game runtime", reason: "Retry removal", output: "") }
        if ready[bottle.name] == bottle { ready[bottle.name] = nil }
    }
}
final class InstallQueueTests: XCTestCase {
    func testSteamLiveReservationChangesOnlyWithAllocationAndRepairsGateSpace() async throws {
        let root = try root(), volumes = FixtureVolumes(root: root), content = OfflineContent()
        let storage = SpaceFixtureStorage(InstallStorage(volumes: volumes)), catalog = try CatalogStore(path: root.appendingPathComponent("catalog.sqlite").path)
        let queue = try InstallQueue(catalog: catalog, sources: [SteamSpaceSource(content: content)], storage: storage, bottles: FixtureBottles())
        let game = SourceGameRecord(id: .init(source: "steam", value: "space"), title: "Space")
        await content.hold("space")
        let id = try await queue.enqueue(queue.offer(for: game, volume: volumes.selection))
        try await queue.start()
        _ = try await waitForSnapshot(queue) { $0.activeJobID == id && $0.jobs.first?.currentFile != nil }
        await content.sendDownloadReport("space", value: .init(bytesCompleted: 4, bytesTotal: 8, currentFile: "game.exe", allocatedBytes: 2))
        _ = try await waitForSnapshot(queue) { $0.jobs.first?.remainingReservationBytes == 1022 }
        let offer = try await queue.offer(for: .init(id: .init(source: "steam", value: "next"), title: "Next"), volume: volumes.selection)
        XCTAssertEqual(offer.reservedBytes, 1022)
        try await Task.sleep(for: .milliseconds(300))
        await content.sendDownloadReport("space", value: .init(bytesCompleted: 4, bytesTotal: 8, currentFile: "game.exe", downloadedBytes: 99, freshlyWrittenBytes: 99))
        try await Task.sleep(for: .milliseconds(300))
        let current = await queue.snapshot(); XCTAssertEqual(current.jobs.first?.remainingReservationBytes, 1022)
        await content.sendDownloadReport("space", value: .init(bytesCompleted: 4, bytesTotal: 8, currentFile: "game.exe", allocatedBytes: 4))
        _ = try await waitForSnapshot(queue) { $0.jobs.first?.remainingReservationBytes == 1020 }
        await content.release("space")
        _ = try await waitFor(queue, jobID: id, state: .completed)
        await storage.setFree(0)
        let repair = try await queue.repair(game.id)
        let paused = try await waitFor(queue, jobID: repair, state: .paused)
        XCTAssertTrue(paused.pauseReasons.contains(.insufficientSpace))
        XCTAssertEqual(paused.spaceReservationVersion, 2)
        let decoded = try JSONDecoder().decode(JobRecord.self, from: JSONEncoder().encode(paused))
        XCTAssertEqual(decoded.spaceReservationVersion, 2)
        let events = await content.events; XCTAssertEqual(events.filter { $0 == "download:space" }.count, 1)
        await queue.shutdown()
    }
    func testSteamRepairLateAllocationPreservesPreparationCapacityGate() async throws {
        try await repairPreparationReservation(freeAfterTransfer: 255)
    }
    func testSteamRepairLateAllocationPreservesPreparationAfterRelayDrain() async throws {
        try await repairPreparationReservation(freeAfterTransfer: 256)
    }
    private func repairPreparationReservation(freeAfterTransfer: Int64) async throws {
        let root = try root(), volumes = FixtureVolumes(root: root), content = OfflineContent()
        let storage = SpaceFixtureStorage(InstallStorage(volumes: volumes))
        let catalog = try CatalogStore(path: root.appendingPathComponent("repair-space.sqlite").path)
        let queue = try InstallQueue(catalog: catalog, sources: [SteamSpaceSource(content: content)], storage: storage, bottles: FixtureBottles())
        let game = SourceGameRecord(id: .init(source: "steam", value: "repair-space"), title: "Repair space")
        let install = try await queue.enqueue(queue.offer(for: game, volume: volumes.selection))
        try await queue.start()
        _ = try await waitFor(queue, jobID: install, state: .completed)
        await content.enableStageVerificationFixture()
        await content.hold("stage:" + game.id.value)
        await content.setRepairPreparationHook { await storage.holdNextRead() }
        let repair = try await queue.repair(game.id)
        await storage.waitForHeldRead()
        // Deliver the final transfer report while the preparation-only gate awaits capacity.
        // Its allocation exceeds preparation, so applying the old credit would erase the budget.
        await content.sendDownloadReport(game.id.value, value: .init(bytesCompleted: 8, bytesTotal: 8,
            currentFile: "late-final", allocatedBytes: 1024))
        let duringGate = try await waitForSnapshot(queue) { $0.jobs.first { $0.id == repair }?.currentFile == "late-final" }
        XCTAssertEqual(duringGate.jobs.first { $0.id == repair }?.remainingReservationBytes, 256)
        let offer = try await queue.offer(for: .init(id: .init(source: "steam", value: "next"), title: "Next"), volume: volumes.selection)
        XCTAssertEqual(offer.reservedBytes, 256)
        await storage.releaseHeldRead(freeAfterTransfer)
        let settled = try await waitForSnapshot(queue) {
            guard let job = $0.jobs.first(where: { $0.id == repair }) else { return false }
            return job.state == .paused || job.stage == .stage
        }
        let job = try XCTUnwrap(settled.jobs.first { $0.id == repair })
        XCTAssertEqual(job.remainingReservationBytes, 256)
        if freeAfterTransfer < 256 {
            XCTAssertEqual(job.state, .paused)
            XCTAssertTrue(job.pauseReasons.contains(.insufficientSpace))
            XCTAssertFalse(job.completedStages.contains(.download))
        } else {
            XCTAssertEqual(job.stage, .stage)
            XCTAssertTrue(job.completedStages.contains(.download))
        }
        await content.release("stage:" + game.id.value)
        await queue.shutdown()
    }
    func testRestartedPausedSteamJobDiscardsSavedAllocationAndTransferCredit() async throws {
        let root = try root(), volumes = FixtureVolumes(root: root), catalog = try CatalogStore(path: root.appendingPathComponent("restart.sqlite").path)
        let content = OfflineContent(), game = SourceGameRecord(id: .init(source: "steam", value: "paused"), title: "Paused")
        var job = JobRecord(gameID: game.id)
        job.plan = try await OfflineInstaller(game: game, content: content).resolve()
        job.volume = await volumes.selection; job.state = .paused; job.pauseReasons = [.user]
        job.bytesCompleted = 8; job.remainingReservationBytes = 0
        try catalog.saveJob(job)
        let queue = try InstallQueue(catalog: catalog, sources: [SteamSpaceSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        try await queue.start()
        let snapshot = await queue.snapshot()
        XCTAssertEqual(InstallReservations.bytes(snapshot.jobs, on: "fixture-volume"), 1024)
        XCTAssertNil(snapshot.jobs.first?.remainingReservationBytes)
        let offer = try await queue.offer(for: .init(id: .init(source: "steam", value: "next"), title: "Next"), volume: volumes.selection)
        XCTAssertEqual(offer.reservedBytes, 1024)
        await queue.shutdown()
    }
    private func rejectJobWrites(_ catalog: CatalogStore, when condition: String) throws {
        try catalog.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_job_save BEFORE UPDATE ON jobs
                WHEN \(condition)
                BEGIN SELECT RAISE(ABORT, 'Injected checkpoint failure'); END
                """)
        }
    }
    private func waitForSnapshot(_ queue: InstallQueue, matching predicate: (InstallQueueSnapshot) -> Bool) async throws -> InstallQueueSnapshot {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let snapshot = await queue.snapshot()
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected queue snapshot was not published")
        throw SourceFailure.unavailable
    }
    func testDownloadProgressSaveFailureIsAdvisoryAndRetries() async throws {
        try await advisoryProgressSaveFailure(verification: nil)
    }
    func testDownloadVerificationProgressSaveFailureIsAdvisoryAndRetries() async throws {
        try await advisoryProgressSaveFailure(verification: .init(file: "game.exe", bytesChecked: 2, bytesTotal: 8))
    }
    private func advisoryProgressSaveFailure(verification: InstallFileVerification?) async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        await content.hold("advisory")
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        addTeardownBlock { await queue.shutdown() }
        let id = try await queue.enqueue(queue.offer(for: game("advisory"), volume: volumes.selection))
        let next = try await queue.enqueue(queue.offer(for: game("next"), volume: volumes.selection))
        try rejectJobWrites(catalog, when: "json_extract(CAST(NEW.payload AS TEXT), '$.bytesCompleted') = 4")
        try await queue.start()
        // The first callback tries to save four bytes, which the database rejects.
        let snapshot = try await waitForSnapshot(queue) { $0.persistenceFailure != nil || $0.jobs.first(where: { $0.id == id })?.bytesCompleted == 4 }
        XCTAssertNil(snapshot.persistenceFailure)
        XCTAssertEqual(snapshot.activeJobID, id)
        XCTAssertEqual(snapshot.jobs.first(where: { $0.id == id })?.state, .running)
        XCTAssertEqual(snapshot.jobs.first(where: { $0.id == id })?.bytesCompleted, 4)
        XCTAssertEqual(try catalog.jobs().first(where: { $0.id == id })?.bytesCompleted, 0)
        try await catalog.database.write { try $0.execute(sql: "DROP TRIGGER reject_job_save") }
        await content.sendDownloadReport("advisory", value: .init(bytesCompleted: 6, bytesTotal: 8, currentFile: "next.exe", verification: verification, sequence: 10))
        if verification == nil { // Let the ordinary UI cadence elapse before sending a subsequent update.
            try await Task.sleep(for: .milliseconds(300))
            await content.sendDownloadReport("advisory", value: .init(bytesCompleted: 6, bytesTotal: 8, currentFile: "next.exe", sequence: 11))
        }
        _ = try await waitForSnapshot(queue) { $0.jobs.first(where: { $0.id == id })?.bytesCompleted == 6 }
        XCTAssertEqual(try catalog.jobs().first(where: { $0.id == id })?.bytesCompleted, 6)
        await content.release("advisory")
        _ = try await waitFor(queue, jobID: id, state: .completed)
        _ = try await waitFor(queue, jobID: next, state: .completed)
        await queue.shutdown()
    }
    func testStageCheckpointSaveFailureHaltsQueueWhenTerminalSaveSucceeds() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        addTeardownBlock { await queue.shutdown() }
        let id = try await queue.enqueue(queue.offer(for: game("checkpoint"), volume: volumes.selection))
        let next = try await queue.enqueue(queue.offer(for: game("next"), volume: volumes.selection))
        try rejectJobWrites(catalog, when: "json_extract(CAST(NEW.payload AS TEXT), '$.bytesCompleted') = 8 AND json_extract(CAST(NEW.payload AS TEXT), '$.state') = 'running'")
        try await queue.start()
        _ = try await waitFor(queue, jobID: id, state: .failed)
        let snapshot = await queue.snapshot()
        XCTAssertNotNil(snapshot.persistenceFailure)
        XCTAssertEqual(snapshot.jobs.first(where: { $0.id == next })?.state, .queued)
        XCTAssertEqual(try catalog.jobs().first(where: { $0.id == id })?.state, .failed, "The terminal save succeeds but must not clear the checkpoint failure")
        XCTAssertNil(try catalog.snapshot().entries.first?.installation)
        await queue.shutdown()
    }
    func testCommitSaveFailureHaltsQueueAndDoesNotPublishInstallation() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        addTeardownBlock { await queue.shutdown() }
        let id = try await queue.enqueue(queue.offer(for: game("commit"), volume: volumes.selection))
        let next = try await queue.enqueue(queue.offer(for: game("next"), volume: volumes.selection))
        try await catalog.database.write { try $0.execute(sql: "CREATE TRIGGER reject_commit BEFORE INSERT ON installations BEGIN SELECT RAISE(ABORT, 'Injected commit failure'); END") }
        try await queue.start()
        _ = try await waitFor(queue, jobID: id, state: .failed)
        let snapshot = await queue.snapshot()
        XCTAssertNotNil(snapshot.persistenceFailure)
        XCTAssertEqual(snapshot.jobs.first(where: { $0.id == next })?.state, .queued)
        XCTAssertTrue(try catalog.snapshot().entries.isEmpty)
        await queue.shutdown()
    }
    func testTerminalErrorSaveFailureHaltsQueueAtLastDurableCheckpoint() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        addTeardownBlock { await queue.shutdown() }
        let id = try await queue.enqueue(queue.offer(for: game("terminal"), volume: volumes.selection))
        let next = try await queue.enqueue(queue.offer(for: game("next"), volume: volumes.selection))
        await content.failOnce("verify:terminal")
        try rejectJobWrites(catalog, when: "json_extract(CAST(NEW.payload AS TEXT), '$.state') = 'failed'")
        try await queue.start()
        let snapshot = try await waitForSnapshot(queue) { $0.persistenceFailure != nil && $0.activeJobID == nil }
        XCTAssertEqual(snapshot.jobs.first(where: { $0.id == next })?.state, .queued)
        let durable = try XCTUnwrap(catalog.jobs().first(where: { $0.id == id }))
        XCTAssertEqual(durable.stage, .verifyOriginals)
        XCTAssertEqual(durable.state, .running)
        XCTAssertTrue(durable.completedStages.contains(.download))
        await queue.shutdown()
    }

    func testTerminalPauseSaveFailureHaltsQueueAtStoppingCheckpoint() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        await content.hold("pause")
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        addTeardownBlock { await queue.shutdown() }
        let id = try await queue.enqueue(queue.offer(for: game("pause"), volume: volumes.selection))
        let next = try await queue.enqueue(queue.offer(for: game("next"), volume: volumes.selection))
        try await queue.start()
        _ = try await waitForSnapshot(queue) { $0.jobs.first(where: { $0.id == id })?.bytesCompleted == 4 }
        try rejectJobWrites(catalog, when: "json_extract(CAST(NEW.payload AS TEXT), '$.state') = 'paused'")
        try await queue.setPaused(true, jobID: id)
        let snapshot = try await waitForSnapshot(queue) { $0.persistenceFailure != nil && $0.activeJobID == nil }
        XCTAssertEqual(snapshot.jobs.first(where: { $0.id == next })?.state, .queued)
        let durable = try XCTUnwrap(catalog.jobs().first(where: { $0.id == id }))
        XCTAssertEqual(durable.state, .stopping)
        XCTAssertEqual(durable.pauseReasons, [.user])
        await queue.shutdown()
    }
    func testTerminalCancelSaveFailureHaltsQueueAfterCleanup() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        await content.hold("cancel-save")
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        addTeardownBlock { await queue.shutdown() }
        let id = try await queue.enqueue(queue.offer(for: game("cancel-save"), volume: volumes.selection))
        let next = try await queue.enqueue(queue.offer(for: game("next"), volume: volumes.selection))
        try await queue.start()
        _ = try await waitForSnapshot(queue) { $0.jobs.first(where: { $0.id == id })?.bytesCompleted == 4 }
        try rejectJobWrites(catalog, when: "json_extract(CAST(NEW.payload AS TEXT), '$.state') = 'cancelled'")
        try await queue.cancel(id)
        let snapshot = try await waitForSnapshot(queue) { $0.persistenceFailure != nil && $0.activeJobID == nil }
        XCTAssertEqual(snapshot.jobs.first(where: { $0.id == next })?.state, .queued)
        let durable = try XCTUnwrap(catalog.jobs().first(where: { $0.id == id }))
        XCTAssertEqual(durable.cancellationRequested, true)
        XCTAssertNotEqual(durable.state, .cancelled, "Cleanup must not be acknowledged until the terminal save succeeds")
        await queue.shutdown()
    }
    func testStageVerificationContinuesWhenCatalogWritesAreUnavailable() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        await content.enableStageVerificationFixture(); await content.hold("verify:ephemeral")
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        addTeardownBlock { await queue.shutdown() }
        let id = try await queue.enqueue(queue.offer(for: game("ephemeral"), volume: volumes.selection))
        try await queue.start()
        _ = try await waitForSnapshot(queue) { $0.transfer?.verification?.bytesChecked == 2 && $0.jobs.first?.stage == .verifyOriginals }
        try rejectJobWrites(catalog, when: "1")
        await content.sendLateReport("verify")
        let snapshot = try await waitForSnapshot(queue) { $0.transfer?.verification?.bytesChecked == 7 }
        XCTAssertNil(snapshot.persistenceFailure)
        XCTAssertEqual(snapshot.activeJobID, id)
        XCTAssertEqual(snapshot.jobs.first?.state, .running)
        XCTAssertEqual(snapshot.jobs.first?.bytesCompleted, 8)
        try await catalog.database.write { try $0.execute(sql: "DROP TRIGGER reject_job_save") }
        await content.release("verify:ephemeral")
        _ = try await waitFor(queue, jobID: id, state: .completed)
        await queue.shutdown()
    }

    func testUninstallCommitSaveFailureHaltsQueueAndKeepsReservation() async throws {
        let (queue, catalog, _, bottles, volumes, game) = try await installedFixture()
        addTeardownBlock { await queue.shutdown() }
        await bottles.setRemoval(held: true)
        try await catalog.database.write { try $0.execute(sql: "CREATE TRIGGER reject_removal_commit BEFORE DELETE ON installations BEGIN SELECT RAISE(ABORT, 'Injected removal commit failure'); END") }
        let id = try await queue.uninstall(.init(review: catalog.reviewUninstall(game.id), discardUnsyncedProgress: true))
        _ = try await waitForSnapshot(queue) { $0.jobs.first(where: { $0.id == id })?.stage == .removeBottle }
        let next = try await queue.enqueue(queue.offer(for: self.game("next"), volume: volumes.selection))
        await bottles.setRemoval()
        _ = try await waitFor(queue, jobID: id, state: .failed)
        let snapshot = await queue.snapshot()
        XCTAssertNotNil(snapshot.persistenceFailure)
        XCTAssertEqual(snapshot.jobs.first(where: { $0.id == next })?.state, .queued)
        XCTAssertNotNil(try catalog.snapshot().entries.first(where: { $0.id == game.id })?.installation)
        let durable = try XCTUnwrap(catalog.jobs().first(where: { $0.id == id }))
        XCTAssertEqual(durable.state, .failed)
        XCTAssertEqual(durable.completedStages, [.removeFiles, .removeBottle])
        XCTAssertThrowsError(try catalog.saveSession(.init(gameID: game.id, bottleID: CrossOverGameBottles.name(for: game.id))))
        await queue.shutdown()
    }

    private func installedFixture() async throws -> (InstallQueue, CatalogStore, InstallStorage, FixtureBottles, FixtureVolumes, SourceGameRecord) {
        let root = try root(), catalog = try CatalogStore(), volumes = FixtureVolumes(root: root)
        let storage = InstallStorage(volumes: volumes), bottles = FixtureBottles(), content = OfflineContent(), game = game("remove")
        try catalog.replaceSourceCatalog(source: game.id.source, games: [game])
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: storage, bottles: bottles)
        let job = try await queue.enqueue(queue.offer(for: game, volume: volumes.selection))
        try await queue.start(); _ = try await waitFor(queue, jobID: job, state: .completed)
        return (queue, catalog, storage, bottles, volumes, game)
    }
    func testUninstallRemovesOwnedFilesAndBottleThenAllowsFreshInstall() async throws {
        let (queue, catalog, storage, bottles, volumes, game) = try await installedFixture()
        let original = try XCTUnwrap(catalog.snapshot().entries.first?.installation)
        try catalog.saveEdits(.init(isFavorite: true), for: game.id)
        let id = try await queue.uninstall(.init(review: catalog.reviewUninstall(game.id), discardUnsyncedProgress: true))
        let removed = try await waitFor(queue, jobID: id, state: .completed)
        XCTAssertEqual(removed.kind, .uninstall); XCTAssertEqual(removed.stage, .finished)
        try await storage.verifyRemoved(original.location, gameID: game.id, owner: original.ownershipToken)
        try await bottles.verifyRemoved(try XCTUnwrap(removed.bottle))
        XCTAssertNil(try catalog.snapshot().entries.first?.installation)
        XCTAssertEqual(try catalog.snapshot().entries.first?.edits.isFavorite, true)
        let reinstall = try await queue.enqueue(queue.offer(for: game, volume: volumes.selection))
        _ = try await waitFor(queue, jobID: reinstall, state: .completed)
        let fresh = try XCTUnwrap(catalog.snapshot().entries.first?.installation)
        XCTAssertNotEqual(fresh.id, original.id); XCTAssertNotEqual(fresh.ownershipToken, original.ownershipToken)
        await queue.shutdown()
    }
    func testFailedBottleRemovalRetriesAfterRestartWithoutAStoreConnection() async throws {
        let (queue, catalog, storage, bottles, _, game) = try await installedFixture()
        let original = try XCTUnwrap(catalog.snapshot().entries.first?.installation)
        await bottles.setRemoval(fail: true)
        let id = try await queue.uninstall(.init(review: catalog.reviewUninstall(game.id), discardUnsyncedProgress: true))
        let failed = try await waitFor(queue, jobID: id, state: .failed)
        XCTAssertEqual(failed.completedStages, [.removeFiles]); XCTAssertEqual(failed.stage, .removeBottle)
        XCTAssertEqual(try catalog.snapshot().entries.first?.installation, original)
        do { try await queue.cancel(id); XCTFail("Confirmed removal cannot be cancelled halfway") } catch {}
        do { try await queue.setPaused(true, jobID: id); XCTFail("Removal should use retry controls") } catch {}
        await queue.shutdown()
        let reopened = try InstallQueue(catalog: catalog, sources: [], storage: storage, bottles: bottles)
        try await reopened.start(); try await reopened.retry(id)
        _ = try await waitFor(reopened, jobID: id, state: .completed)
        XCTAssertNil(try catalog.snapshot().entries.first?.installation)
        await reopened.shutdown()
    }
    func testRunningWriterPreventsAnyRemoval() async throws {
        let (queue, catalog, storage, bottles, _, game) = try await installedFixture()
        let original = try XCTUnwrap(catalog.snapshot().entries.first?.installation)
        await bottles.setRemoval(blocked: true)
        let id = try await queue.uninstall(.init(review: catalog.reviewUninstall(game.id), discardUnsyncedProgress: true))
        _ = try await waitFor(queue, jobID: id, state: .failed)
        _ = try await storage.directory(original.location, gameID: game.id, owner: original.ownershipToken)
        let calls = await bottles.removals; XCTAssertEqual(calls, 0)
        await bottles.setRemoval(); try await queue.retry(id)
        _ = try await waitFor(queue, jobID: id, state: .completed)
        await queue.shutdown()
    }
    func testShutdownDuringRemovalKeepsReservationAndRestartResumes() async throws {
        let (queue, catalog, storage, bottles, _, game) = try await installedFixture()
        await bottles.setRemoval(held: true)
        let id = try await queue.uninstall(.init(review: catalog.reviewUninstall(game.id), discardUnsyncedProgress: true))
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while await bottles.removals == 0, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(10)) }
        let calls = await bottles.removals; XCTAssertEqual(calls, 1)
        await queue.shutdown()
        let paused = try XCTUnwrap(catalog.jobs().first(where: { $0.id == id }))
        XCTAssertEqual(paused.state, .queued); XCTAssertEqual(paused.completedStages, [.removeFiles])
        XCTAssertThrowsError(try catalog.saveSession(.init(gameID: game.id, bottleID: CrossOverGameBottles.name(for: game.id))))
        await bottles.setRemoval()
        let reopened = try InstallQueue(catalog: catalog, sources: [], storage: storage, bottles: bottles)
        try await reopened.start(); _ = try await waitFor(reopened, jobID: id, state: .completed)
        await reopened.shutdown()
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Playden-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func game(_ id: String) -> SourceGameRecord { .init(id: GameID(source: "offlinefixture", value: id), title: id) }
    private func waitFor(_ queue: InstallQueue, jobID: UUID, state: JobState, file: StaticString = #filePath, line: UInt = #line) async throws -> JobRecord {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < limit {
            if let value = await queue.snapshot().jobs.first(where: { $0.id == jobID && $0.state == state }) { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        let value = await queue.snapshot().jobs.first { $0.id == jobID }
        // A completion can arrive while the polling task is suspended at its deadline.
        if let value, value.state == state { return value }
        XCTFail("Expected \(state), got \(String(describing: value?.state)); \(value?.failure?.reason ?? "")", file: file, line: line)
        throw SourceFailure.unavailable
    }
    func testMacBuildsInstallAndUninstallWithoutABottle() async throws {
        let root = try root(), catalog = try CatalogStore(), volumes = FixtureVolumes(root: root)
        let storage = InstallStorage(volumes: volumes), bottles = FixtureBottles(), game = game("mac")
        try catalog.replaceSourceCatalog(source: game.id.source, games: [game])
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: OfflineContent())], storage: storage, bottles: bottles)
        let offer = try await queue.offer(for: game, volume: volumes.selection, platform: .macOS)
        XCTAssertEqual(offer.plan.resolvedPlatform, .macOS)
        let job = try await queue.enqueue(offer)
        try await queue.start(); _ = try await waitFor(queue, jobID: job, state: .completed)
        let installed = try XCTUnwrap(catalog.snapshot().entries.first?.installation)
        XCTAssertEqual(installed.runtimeBinding, .native); XCTAssertFalse(installed.isExternal)
        let prepared = await bottles.preparations, acknowledged = await bottles.acknowledgments
        XCTAssertEqual(prepared, 0, "A Mac build never creates a bottle"); XCTAssertEqual(acknowledged, 0)
        let removal = try await queue.uninstall(.init(review: catalog.reviewUninstall(game.id), discardUnsyncedProgress: true))
        _ = try await waitFor(queue, jobID: removal, state: .completed)
        try await storage.verifyRemoved(installed.location, gameID: game.id, owner: installed.ownershipToken)
        XCTAssertNil(try catalog.snapshot().entries.first?.installation)
        let removals = await bottles.removals
        XCTAssertEqual(removals, 0, "There is no bottle to remove")
        await queue.shutdown()
    }
    func testStoresWithGamesAlreadyOnDiskNeverInstall() async throws {
        let root = try root(), catalog = try CatalogStore(), volumes = FixtureVolumes(root: root)
        let queue = try InstallQueue(catalog: catalog, sources: [ExternalFixtureSource()], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        let record = SourceGameRecord(id: GameID(source: "externalfixture", value: "app"), title: "App")
        do { _ = try await queue.offer(for: record, volume: volumes.selection); XCTFail("An external store must not offer an install") }
        catch let failure as OperationFailure { XCTAssertEqual(failure.stage, "Resolve") }
    }
    func testVerificationSnapshotRejectsDelayedDownloadEventsAndClearsOnPause() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        await content.enableVerificationFixture(); await content.hold("checking")
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        let id = try await queue.enqueue(queue.offer(for: game("checking"), volume: volumes.selection))
        try await queue.start()
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while await queue.snapshot().transfer?.verification == nil, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(10))
        }
        let checking = await queue.snapshot()
        XCTAssertEqual(checking.transfer?.verification?.fraction, 0.5)
        XCTAssertEqual(checking.jobs.first?.stage, .download, "File checks do not advance the install pipeline")
        XCTAssertEqual(checking.jobs.first?.bytesCompleted, 4)
        try await queue.setPaused(true, jobID: id)
        _ = try await waitFor(queue, jobID: id, state: .paused)
        let paused = await queue.snapshot()
        XCTAssertNil(paused.transfer)
        await queue.shutdown()
    }
    func testStageVerificationIsEphemeralAndRejectsCallbacksFromPreviousStage() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        await content.enableStageVerificationFixture()
        await content.hold("verify:checks"); await content.hold("stage:checks"); await content.hold("settings:checks"); await content.hold("validate:checks")
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        let id = try await queue.enqueue(queue.offer(for: game("checks"), volume: volumes.selection))
        try await queue.start()
        for (stage, fraction) in [(JobStage.verifyOriginals, 0.25), (.stage, 0.75), (.validate, 0.5)] {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                let snapshot = await queue.snapshot()
                if snapshot.jobs.first?.stage == stage, snapshot.transfer?.verification?.fraction == fraction { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let snapshot = await queue.snapshot()
            XCTAssertEqual(snapshot.jobs.first?.stage, stage)
            XCTAssertEqual(snapshot.transfer?.verification?.fraction, fraction)
            XCTAssertEqual(snapshot.jobs.first?.bytesCompleted, 8, "Checking must not overwrite downloaded byte counts")
            if stage == .verifyOriginals { await content.release("verify:checks") }
            if stage == .stage {
                await content.release("stage:checks")
                let deadline = ContinuousClock.now + .seconds(2)
                while await queue.snapshot().preparation?.step != .applyingSettings && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let applying = await queue.snapshot()
                XCTAssertEqual(applying.preparation?.step, .applyingSettings)
                XCTAssertNil(applying.transfer)
                await content.release("settings:checks")
            }
        }
        await content.sendLateReport("verify")
        try await Task.sleep(for: .milliseconds(30))
        let afterLate = await queue.snapshot()
        XCTAssertEqual(afterLate.transfer?.verification?.fraction, 0.5)
        try await queue.setPaused(true, jobID: id)
        _ = try await waitFor(queue, jobID: id, state: .paused)
        let paused = await queue.snapshot(); XCTAssertNil(paused.transfer)
        await queue.shutdown()
    }
    func testOfflineSourceCompletesUnchangedPipelineAndCommitsInstallation() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        let offer = try await queue.offer(for: game("Café / Bundle"), volume: volumes.selection)
        let id = try await queue.enqueue(offer)
        try await queue.start()
        let completed = try await waitFor(queue, jobID: id, state: .completed)
        let installed = try XCTUnwrap(catalog.snapshot().entries.first?.installation)
        XCTAssertEqual(installed.gameID, game("Café / Bundle").id)
        XCTAssertEqual(installed.plan, offer.plan)
        XCTAssertEqual(completed.stage, .finished)
        XCTAssertEqual(try catalog.jobs().first?.state, .completed)
        await queue.shutdown()
    }
    func testQueueIsSerialAndReorderSurvivesPersistence() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        await content.hold("first")
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        var ids: [UUID] = []
        for name in ["first", "second", "third"] { ids.append(try await queue.enqueue(queue.offer(for: game(name), volume: volumes.selection))) }
        try await queue.start()
        _ = try await waitFor(queue, jobID: ids[0], state: .running)
        try await queue.move(ids[2], before: ids[1])
        XCTAssertEqual(try catalog.jobs().map(\.id), [ids[0], ids[2], ids[1]])
        let before = await content.events
        XCTAssertFalse(before.contains("download:second")); XCTAssertFalse(before.contains("download:third"))
        await content.release("first")
        _ = try await waitFor(queue, jobID: ids[1], state: .completed)
        let downloaded = await content.events.filter { $0.hasPrefix("download:") }
        XCTAssertEqual(downloaded, ["download:first", "download:third", "download:second"])
        await queue.shutdown()
    }
    func testRepairSurvivesRestartPreservesInstallIdentityAndBlocksPlayUntilValidated() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        let storage = InstallStorage(volumes: volumes), bottles = FixtureBottles(), source = OfflineSource(content: content)
        let queue = try InstallQueue(catalog: catalog, sources: [source], storage: storage, bottles: bottles)
        let id = try await queue.enqueue(queue.offer(for: game("repair"), volume: volumes.selection))
        try await queue.start(); _ = try await waitFor(queue, jobID: id, state: .completed)
        let original = try XCTUnwrap(catalog.snapshot().entries.first?.installation)
        let directory = try await storage.directory(original.location, gameID: original.gameID, owner: original.ownershipToken)
        try Data("save".utf8).write(to: directory.appendingPathComponent("player.sav"))
        try Data("short".utf8).write(to: directory.appendingPathComponent("game.exe"))
        await content.failOnce("stage:repair")
        let repair = try await queue.repair(original.gameID)
        _ = try await waitFor(queue, jobID: repair, state: .failed)
        XCTAssertTrue(try XCTUnwrap(catalog.snapshot().entries.first?.installation).needsRepair == true)
        XCTAssertThrowsError(try catalog.saveSession(.init(gameID: original.gameID, bottleID: original.bottleID)))
        await queue.shutdown()
        let restored = try InstallQueue(catalog: catalog, sources: [source], storage: storage, bottles: bottles)
        try await restored.start(); try await restored.retry(repair)
        _ = try await waitFor(restored, jobID: repair, state: .completed)
        let installed = try XCTUnwrap(catalog.snapshot().entries.first?.installation)
        XCTAssertEqual(installed.id, original.id); XCTAssertEqual(installed.installedAt, original.installedAt)
        XCTAssertEqual(installed.ownershipToken, original.ownershipToken); XCTAssertEqual(installed.manifestIDs, original.manifestIDs)
        XCTAssertEqual(installed.needsRepair, false)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("game.exe")), Data("complete".utf8))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("player.sav")), Data("save".utf8))
        let events = await content.events
        XCTAssertEqual(events.filter { $0 == "resolve:repair" }.count, 1, "Repair must keep the installed manifest")
        XCTAssertEqual(events.filter { $0 == "download:repair" }.count, 2, "Restart must reuse the successful repair download")
        try catalog.saveSession(.init(gameID: original.gameID, bottleID: original.bottleID))
        do { _ = try await restored.repair(original.gameID); XCTFail("Repair accepted a running session") } catch {}
        await restored.shutdown()
    }
    func testCancellingRepairKeepsFilesBottleAndPlayGuardUntilNextVerification() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        let bottles = FixtureBottles(), storage = InstallStorage(volumes: volumes)
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: storage, bottles: bottles)
        let id = try await queue.enqueue(queue.offer(for: game("cancel-repair"), volume: volumes.selection))
        try await queue.start(); _ = try await waitFor(queue, jobID: id, state: .completed)
        let original = try XCTUnwrap(catalog.snapshot().entries.first?.installation)
        let directory = try await storage.directory(original.location, gameID: original.gameID, owner: original.ownershipToken)
        try Data("bad".utf8).write(to: directory.appendingPathComponent("game.exe"))
        await content.hold(original.gameID.value)
        let repair = try await queue.repair(original.gameID)
        _ = try await waitFor(queue, jobID: repair, state: .running)
        try await queue.cancel(repair); _ = try await waitFor(queue, jobID: repair, state: .cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let bottle = GameBottle(gameID: original.gameID, name: original.bottleID, ownershipToken: original.ownershipToken)
        let ready = try await bottles.isReady(bottle); XCTAssertTrue(ready)
        XCTAssertThrowsError(try catalog.saveSession(.init(gameID: original.gameID, bottleID: original.bottleID)))
        let events = await content.events; XCTAssertFalse(events.contains("cleanup:cancel-repair"))
        await content.release(original.gameID.value)
        let retry = try await queue.repair(original.gameID)
        _ = try await waitFor(queue, jobID: retry, state: .completed)
        XCTAssertEqual(try catalog.snapshot().entries.first?.installation?.needsRepair, false)
        await queue.shutdown()
    }
    func testUserAndGameplayPausesAreIndependentAndNewJobsInheritGameplayPause() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        try await queue.start(); try await queue.setGameplayPaused(true)
        let id = try await queue.enqueue(queue.offer(for: game("paused"), volume: volumes.selection))
        try await queue.setPaused(true, jobID: id)
        try await queue.setGameplayPaused(false)
        let paused = try await waitFor(queue, jobID: id, state: .paused)
        XCTAssertEqual(paused.pauseReasons, [.user])
        try await queue.setPaused(false, jobID: id)
        _ = try await waitFor(queue, jobID: id, state: .completed)
        await queue.shutdown()
    }
    func testCancellationRemovesPartialContentAndRunsSourceCleanup() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        await content.hold("cancelled")
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        let id = try await queue.enqueue(queue.offer(for: game("cancelled"), volume: volumes.selection)); try await queue.start()
        let limit = Date().addingTimeInterval(5)
        while !(await content.events.contains("download:cancelled")) && Date() < limit { try await Task.sleep(for: .milliseconds(10)) }
        try await queue.cancel(id)
        let cancelled = try await waitFor(queue, jobID: id, state: .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(CrossOverGameBottles.name(for: cancelled.gameID)).path))
        let events = await content.events; XCTAssertTrue(events.contains("cleanup:cancelled"))
        XCTAssertTrue(try catalog.snapshot().entries.isEmpty)
        await queue.shutdown()
    }
    func testGameplayPauseWaitsForDownloadWorkerToFinish() async throws {
        let root = try root(), catalog = try CatalogStore(), content = OfflineContent(), volumes = FixtureVolumes(root: root)
        await content.hold("playing")
        let queue = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: FixtureBottles())
        let id = try await queue.enqueue(queue.offer(for: game("playing"), volume: volumes.selection)); try await queue.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await content.events.contains("download:playing")) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let downloading = await content.events.contains("download:playing"); XCTAssertTrue(downloading)
        try await queue.setGameplayPaused(true)
        let snapshot = await queue.snapshot()
        XCTAssertNil(snapshot.activeJobID)
        XCTAssertEqual(snapshot.jobs.first(where: { $0.id == id })?.state, .paused)
        XCTAssertEqual(snapshot.jobs.first(where: { $0.id == id })?.pauseReasons, [.gameplay])
        await queue.shutdown()
    }
    func testRestartKeepsPinnedPlanAndCompletedDownloadAfterPostInstallFailure() async throws {
        let root = try root(), database = root.appendingPathComponent("catalog.sqlite").path
        let content = OfflineContent(), volumes = FixtureVolumes(root: root), bottles = FixtureBottles()
        await content.failOnce("stage:retry")
        let catalog = try CatalogStore(path: database)
        let first = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: bottles)
        let id = try await first.enqueue(first.offer(for: game("retry"), volume: volumes.selection)); try await first.start()
        let failed = try await waitFor(first, jobID: id, state: .failed)
        XCTAssertTrue(failed.completedStages.contains(.download)); await first.shutdown()
        let reopened = try CatalogStore(path: database)
        let second = try InstallQueue(catalog: reopened, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: bottles)
        try await second.start(); try await second.retry(id)
        let completed = try await waitFor(second, jobID: id, state: .completed)
        XCTAssertEqual(completed.plan, failed.plan)
        let events = await content.events
        XCTAssertEqual(events.filter { $0 == "resolve:retry" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "download:retry" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "stage:retry" }.count, 2)
        await second.shutdown()
    }
    func testPrerequisiteFailureRestartsAtPrerequisitesWithoutRepeatingDownload() async throws {
        let root = try root(), path = root.appendingPathComponent("catalog.sqlite").path
        let content = OfflineContent(), volumes = FixtureVolumes(root: root), bottles = FixtureBottles()
        await content.failOnce("prerequisites:retry")
        let first = try InstallQueue(catalog: CatalogStore(path: path), sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: bottles)
        let id = try await first.enqueue(first.offer(for: game("retry"), volume: volumes.selection)); try await first.start()
        let failed = try await waitFor(first, jobID: id, state: .failed)
        XCTAssertEqual(failed.stage, .prerequisites)
        XCTAssertTrue(failed.completedStages.contains(.createBottle)); XCTAssertFalse(failed.completedStages.contains(.prerequisites))
        await first.shutdown()
        let second = try InstallQueue(catalog: CatalogStore(path: path), sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: bottles)
        try await second.start(); try await second.retry(id)
        _ = try await waitFor(second, jobID: id, state: .completed)
        let events = await content.events
        XCTAssertEqual(events.filter { $0 == "download:retry" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "prerequisites:retry" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "stage:retry" }.count, 1)
        await second.shutdown()
    }
    func testMissingRuntimeAtEachPreparationCheckpointRebuildsBeforeRetry() async throws {
        for step in ["prerequisites", "stage", "validate", "acknowledge"] {
            let root = try root(), path = root.appendingPathComponent("catalog.sqlite").path
            let content = OfflineContent(), volumes = FixtureVolumes(root: root), bottles = FixtureBottles()
            if step == "acknowledge" { await bottles.failAcknowledgmentOnce() }
            else { await content.failOnce(step + ":retry") }
            let first = try InstallQueue(catalog: CatalogStore(path: path), sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: bottles)
            let id = try await first.enqueue(first.offer(for: game("retry"), volume: volumes.selection)); try await first.start()
            let failed = try await waitFor(first, jobID: id, state: .failed)
            XCTAssertTrue(failed.completedStages.contains(.createBottle))
            await first.shutdown()
            try await bottles.remove(XCTUnwrap(failed.bottle))
            let catalog = try CatalogStore(path: path)
            let second = try InstallQueue(catalog: catalog, sources: [OfflineSource(content: content)], storage: InstallStorage(volumes: volumes), bottles: bottles)
            try await second.start(); try await second.retry(id)
            _ = try await waitFor(second, jobID: id, state: .completed)
            XCTAssertNotNil(try catalog.snapshot().entries.first?.installation)
            let preparations = await bottles.preparations; XCTAssertEqual(preparations, 2)
            let acknowledgments = await bottles.acknowledgments; XCTAssertEqual(acknowledgments, step == "acknowledge" ? 2 : 1)
            let events = await content.events
            XCTAssertEqual(events.filter { $0 == "download:retry" }.count, 1)
            XCTAssertEqual(events.filter { $0 == "prerequisites:retry" }.count, 2)
            await second.shutdown()
        }
    }
    func testStorageRejectsUnownedFoldersWrongTokenAndEscapingLocation() async throws {
        let root = try root(), volumes = FixtureVolumes(root: root), storage = InstallStorage(volumes: volumes)
        let id = game("owned").id, token = UUID()
        var location = try await storage.prepare(gameID: id, owner: token, on: volumes.selection)
        do { try await storage.remove(location, gameID: id, owner: UUID()); XCTFail("Wrong owner accepted") } catch {}
        location.relativePath = "../outside"
        do { _ = try await storage.directory(location, gameID: id, owner: token); XCTFail("Escaping location accepted") } catch {}
        let unowned = root.appendingPathComponent(CrossOverGameBottles.name(for: game("unowned").id))
        try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: true)
        do { _ = try await storage.prepare(gameID: game("unowned").id, owner: UUID(), on: volumes.selection); XCTFail("Unowned folder adopted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: unowned.path))
    }
}
