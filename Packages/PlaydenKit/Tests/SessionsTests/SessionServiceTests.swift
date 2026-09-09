import XCTest
import Foundation
import Synchronization
import Domain
import Catalog
import Installs
@testable import Sessions

private final class TestClock: SessionClock, Sendable {
    private let state = Mutex((wall: Date(timeIntervalSince1970: 1000), uptime: 100.0))
    var wallTime: Date { state.withLock { $0.wall } }
    var uptime: TimeInterval { state.withLock { $0.uptime } }
    func advance(_ seconds: Double, wall: Double? = nil) {
        state.withLock { $0.uptime += seconds; $0.wall.addTimeInterval(wall ?? seconds) }
    }
}
private actor Events {
    var values: [String] = []
    var prerequisiteChecks = 0
    var prerequisiteFailure = false
    var preparationPending = false
    var failedPreparationStep: String?
    var appliedOptions: [[String: String]] = []
    func recordAppliedOptions(_ options: [String: String]) { appliedOptions.append(options) }
    func failPreparationOnce(_ step: String) { failedPreparationStep = step }
    func preparationRequired(changed: Bool) -> Bool {
        preparationPending = preparationPending || changed
        return preparationPending
    }
    func preparationStep(_ step: String) throws {
        if step != "acknowledge" { values.append(step) }
        if failedPreparationStep == step {
            failedPreparationStep = nil
            throw OperationFailure(stage: step, reason: "Retry source preparation.", output: "fixture")
        }
        if step == "acknowledge" { preparationPending = false }
    }
    func add(_ event: String) { values.append(event) }
    func failPrerequisiteOnce() { prerequisiteFailure = true }
    func checkPrerequisite() throws {
        prerequisiteChecks += 1
        if prerequisiteFailure {
            prerequisiteFailure = false
            throw OperationFailure(stage: "Fixture prerequisite", reason: "Retry preparation.", output: "fixture")
        }
    }
}
private actor Queue: InstallQueuing {
    let events: Events
    var paused = false
    init(_ events: Events) { self.events = events }
    func start() async throws { await events.add("queue:start") }
    func shutdown() async { await events.add("queue:stop") }
    func setGameplayPaused(_ paused: Bool) async throws { self.paused = paused; await events.add("pause:\(paused)") }
    func updates() -> AsyncStream<InstallQueueSnapshot> { AsyncStream { $0.finish() } }
    func offer(for game: SourceGameRecord, volume: GamesVolumeSelection) async throws -> InstallOffer { throw SourceFailure.unavailable }
    func enqueue(_ offer: InstallOffer) async throws -> UUID { throw SourceFailure.unavailable }
    func uninstall(_ authorization: UninstallAuthorization) async throws -> UUID { throw SourceFailure.unavailable }
    func repair(_ gameID: GameID) async throws -> UUID { throw SourceFailure.unavailable }
    func setPaused(_ paused: Bool, reason: PauseReason, jobID: UUID) async throws {}
    func retry(_ jobID: UUID) async throws {}
    func cancel(_ jobID: UUID) async throws {}
    func move(_ jobID: UUID, before otherID: UUID) async throws {}
}
private struct Storage: InstallStorageManaging {
    func freeBytes(on volume: GamesVolumeSelection) async throws -> Int64 { 1000 }
    func prepare(gameID: GameID, owner: UUID, on volume: GamesVolumeSelection) async throws -> GameLocation { throw SourceFailure.unavailable }
    func directory(_ location: GameLocation, gameID: GameID, owner: UUID) async throws -> URL { URL(fileURLWithPath: "/fixture/game") }
    func remove(_ location: GameLocation, gameID: GameID, owner: UUID) async throws {}
}
private actor Runner: GameRunner {
    let events: Events
    var snapshot: RunSnapshot?
    var listener: AsyncStream<RunSnapshot>.Continuation?
    var changed = false, held = false, graceful = true
    var lastLaunchSpec: LaunchSpec?
    init(_ events: Events) { self.events = events }
    func configure(changed: Bool = false, held: Bool = false, graceful: Bool = true) { self.changed = changed; self.held = held; self.graceful = graceful }
    func prepare(_ bottle: GameBottle) async throws -> Bool {
        await events.add("prepare")
        while held { try await Task.sleep(for: .milliseconds(5)) }
        return await events.preparationRequired(changed: changed)
    }
    func completePreparation(_ bottle: GameBottle) async throws { try await events.preparationStep("acknowledge") }
    func launch(_ spec: LaunchSpec, in bottle: GameBottle, directory: URL) async throws -> RunningGame {
        lastLaunchSpec = spec
        await events.add("launch:" + spec.executableRelativePath)
        let run = RunningGame(bottle: bottle, launcher: .init(pid: 99999, startSeconds: 1, startMicroseconds: 0))
        snapshot = .init(run: run)
        return run
    }
    func observe(_ run: RunningGame) -> AsyncStream<RunSnapshot> {
        AsyncStream { listener = $0; if let snapshot { $0.yield(snapshot) } }
    }
    func recover(_ saved: RunSnapshot) async throws -> RunSnapshot {
        await events.add("recover")
        snapshot = saved
        return saved
    }
    func emit(window: Bool = true, exit: Int32? = nil, forced: Bool = false) {
        guard var next = snapshot else { return }
        next.hadWindow = window; next.phase = exit == nil ? .running : .exited
        next.window = window ? .init(id: 1, process: next.run.launcher) : nil
        next.exitCode = exit; next.forced = forced
        snapshot = next; listener?.yield(next)
        if next.phase == .exited { listener?.finish() }
    }
    func terminate(_ run: RunningGame, force: Bool) async throws {
        await events.add(force ? "force" : "graceful")
        if force || graceful { emit(window: snapshot?.hadWindow ?? false, exit: 0, forced: force) }
    }
}
private struct Auth: SourceAuth {
    func identity() async throws -> SourceIdentity? { nil }
    func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func signIn(accountName: String, password: String, codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String, onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    func cancelSignIn() async {}
    func signOut() async throws {}
}
private struct Store: GameSource {
    let id = "fixture", displayName = "Fixture"
    let auth: any SourceAuth = Auth()
    let events: Events
    func ownedGames() async throws -> [SourceGameRecord] { [] }
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord { game }
    func installer(for game: SourceGameRecord) throws -> any Installer { Content(gameID: game.id, events: events) }
}
private struct Content: Installer {
    let gameID: GameID
    let events: Events
    func resolve() async throws -> InstallPlan { throw SourceFailure.unavailable }
    func download(_ plan: InstallPlan, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws { throw SourceFailure.unavailable }
    func verifyOriginals(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?) async throws -> VerificationResult { .init(invalidFiles: []) }
    func postInstall(_ plan: InstallPlan, at directory: URL) async throws -> InstallStaging { try await events.preparationStep("stage"); return .init() }
    func preparePrerequisites(_ plan: InstallPlan, at directory: URL, in bottle: GameBottle) async throws { try await events.checkPrerequisite() }
    func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging) async throws -> LaunchSpec { try await events.preparationStep("validate"); return .init(executableRelativePath: "rebuilt.exe") }
    func applyRuntimeOptions(_ options: [String: String], plan: InstallPlan, at directory: URL) async throws { await events.recordAppliedOptions(options) }
    func uninstall(_ plan: InstallPlan, at directory: URL) async throws {}
    func saveMapping(_ plan: InstallPlan) throws -> SaveMapping {
        .init(rules: [.init(root: .game, directory: "saves", pattern: "*.sav", cloudPrefix: "%GameInstall%saves")], coverage: .metadata)
    }
}

private actor SessionCloud: CloudSyncManaging {
    let catalog: CatalogStore, events: Events
    var before: CloudSyncStatus.State = .upToDate
    var holdExit = false
    var calls: [PlaySessionRecord] = []
    var authorizations: [CloudSyncAuthorization?] = []
    init(_ catalog: CatalogStore, _ events: Events) { self.catalog = catalog; self.events = events }
    func configure(before: CloudSyncStatus.State = .upToDate, holdExit: Bool = false) {
        self.before = before; self.holdExit = holdExit
    }
    func updates() -> AsyncStream<[GameID: CloudSyncStatus]> { AsyncStream { $0.finish() } }
    func recoverInterruptedOperations() async throws {
        await events.add("cloud:recover")
        for operation in try catalog.cloudOperations() where operation.claim != nil && !operation.phase.isTerminal {
            _ = try catalog.recoverInterruptedCloudSync(operation)
        }
    }
    func synchronize(_ installed: InstallationRecord, mapping: SaveMapping, preparingSessionID: UUID?,
                     authorization: CloudSyncAuthorization?) async -> CloudSyncStatus {
        var operation: CloudSyncOperation?
        do {
            let session = try XCTUnwrap(catalog.unfinishedSessions().first { $0.id == preparingSessionID })
            calls.append(session); authorizations.append(authorization)
            let exiting = session.runtime?.phase == .exited
            await events.add(exiting ? "cloud:exit" : "cloud:launch")
            if let pending = try catalog.cloudOperations(for: installed.gameID).last(where: { !$0.phase.isTerminal }) {
                operation = try catalog.resumeCloudSync(pending, preparingSessionID: preparingSessionID)
            } else {
                operation = try catalog.beginCloudSync(installation: installed, accountKey: "fixture-account",
                    mapping: mapping, preparingSessionID: preparingSessionID)
            }
            while exiting && holdExit { try await Task.sleep(for: .milliseconds(5)) }
            if exiting || before == .upToDate {
                if operation?.needsLocalRecovery == true {
                    operation = try catalog.stageCloudLocalRecovery(XCTUnwrap(operation),
                        recovery: .init(localSnapshotID: UUID(), remoteSnapshotID: UUID(), plan: XCTUnwrap(operation?.plan)))
                    operation = try catalog.authorizeCloudLocalRecovery(XCTUnwrap(operation))
                    operation = try catalog.markCloudLocalApplied(XCTUnwrap(operation))
                    await events.add("cloud:local-recovery")
                }
                operation = try catalog.supersedeCloudSync(XCTUnwrap(operation))
                await events.add("cloud:finished")
                return .init(gameID: installed.gameID, state: .upToDate, operation: operation, message: "Up to date")
            }
            operation = try catalog.pauseCloudSync(XCTUnwrap(operation), phase: .conflict)
            return .init(gameID: installed.gameID, state: before, operation: operation, message: "Review saves", canPlayOffline: operation?.needsLocalRecovery == false)
        } catch {
            if let current = operation, current.claim != nil { operation = try? catalog.pauseCloudSync(current, phase: .pending) }
            return .init(gameID: installed.gameID, state: .pendingUpload, operation: operation,
                message: "Sync interrupted", canPlayOffline: operation?.claim == nil && operation?.needsLocalRecovery == false)
        }
    }
}
@MainActor
final class SessionServiceTests: XCTestCase {
    func testSelectedLaunchOptionSurvivesRuntimePreparationAndCloudPrompt() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        var game = try installed(catalog)
        let selected = LaunchOption(id: "dx11", title: "DirectX 11", spec: .init(executableRelativePath: "Alternate.exe", workingDirectoryRelativePath: "Bin", arguments: ["-dx11"]))
        game.plan = .init(game: game.game, manifestIDs: [:], estimate: .init(downloadBytes: 1, installedBytes: 1, requiredBytes: 1),
            launchSpec: game.launchSpec, sourcePayload: Data(), launchOptions: [selected])
        try catalog.saveInstallation(game)
        let cloud = SessionCloud(catalog, events)
        await cloud.configure(before: .conflict); await runner.configure(changed: true)
        let service = try make(catalog, runner, queue, clock, events, cloud: cloud)
        try await service.start(downloadWhilePlaying: false)
        do { try await service.play(game.gameID, launchOptionID: "missing"); XCTFail("Unknown choice must fail before starting a session") } catch {}
        XCTAssertTrue(try catalog.unfinishedSessions().isEmpty)
        try await service.play(game.gameID, launchOptionID: "dx11")
        _ = try await wait(service, phase: .awaitingCloud)
        try await service.playOffline()
        _ = try await wait(service, phase: .launching)
        let actual = await runner.lastLaunchSpec
        XCTAssertEqual(actual, selected.spec)
        XCTAssertEqual(try catalog.snapshot().entries.first?.installation?.launchSpec.executableRelativePath, "rebuilt.exe", "One-time selection must not replace the prepared default")
        await runner.emit(exit: 0); _ = try await wait(service, phase: .idle)
        await cloud.configure(before: .upToDate); await runner.configure(changed: false)
        try await service.play(game.gameID)
        _ = try await wait(service, phase: .launching)
        let next = await runner.lastLaunchSpec
        XCTAssertEqual(next?.executableRelativePath, "rebuilt.exe", "One-time selection must not leak to the next session")
        await runner.emit(exit: 0); _ = try await wait(service, phase: .idle)
    }
    func testStoredRuntimeProfileLaunchOptionSelectsMatchingSpec() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        var game = try installed(catalog)
        let first = LaunchOption(id: "dx10", title: "DirectX 10", spec: .init(executableRelativePath: "DX10.exe"))
        let second = LaunchOption(id: "dx11", title: "DirectX 11", spec: .init(executableRelativePath: "Alternate.exe", workingDirectoryRelativePath: "Bin", arguments: ["-dx11"]))
        game.plan = .init(game: game.game, manifestIDs: [:], estimate: .init(downloadBytes: 1, installedBytes: 1, requiredBytes: 1),
            launchSpec: game.launchSpec, sourcePayload: Data(), launchOptions: [first, second])
        try catalog.saveInstallation(game)
        var edits = GameEdits(); edits.runtime = RuntimeProfile(overrides: [.launchOption: .scalar("dx11")])
        try catalog.saveEdits(edits, for: game.gameID)
        let service = try make(catalog, runner, queue, clock, events)
        try await service.start(downloadWhilePlaying: false)
        try await service.play(game.gameID)
        _ = try await wait(service, phase: .launching)
        let actual = await runner.lastLaunchSpec
        XCTAssertEqual(actual, second.spec)
        await runner.emit(exit: 0); _ = try await wait(service, phase: .idle)
    }
    func testStoredRuntimeProfileLaunchOptionMissingFallsBackToDefaultWithoutError() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        let game = try installed(catalog)
        var edits = GameEdits(); edits.runtime = RuntimeProfile(overrides: [.launchOption: .scalar("missing")])
        try catalog.saveEdits(edits, for: game.gameID)
        let service = try make(catalog, runner, queue, clock, events)
        try await service.start(downloadWhilePlaying: false)
        try await service.play(game.gameID)
        _ = try await wait(service, phase: .launching)
        let actual = await runner.lastLaunchSpec
        XCTAssertEqual(actual?.executableRelativePath, game.launchSpec.executableRelativePath)
        await runner.emit(exit: 0); _ = try await wait(service, phase: .idle)
    }
    func testRuntimeProfileSourceOptionsAreAppliedOnEveryLaunch() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        let game = try installed(catalog)
        var edits = GameEdits(); edits.runtime = RuntimeProfile(overrides: [.steamOverlay: .scalar("on")])
        try catalog.saveEdits(edits, for: game.gameID)
        let service = try make(catalog, runner, queue, clock, events)
        try await service.start(downloadWhilePlaying: false)
        try await service.play(game.gameID)
        _ = try await wait(service, phase: .launching)
        var applied = await events.appliedOptions
        XCTAssertEqual(applied.last?["steam.overlay"], "1")
        await runner.emit(exit: 0); _ = try await wait(service, phase: .idle)
        try await service.play(game.gameID)
        _ = try await wait(service, phase: .launching)
        applied = await events.appliedOptions
        XCTAssertEqual(applied.count, 2, "Source options must be re-applied on every launch")
        XCTAssertEqual(applied.last?["steam.overlay"], "1")
        await runner.emit(exit: 0); _ = try await wait(service, phase: .idle)
    }
    private func installed(_ catalog: CatalogStore, id: String = "one") throws -> InstallationRecord {
        let game = SourceGameRecord(id: GameID(source: "fixture", value: id), title: id)
        var installation = InstallationRecord(game: game, location: .init(volumeID: "fixture", lastKnownRoot: URL(fileURLWithPath: "/fixture"), relativePath: "game"), bottleID: "playden-fixture-" + id, manifestIDs: [:], templateVersion: "1", launchSpec: .init(executableRelativePath: "game.exe"), installedBytes: 100)
        installation.plan = .init(game: game, manifestIDs: [:], estimate: .init(downloadBytes: 100, installedBytes: 100, requiredBytes: 100), launchSpec: installation.launchSpec, sourcePayload: Data())
        try catalog.saveInstallation(installation)
        return installation
    }
    private func make(_ catalog: CatalogStore, _ runner: Runner, _ queue: Queue, _ clock: TestClock, _ events: Events, cloud: (any CloudSyncManaging)? = nil) throws -> SessionService {
        try SessionService(catalog: catalog, sources: [Store(events: events)], runner: runner, queue: queue, storage: Storage(), clock: clock, quitGrace: .milliseconds(20), stopTimeout: .seconds(1), cloud: cloud)
    }
    private func current(_ service: SessionService) async -> SessionSnapshot {
        var iterator = await service.updates().makeAsyncIterator()
        return await iterator.next()!
    }
    private func wait(_ service: SessionService, phase: SessionPhase, seconds: Int64? = nil) async throws -> SessionSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let value = await current(service)
            if value.phase == phase && (seconds == nil || value.session?.playedSeconds == seconds) { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Session did not reach \(phase)")
        throw SourceFailure.unavailable
    }
    func testWindowStartsMonotonicPlaytimeAndShortCleanExitStaysClean() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        let game = try installed(catalog), service = try make(catalog, runner, queue, clock, events)
        try await service.start(downloadWhilePlaying: false); try await service.play(game.gameID)
        _ = try await wait(service, phase: .launching)
        clock.advance(20); await runner.emit(); _ = try await wait(service, phase: .running)
        clock.advance(7, wall: -500); await runner.emit(exit: 0)
        let ended = try await wait(service, phase: .idle)
        XCTAssertEqual(ended.session?.playedSeconds, 7); XCTAssertEqual(ended.session?.outcome, .clean)
        XCTAssertGreaterThanOrEqual(ended.session!.endedAt!, ended.session!.startedAt)
        XCTAssertTrue(try catalog.unfinishedSessions().isEmpty)
        let paused = await queue.paused; XCTAssertFalse(paused)
        let ordered = await events.values
        XCTAssertEqual(Array(ordered.suffix(4)), ["pause:true", "prepare", "launch:game.exe", "pause:false"])
        try await service.quit() // repeated exit must not create another checkpoint/session
        let repeated = await current(service); XCTAssertEqual(repeated.session?.id, ended.session?.id)
    }
    func testSingleSessionAndForcedExitWinsOverZeroStatus() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        await runner.configure(graceful: false)
        let game = try installed(catalog), other = try installed(catalog, id: "two"), service = try make(catalog, runner, queue, clock, events)
        try await service.start(downloadWhilePlaying: true); try await service.play(game.gameID)
        _ = try await wait(service, phase: .launching)
        do { try await service.play(other.gameID); XCTFail("Second game launched") } catch {}
        await runner.emit(); _ = try await wait(service, phase: .running)
        let paused = await queue.paused; XCTAssertFalse(paused)
        try await service.quit()
        let ended = await current(service); XCTAssertEqual(ended.session?.outcome, .forced)
        let ordered = await events.values; XCTAssertEqual(Array(ordered.suffix(3)), ["graceful", "force", "pause:false"])
    }
    func testEarlyExitAndNonzeroExitHaveDistinctOutcomes() async throws {
        for window in [false, true] {
            let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
            let game = try installed(catalog), service = try make(catalog, runner, queue, clock, events)
            try await service.start(downloadWhilePlaying: false); try await service.play(game.gameID)
            _ = try await wait(service, phase: .launching)
            await runner.emit(window: window, exit: 7)
            let ended = try await wait(service, phase: .idle)
            XCTAssertEqual(ended.session?.outcome, window ? .crash : .launchFailed)
        }
    }
    func testRecoveryPrecedesQueueAndDoesNotCountOfflineWallTime() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        let game = try installed(catalog), service = try make(catalog, runner, queue, clock, events)
        var saved = PlaySessionRecord(gameID: game.gameID, bottleID: game.bottleID, startedAt: Date(timeIntervalSince1970: 100))
        saved.playedSeconds = 17
        let bottle = GameBottle(gameID: game.gameID, name: game.bottleID, ownershipToken: game.ownershipToken)
        saved.runtime = .init(run: .init(bottle: bottle, launcher: .init(pid: 99999, startSeconds: 1, startMicroseconds: 0)), phase: .running, hadWindow: true)
        try catalog.saveSession(saved)
        try await service.start(downloadWhilePlaying: false)
        let ordered = await events.values; XCTAssertEqual(ordered, ["pause:true", "recover", "pause:true", "queue:start"])
        clock.advance(8); await runner.emit(exit: 0)
        let ended = try await wait(service, phase: .idle)
        XCTAssertEqual(ended.session?.id, saved.id); XCTAssertEqual(ended.session?.playedSeconds, 25)
        XCTAssertTrue(try catalog.unfinishedSessions().isEmpty)
    }
    func testQuitDuringPreparationDoesNotSpawnAndShutdownKeepsQueueStopped() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        await runner.configure(held: true)
        let game = try installed(catalog), service = try make(catalog, runner, queue, clock, events)
        try await service.start(downloadWhilePlaying: false); try await service.play(game.gameID)
        try await Task.sleep(for: .milliseconds(20))
        try await service.shutdown()
        let ordered = await events.values
        XCTAssertFalse(ordered.contains("launch:game.exe")); XCTAssertEqual(ordered.last, "queue:stop")
        let ended = await current(service); XCTAssertEqual(ended.session?.outcome, .interrupted)
        XCTAssertTrue(try catalog.unfinishedSessions().isEmpty)
    }
    func testCloudConflictPausesLaunchAndOfflineChoiceSkipsOnlyThatPreflight() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        let cloud = SessionCloud(catalog, events), game = try installed(catalog)
        await cloud.configure(before: .conflict)
        let service = try make(catalog, runner, queue, clock, events, cloud: cloud)
        try await service.start(downloadWhilePlaying: false); try await service.play(game.gameID)
        let waiting = try await wait(service, phase: .awaitingCloud)
        XCTAssertEqual(waiting.cloudStatus?.state, .conflict)
        var ordered = await events.values; XCTAssertFalse(ordered.contains("launch:game.exe"))
        XCTAssertEqual(try catalog.unfinishedSessions().count, 1)
        let client: any SessionManaging = service
        try await client.playOffline()
        _ = try await wait(service, phase: .launching)
        ordered = await events.values
        XCTAssertEqual(ordered.filter { $0 == "cloud:launch" }.count, 1)
        await runner.emit(exit: 0)
        _ = try await wait(service, phase: .idle)
        ordered = await events.values; XCTAssertTrue(ordered.contains("cloud:exit"))
        let log = try XCTUnwrap(catalog.diagnosticLog(try XCTUnwrap(waiting.session).id))
        let messages = log.events.map(\.message)
        XCTAssertTrue(messages.contains("Cloud before launch · checking"))
        XCTAssertTrue(messages.contains("Cloud before launch · conflict"))
        XCTAssertTrue(messages.contains("Cloud before launch · offline choice"))
        XCTAssertTrue(messages.contains("Cloud after exit · checking"))
        XCTAssertTrue(messages.contains(where: { $0.hasPrefix("Cloud after exit · ") && $0 != "Cloud after exit · checking" }))
    }

    func testCloudRetryForwardsChoiceAndLaunchesOnlyAfterSuccessfulSync() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        let cloud = SessionCloud(catalog, events), game = try installed(catalog)
        await cloud.configure(before: .conflict)
        let service = try make(catalog, runner, queue, clock, events, cloud: cloud)
        try await service.start(downloadWhilePlaying: false); try await service.play(game.gameID)
        let waiting = try await wait(service, phase: .awaitingCloud)
        let reviewed = try XCTUnwrap(waiting.cloudStatus?.operation)
        clock.advance(7)
        await cloud.configure()
        let client: any SessionManaging = service
        try await client.retryCloud(authorization: .init(operation: reviewed, conflictChoice: .remote, attachAccount: true))
        _ = try await wait(service, phase: .launching)
        let choices = await cloud.authorizations
        XCTAssertEqual(choices.count, 2); XCTAssertEqual(choices[1]?.operation, reviewed)
        let ordered = await events.values
        XCTAssertLessThan(try XCTUnwrap(ordered.lastIndex(of: "cloud:finished")), try XCTUnwrap(ordered.firstIndex(of: "launch:game.exe")))
        try await service.quit()
        let log = try XCTUnwrap(catalog.diagnosticLog(try XCTUnwrap(waiting.session).id))
        XCTAssertEqual(log.events.filter { $0.message == "Cloud before launch · checking" }.count, 2)
        XCTAssertTrue(log.events.contains { $0.message == "Cloud before launch · upToDate" })
        let cloudTime = try XCTUnwrap(log.events.last { $0.message == "Cloud before launch · upToDate" }).timestamp
        let launchTime = try XCTUnwrap(log.events.first { $0.message == "Runtime · launching" }).timestamp
        XCTAssertGreaterThanOrEqual(launchTime, cloudTime, "Launch timestamp must follow the completed Cloud preflight")
    }

    func testExitSyncKeepsDurableSessionReservationAndDoesNotCountSyncTime() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        let cloud = SessionCloud(catalog, events), game = try installed(catalog)
        await cloud.configure(holdExit: true)
        let service = try make(catalog, runner, queue, clock, events, cloud: cloud)
        try await service.start(downloadWhilePlaying: false); try await service.play(game.gameID)
        _ = try await wait(service, phase: .launching)
        await runner.emit(); _ = try await wait(service, phase: .running)
        clock.advance(20)
        let quitting = Task { try await service.quit() }
        _ = try await wait(service, phase: .syncingSaves)
        let saved = try XCTUnwrap(catalog.unfinishedSessions().first)
        XCTAssertEqual(saved.runtime?.phase, .exited); XCTAssertNil(saved.endedAt)
        do { try await service.play(game.gameID); XCTFail("Started during exit sync") } catch { }
        do { _ = try catalog.beginCloudSync(installation: game, accountKey: "other", mapping: .init()); XCTFail("Background sync stole reservation") } catch { }
        clock.advance(60)
        try await Task.sleep(for: .milliseconds(40))
        let duringSync = await events.values; XCTAssertFalse(duringSync.contains("force"))
        await cloud.configure()
        try await quitting.value
        let ended = try await wait(service, phase: .idle)
        XCTAssertEqual(ended.session?.playedSeconds, 20); XCTAssertEqual(ended.session?.outcome, .clean)
        XCTAssertTrue(try catalog.unfinishedSessions().isEmpty)
        let ordered = await events.values
        XCTAssertLessThan(try XCTUnwrap(ordered.lastIndex(of: "cloud:finished")), try XCTUnwrap(ordered.lastIndex(of: "pause:false")))
    }

    func testQuitWhileWaitingForCloudDoesNotLaunchAndExitSyncCancellationLeavesPendingWork() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        let cloud = SessionCloud(catalog, events), game = try installed(catalog)
        await cloud.configure(before: .conflict)
        let service = try make(catalog, runner, queue, clock, events, cloud: cloud)
        try await service.start(downloadWhilePlaying: false); try await service.play(game.gameID)
        _ = try await wait(service, phase: .awaitingCloud)
        try await service.quit()
        XCTAssertTrue(try catalog.unfinishedSessions().isEmpty)
        let ordered = await events.values; XCTAssertFalse(ordered.contains("launch:game.exe"))
        await cloud.configure(holdExit: true)
        try await service.play(game.gameID); _ = try await wait(service, phase: .launching)
        await runner.emit(exit: 0); _ = try await wait(service, phase: .syncingSaves)
        try await service.quit()
        let ended = try await wait(service, phase: .idle)
        XCTAssertEqual(ended.cloudStatus?.state, .pendingUpload)
        XCTAssertEqual(ended.session?.outcome, .clean)
        let pending = try XCTUnwrap(catalog.cloudOperations(for: game.gameID).last)
        XCTAssertEqual(pending.phase, .pending); XCTAssertNil(pending.claim)
    }

    func testRestartRecoversExitedSessionAndItsCloudClaimBeforeStartingQueue() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        let cloud = SessionCloud(catalog, events), game = try installed(catalog)
        let bottle = GameBottle(gameID: game.gameID, name: game.bottleID, ownershipToken: game.ownershipToken, templateVersion: game.templateVersion)
        var saved = PlaySessionRecord(gameID: game.gameID, bottleID: game.bottleID, startedAt: clock.wallTime)
        saved.runtime = .init(run: .init(bottle: bottle, launcher: .init(pid: 123, startSeconds: 1, startMicroseconds: 0)))
        saved.runtime?.phase = .exited; saved.runtime?.hadWindow = true; saved.runtime?.exitCode = 0
        saved.playedSeconds = 25
        try catalog.saveSession(saved)
        let mapping = try Content(gameID: game.gameID, events: events).saveMapping(XCTUnwrap(game.plan))
        let interrupted = try catalog.beginCloudSync(installation: game, accountKey: "fixture-account", mapping: mapping, preparingSessionID: saved.id)
        var lateRunning = saved; lateRunning.runtime?.phase = .running
        XCTAssertThrowsError(try catalog.saveSession(lateRunning))
        let service = try make(catalog, runner, queue, clock, events, cloud: cloud)
        try await service.start(downloadWhilePlaying: false)
        let final = try XCTUnwrap(catalog.latestSession(for: game.gameID))
        XCTAssertEqual(final.id, saved.id); XCTAssertEqual(final.playedSeconds, 25); XCTAssertEqual(final.outcome, .clean)
        XCTAssertNotNil(final.endedAt)
        XCTAssertEqual(try catalog.cloudOperations(for: game.gameID).first { $0.id == interrupted.id }?.phase, .superseded)
        let ordered = await events.values
        XCTAssertLessThan(try XCTUnwrap(ordered.firstIndex(of: "recover")), try XCTUnwrap(ordered.firstIndex(of: "cloud:recover")))
        XCTAssertLessThan(try XCTUnwrap(ordered.firstIndex(of: "cloud:finished")), try XCTUnwrap(ordered.firstIndex(of: "queue:start")))
        XCTAssertFalse(ordered.contains("launch:game.exe"))
    }

    func testRuntimeRebuildRestagesAndPersistsValidatedLaunchSpec() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        await runner.configure(changed: true)
        let game = try installed(catalog), service = try make(catalog, runner, queue, clock, events)
        try await service.start(downloadWhilePlaying: false); try await service.play(game.gameID)
        _ = try await wait(service, phase: .launching)
        let ordered = await events.values
        XCTAssertEqual(Array(ordered.suffix(5)), ["pause:true", "prepare", "stage", "validate", "launch:rebuilt.exe"])
        XCTAssertEqual(try catalog.snapshot().entries.first?.installation?.launchSpec.executableRelativePath, "rebuilt.exe")
        try await service.quit()
    }
    func testPrerequisiteRetryRunsEvenAfterBottleAlreadyBecameReady() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        let game = try installed(catalog), service = try make(catalog, runner, queue, clock, events)
        await runner.configure(changed: true); await events.failPrerequisiteOnce()
        try await service.start(downloadWhilePlaying: false); try await service.play(game.gameID)
        let failed = try await wait(service, phase: .idle)
        XCTAssertEqual(failed.session?.outcome, .launchFailed)
        let before = await events.values; XCTAssertFalse(before.contains(where: { $0.hasPrefix("launch:") }))
        await runner.configure(changed: false)
        try await service.play(game.gameID)
        _ = try await wait(service, phase: .launching)
        let checks = await events.prerequisiteChecks; XCTAssertEqual(checks, 2)
        try await service.quit()
    }

    func testInterruptedSourcePreparationRetriesAfterSessionAndCatalogRestart() async throws {
        for step in ["stage", "validate", "acknowledge"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Playden-source-recovery-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appendingPathComponent("catalog.sqlite").path
            let catalog = try CatalogStore(path: path), clock = TestClock(), events = Events(), runner = Runner(events)
            let game = try installed(catalog), first = try make(catalog, runner, Queue(events), clock, events)
            await runner.configure(changed: true); await events.failPreparationOnce(step)
            try await first.start(downloadWhilePlaying: false); try await first.play(game.gameID)
            let failed = try await wait(first, phase: .idle)
            XCTAssertEqual(failed.session?.outcome, .launchFailed)
            let pending = await events.preparationPending; XCTAssertTrue(pending)
            let before = await events.values; XCTAssertFalse(before.contains(where: { $0.hasPrefix("launch:") }))
            XCTAssertEqual(try catalog.snapshot().entries.first?.installation?.launchSpec.executableRelativePath,
                           step == "acknowledge" ? "rebuilt.exe" : "game.exe")
            try await first.shutdown()
            let reopened = try CatalogStore(path: path), recoveredRunner = Runner(events)
            let second = try make(reopened, recoveredRunner, Queue(events), clock, events)
            try await second.start(downloadWhilePlaying: false); try await second.play(game.gameID)
            _ = try await wait(second, phase: .launching)
            let ready = await events.preparationPending; XCTAssertFalse(ready)
            XCTAssertEqual(try reopened.snapshot().entries.first?.installation?.launchSpec.executableRelativePath, "rebuilt.exe")
            try await second.quit()
            try await second.play(game.gameID)
            _ = try await wait(second, phase: .launching)
            let after = await events.values
            XCTAssertEqual(after.filter { $0 == "stage" }.count, 2, "Completed source staging should not repeat on ordinary launches")
            try await second.quit(); try await second.shutdown()
        }
    }

    func testPendingPublicationCanRebuildRecipeButCannotLaunchOrGoOfflineBeforeRecovery() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        let game = try installed(catalog), cloud = SessionCloud(catalog, events)
        let mapping = try Content(gameID: game.gameID, events: events).saveMapping(XCTUnwrap(game.plan))
        var operation = try catalog.beginCloudSync(installation: game, accountKey: "fixture-account", mapping: mapping)
        let remote = CloudFileList(gameID: game.gameID, accountKey: "fixture-account", revision: 1, files: [])
        let plan = CloudSyncPlan(gameID: game.gameID, installationID: game.id, accountKey: "fixture-account",
            remoteRevision: 1, decisions: [], requiresAccountConfirmation: false)
        operation = try catalog.stageCloudSync(operation, plan: plan, remote: remote, localSnapshotID: UUID(), remoteSnapshotID: UUID())
        operation = try catalog.markCloudApplying(operation)
        await runner.configure(changed: true); await cloud.configure(before: .conflict)
        let service = try make(catalog, runner, queue, clock, events, cloud: cloud)
        try await service.start(downloadWhilePlaying: false)
        try await service.play(game.gameID)
        let waiting = try await wait(service, phase: .awaitingCloud)
        XCTAssertFalse(waiting.cloudStatus?.canPlayOffline ?? true)
        XCTAssertEqual(try catalog.snapshot().entries.first?.installation?.launchSpec.executableRelativePath, "rebuilt.exe")
        let firstEvents = await events.values
        XCTAssertTrue(firstEvents.contains("stage")); XCTAssertTrue(firstEvents.contains("validate"))
        XCTAssertFalse(firstEvents.contains(where: { $0.hasPrefix("launch:") }))
        do { try await service.playOffline(); XCTFail("Launched through incomplete local recovery") } catch {}
        await cloud.configure()
        try await service.retryCloud()
        _ = try await wait(service, phase: .launching)
        let ordered = await events.values
        XCTAssertLessThan(try XCTUnwrap(ordered.firstIndex(of: "cloud:local-recovery")), try XCTUnwrap(ordered.firstIndex(of: "launch:rebuilt.exe")))
        try await service.quit()
    }

    func testChangedRecoveryMappingCannotPrepareRuntime() async throws {
        let catalog = try CatalogStore(), clock = TestClock(), events = Events(), runner = Runner(events), queue = Queue(events)
        let game = try installed(catalog), cloud = SessionCloud(catalog, events)
        var operation = try catalog.beginCloudSync(installation: game, accountKey: "fixture-account", mapping: .init())
        let remote = CloudFileList(gameID: game.gameID, accountKey: "fixture-account", revision: 1, files: [])
        let plan = CloudSyncPlan(gameID: game.gameID, installationID: game.id, accountKey: "fixture-account",
            remoteRevision: 1, decisions: [], requiresAccountConfirmation: false)
        operation = try catalog.stageCloudSync(operation, plan: plan, remote: remote, localSnapshotID: UUID(), remoteSnapshotID: UUID())
        _ = try catalog.markCloudApplying(operation)
        let service = try make(catalog, runner, queue, clock, events, cloud: cloud)
        try await service.start(downloadWhilePlaying: false)
        do { try await service.play(game.gameID); XCTFail("Prepared a runtime using a different save mapping") }
        catch let failure as OperationFailure { XCTAssertTrue(failure.reason.contains("original save mapping")) }
        let ordered = await events.values
        XCTAssertFalse(ordered.contains("prepare"))
        XCTAssertTrue(try catalog.unfinishedSessions().isEmpty)
        try await service.shutdown()
    }
}
