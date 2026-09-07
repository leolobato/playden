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
    func add(_ event: String) { values.append(event) }
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
    init(_ events: Events) { self.events = events }
    func configure(changed: Bool = false, held: Bool = false, graceful: Bool = true) { self.changed = changed; self.held = held; self.graceful = graceful }
    func prepare(_ bottle: GameBottle) async throws -> Bool {
        await events.add("prepare")
        while held { try await Task.sleep(for: .milliseconds(5)) }
        return changed
    }
    func launch(_ spec: LaunchSpec, in bottle: GameBottle, directory: URL) async throws -> RunningGame {
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
    func postInstall(_ plan: InstallPlan, at directory: URL) async throws -> InstallStaging { await events.add("stage"); return .init() }
    func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging) async throws -> LaunchSpec { await events.add("validate"); return .init(executableRelativePath: "rebuilt.exe") }
    func uninstall(_ plan: InstallPlan, at directory: URL) async throws {}
}
@MainActor
final class SessionServiceTests: XCTestCase {
    private func installed(_ catalog: CatalogStore, id: String = "one") throws -> InstallationRecord {
        let game = SourceGameRecord(id: GameID(source: "fixture", value: id), title: id)
        var installation = InstallationRecord(game: game, location: .init(volumeID: "fixture", lastKnownRoot: URL(fileURLWithPath: "/fixture"), relativePath: "game"), bottleID: "gn-fixture-" + id, manifestIDs: [:], templateVersion: "1", launchSpec: .init(executableRelativePath: "game.exe"), installedBytes: 100)
        installation.plan = .init(game: game, manifestIDs: [:], estimate: .init(downloadBytes: 100, installedBytes: 100, requiredBytes: 100), launchSpec: installation.launchSpec, sourcePayload: Data())
        try catalog.saveInstallation(installation)
        return installation
    }
    private func make(_ catalog: CatalogStore, _ runner: Runner, _ queue: Queue, _ clock: TestClock, _ events: Events) throws -> SessionService {
        try SessionService(catalog: catalog, sources: [Store(events: events)], runner: runner, queue: queue, storage: Storage(), clock: clock, quitGrace: .milliseconds(20), stopTimeout: .seconds(1))
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
}
