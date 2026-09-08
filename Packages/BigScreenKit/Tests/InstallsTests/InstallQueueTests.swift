import XCTest
import Foundation
import Domain
import Catalog
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
/// A store with no sign-in, no numeric IDs, no depots and no Steam emulation. The same queue runs it.
private struct OfflineSource: GameSource {
    let id = "offlinefixture", displayName = "Offline files"
    let auth: any SourceAuth = OfflineAuth()
    let content: OfflineContent
    func ownedGames() async throws -> [SourceGameRecord] { [] }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
    func installer(for game: SourceGameRecord) throws -> any Installer { OfflineInstaller(game: game, content: content) }
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
    func download(_ plan: InstallPlan, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        try await content.record("download:" + gameID.value)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BigScreen-queue-\(UUID().uuidString)")
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
