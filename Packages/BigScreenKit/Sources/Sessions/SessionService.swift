import Foundation
import Domain
import Catalog
import Installs

public enum SessionPhase: String, Sendable { case idle, preparing, awaitingCloud, syncingSaves, launching, running, stopping }
public struct SessionSnapshot: Sendable {
    public var phase: SessionPhase
    public var game: SourceGameRecord?
    public var session: PlaySessionRecord?
    public var failure: OperationFailure?
    public var cloudStatus: CloudSyncStatus?
    public init(phase: SessionPhase = .idle, game: SourceGameRecord? = nil, session: PlaySessionRecord? = nil, failure: OperationFailure? = nil, cloudStatus: CloudSyncStatus? = nil) {
        self.phase = phase; self.game = game; self.session = session; self.failure = failure; self.cloudStatus = cloudStatus
    }
}
public protocol SessionClock: Sendable {
    var wallTime: Date { get }
    var uptime: TimeInterval { get }
}
public struct SystemSessionClock: SessionClock {
    public init() {}
    public var wallTime: Date { .now }
    public var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
public protocol SessionManaging: Sendable {
    func start(downloadWhilePlaying: Bool) async throws
    func updates() async -> AsyncStream<SessionSnapshot>
    func play(_ gameID: GameID) async throws
    func retryCloud(authorization: CloudSyncAuthorization?) async throws
    func playOffline() async throws
    func quit() async throws
    func setDownloadWhilePlaying(_ enabled: Bool) async throws
    func shutdown() async throws
}
/// Coordinates source preparation, runner lifetime and catalog checkpoints. UI subscriptions do
/// not own the session. Recovery finishes before the install queue is allowed to start.
public actor SessionService: SessionManaging {
    private let catalog: CatalogStore
    private let sources: [String: any GameSource]
    private let runner: any GameRunner
    private let queue: any InstallQueuing
    private let storage: any InstallStorageManaging
    private let clock: any SessionClock
    private let quitGrace: Duration
    private let stopTimeout: Duration
    private let cloud: (any CloudSyncManaging)?
    private var finishing = false
    private var started = false, starting = false, shuttingDown = false
    private var downloadWhilePlaying = false
    private var value = SessionSnapshot()
    private var active: PlaySessionRecord?
    private var worker: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<SessionSnapshot>.Continuation] = [:]
    private var playAnchor: TimeInterval?
    private var baseSeconds: Int64 = 0
    private var lastSave: TimeInterval = 0, lastPublish: TimeInterval = 0
    public init(catalog: CatalogStore, sources: [any GameSource], runner: any GameRunner, queue: any InstallQueuing,
                storage: any InstallStorageManaging = InstallStorage(), clock: any SessionClock = SystemSessionClock(),
                quitGrace: Duration = .seconds(10), stopTimeout: Duration = .seconds(10),
                cloud: (any CloudSyncManaging)? = nil) throws {
        self.catalog = catalog; self.runner = runner; self.queue = queue; self.storage = storage; self.clock = clock
        self.quitGrace = quitGrace; self.stopTimeout = stopTimeout
        self.cloud = cloud
        var registry: [String: any GameSource] = [:]
        for source in sources { guard registry.updateValue(source, forKey: source.id) == nil else { throw SourceFailure.unavailable } }
        self.sources = registry
    }
    public func updates() -> AsyncStream<SessionSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { stream in
            observers[id] = stream; stream.yield(value)
            stream.onTermination = { @Sendable _ in Task { await self.removeObserver(id) } }
        }
    }
    public func start(downloadWhilePlaying: Bool) async throws {
        guard !started else { return }
        guard !starting else { throw issue("Recover session", "Session recovery is already in progress.") }
        starting = true; defer { starting = false }
        self.downloadWhilePlaying = downloadWhilePlaying
        let unfinished = try catalog.unfinishedSessions().sorted { $0.startedAt < $1.startedAt }
        // Persist the pause before recovery; a previously user-paused job keeps that reason too.
        try await queue.setGameplayPaused(true)
        for var saved in unfinished {
            if active?.id == saved.id { continue }
            let entry = try catalog.snapshot().entries.first { $0.id == saved.gameID }
            if let runtime = saved.runtime {
                let recovered = try await DiagnosticOutputContext.$sink.withValue(catalog.diagnosticSink(for: saved.id)) {
                    try await runner.recover(runtime)
                }
                saved.runtime = recovered
                if recovered.phase != .exited {
                    guard active == nil else { throw issue("Recover session", "More than one running session needs attention before downloads can resume.") }
                    active = saved; baseSeconds = saved.playedSeconds
                    playAnchor = recovered.hadWindow ? clock.uptime : nil
                    value = .init(phase: phase(recovered), game: entry?.source, session: saved)
                    worker = Task { await self.observe(recovered.run) }
                    publish()
                    try catalog.saveSession(saved)
                    continue
                }
            } else if let installed = entry?.installation {
                // An interrupted pre-launch record has no PID receipt. The runner refuses to
                // prepare a bottle with a live game, so uncertainty cannot restart downloads.
                _ = try await DiagnosticOutputContext.$sink.withValue(catalog.diagnosticSink(for: saved.id)) {
                    try await runner.prepare(bottle(installed))
                }
            }
            if saved.runtime?.phase == .exited, cloud != nil {
                // Keep the recovered session reservation until its post-exit Cloud work is durable.
                // An interrupted worker's claim can be released only after runner recovery above.
                try catalog.saveSession(saved)
                try await cloud?.recoverInterruptedOperations()
                guard active == nil else { throw issue("Recover session", "Another game is still running. Save recovery must wait for it to close.") }
                active = saved; baseSeconds = saved.playedSeconds; playAnchor = nil
                value = .init(phase: .syncingSaves, game: entry?.source, session: saved)
                await finish(outcome: outcome(saved.runtime!), failure: saved.runtime?.failure)
                guard active == nil else { throw issue("Recover session", "The recovered session checkpoint could not be finalized.") }
                continue
            }
            saved.endedAt = max(clock.wallTime, saved.lastCheckpointAt)
            saved.lastCheckpointAt = saved.endedAt!; saved.outcome = saved.runtime?.forced == true ? .forced : .interrupted
            try catalog.saveSession(saved)
        }
        try await cloud?.recoverInterruptedOperations()
        try await queue.setGameplayPaused(active != nil && !downloadWhilePlaying)
        try await queue.start(); started = true
    }
    public func play(_ gameID: GameID) async throws {
        guard started, !shuttingDown else { throw issue("Launch game", "Session recovery must finish before a game can start.") }
        guard active == nil else { throw issue("Launch game", "Quit the current game before starting another one.") }
        guard let installation = try catalog.snapshot().entries.first(where: { $0.id == gameID })?.installation else {
            throw issue("Launch game", "This game is not installed. Install it from your library first.")
        }
        var session = PlaySessionRecord(gameID: gameID, bottleID: installation.bottleID, startedAt: clock.wallTime)
        session.lastCheckpointAt = session.startedAt
        try catalog.saveSession(session)
        active = session; value = .init(phase: .preparing, game: installation.game, session: session)
        playAnchor = nil; baseSeconds = 0; lastSave = clock.uptime; lastPublish = clock.uptime
        publish()
        worker = Task { await self.launch(installation) }
    }
    public func retryCloud(authorization: CloudSyncAuthorization? = nil) async throws {
        let installed = try waitingInstallation()
        value.phase = .preparing; value.failure = nil; publish()
        worker = Task { await self.launch(installed, authorization: authorization) }
    }
    public func playOffline() async throws {
        let installed = try waitingInstallation()
        guard value.cloudStatus?.canPlayOffline == true else { throw issue("Cloud saves", "Recover this save sync before playing offline.") }
        value.phase = .preparing; value.failure = nil; publish()
        worker = Task { await self.launch(installed, offline: true) }
    }
    private func waitingInstallation() throws -> InstallationRecord {
        guard started, !shuttingDown, value.phase == .awaitingCloud, let active, active.runtime == nil,
              let installed = try catalog.snapshot().entries.first(where: { $0.id == active.gameID })?.installation else {
            throw issue("Cloud saves", "There is no game waiting for a save-sync choice.")
        }
        return installed
    }
    private func launch(_ original: InstallationRecord, offline: Bool = false, authorization: CloudSyncAuthorization? = nil) async {
        guard let id = active?.id else { return }
        await DiagnosticOutputContext.$sink.withValue(catalog.diagnosticSink(for: id)) {
            await launchTracked(original, offline: offline, authorization: authorization)
        }
    }
    private func launchTracked(_ original: InstallationRecord, offline: Bool, authorization: CloudSyncAuthorization?) async {
        do {
            try await queue.setGameplayPaused(!downloadWhilePlaying)
            try Task.checkCancellation()
            let directory = try await storage.directory(original.location, gameID: original.gameID, owner: original.ownershipToken)
            var installed = original
            if let id = active?.id { catalog.captureDiagnosticEvent(for: id, message: "Preparing runtime", at: clock.wallTime) }
            if try await runner.prepare(bottle(installed)) {
                guard let source = sources[installed.gameID.source], let plan = installed.plan else { throw issue("Prepare game", "The saved install plan is unavailable. Verify or reinstall this game.") }
                let installer = try source.installer(for: installed.game)
                let staging = try await installer.postInstall(plan, at: directory)
                installed.launchSpec = try await installer.validate(plan, at: directory, staging: staging)
                installed.staging = staging; try catalog.saveInstallation(installed)
            }
            try Task.checkCancellation()
            if let id = active?.id {
                catalog.captureDiagnosticEvent(for: id, message: offline ? "Cloud before launch · offline choice" : "Cloud before launch · checking", at: clock.wallTime)
            }
            if !offline, let cloud, let session = active, let mapping = try mapping(installed) {
                let result = await cloud.synchronize(installed, mapping: mapping,
                    preparingSessionID: session.id, authorization: authorization)
                value.cloudStatus = result
                catalog.captureDiagnosticEvent(for: session.id, message: "Cloud before launch · \(result.state.rawValue)", at: clock.wallTime)
                try Task.checkCancellation()
                if result.state != .upToDate {
                    value.phase = .awaitingCloud; worker = nil; publish(); return
                }
            } else if !offline, let id = active?.id {
                catalog.captureDiagnosticEvent(for: id, message: "Cloud before launch · not configured for this game", at: clock.wallTime)
            }
            try Task.checkCancellation()
            let run = try await runner.launch(installed.launchSpec, in: bottle(installed), directory: directory)
            guard var session = active else { try await runner.terminate(run, force: true); return }
            session.runtime = .init(run: run)
            session.lastCheckpointAt = max(clock.wallTime, session.lastCheckpointAt)
            active = session
            // Keep observing even if a checkpoint fails; a database error must not orphan a game.
            do { try catalog.saveSession(session) }
            catch { value.failure = issue("Save session", "The process checkpoint could not be saved. Your game is still being tracked.") }
            value.phase = .launching; value.session = session; publish()
            worker = Task { await self.observe(run) }
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            await finish(outcome: cancelled ? .interrupted : .launchFailed,
                         failure: cancelled ? nil : error as? OperationFailure ?? issue("Launch game", error.localizedDescription))
        }
    }
    private func observe(_ run: RunningGame) async {
        for await runtime in await runner.observe(run) {
            guard var session = active, session.runtime?.run.id == run.id else { return }
            let changed = session.runtime?.phase != runtime.phase || session.runtime?.window != runtime.window || session.runtime?.processes != runtime.processes
            if runtime.hadWindow && playAnchor == nil { playAnchor = clock.uptime }
            session.runtime = runtime
            session.playedSeconds = elapsed()
            session.lastCheckpointAt = max(clock.wallTime, session.lastCheckpointAt)
            active = session; value.phase = phase(runtime); value.session = session
            if runtime.phase == .exited {
                await finish(outcome: outcome(runtime), failure: runtime.failure)
                return
            }
            if changed || clock.uptime - lastSave >= 5 {
                do { try catalog.saveSession(session); lastSave = clock.uptime }
                catch { value.failure = issue("Save session", "Playtime could not be saved. Your game is still being tracked.") }
            }
            if changed || clock.uptime - lastPublish >= 1 { publish(); lastPublish = clock.uptime }
        }
    }
    public func quit() async throws {
        guard let id = active?.id else { return }
        try await DiagnosticOutputContext.$sink.withValue(catalog.diagnosticSink(for: id)) {
            try await quitTracked()
        }
    }
    private func quitTracked() async throws {
        guard var session = active else { return }
        if finishing {
            let syncing = worker
            syncing?.cancel(); await syncing?.value
            if active != nil { throw issue("Cloud saves", "Save sync is still stopping. Retry after its checkpoint finishes.") }
            return
        }
        if let runtime = session.runtime, runtime.phase == .exited, session.endedAt == nil {
            await finish(outcome: outcome(runtime), failure: value.failure)
            if active != nil { throw issue("Save session", "The exited game's save checkpoint still needs recovery. Try again.") }
            return
        }
        if let outcome = session.outcome, session.endedAt != nil {
            await finish(outcome: outcome, failure: value.failure)
            if active != nil { throw issue("Save session", "The final checkpoint still could not be saved. Free space and try again.") }
            return
        }
        value.phase = .stopping; publish()
        if session.runtime == nil {
            let preparing = worker
            preparing?.cancel(); await preparing?.value
            guard let remaining = active else { return }
            session = remaining
            if session.runtime == nil {
                await finish(outcome: .interrupted, failure: nil)
                if active != nil { throw issue("Save session", "Game preparation could not be finalized. Try again.") }
                return
            }
        }
        guard let run = session.runtime?.run else { throw issue("Quit game", "Game preparation has not finished stopping. Try again.") }
        let start = ContinuousClock.now
        do { try await runner.terminate(run, force: false) }
        catch { value.failure = error as? OperationFailure ?? issue("Quit game", error.localizedDescription); publish() }
        let remaining = quitGrace - start.duration(to: .now)
        if remaining > .zero {
            let deadline = ContinuousClock.now.advanced(by: remaining)
            while active?.id == session.id && active?.runtime?.phase != .exited && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        }
        if active?.id == session.id && active?.runtime?.phase != .exited { try await runner.terminate(run, force: true) }
        let deadline = ContinuousClock.now.advanced(by: stopTimeout)
        while active?.id == session.id && active?.runtime?.phase != .exited && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if active?.id == session.id, active?.runtime?.phase == .exited {
            // The game has stopped; waiting for save sync is not a reason to force-quit it.
            let syncing = worker
            if shuttingDown { syncing?.cancel() }
            await syncing?.value
        }
        if active?.id == session.id { throw issue("Quit game", "The game has not finished stopping. Try again.") }
    }
    public func setDownloadWhilePlaying(_ enabled: Bool) async throws {
        downloadWhilePlaying = enabled
        try await queue.setGameplayPaused(active != nil && !enabled)
    }
    public func shutdown() async throws {
        shuttingDown = true
        await queue.shutdown()
        do { try await quit() }
        catch { shuttingDown = false; try? await queue.start(); throw error }
    }
    private func finish(outcome: SessionOutcome, failure: OperationFailure?) async {
        guard !finishing else { return }
        guard var session = active else { return }
        finishing = true; defer { finishing = false }
        if session.endedAt == nil, session.runtime?.phase == .exited, let cloud {
            // Persist verified exit but retain the unfinished session as the game reservation.
            // Background retries and maintenance cannot claim the files between exit and sync.
            session.playedSeconds = elapsed(); session.lastCheckpointAt = max(clock.wallTime, session.lastCheckpointAt)
            active = session; baseSeconds = session.playedSeconds; playAnchor = nil
            do {
                try catalog.saveSession(session)
                if let installed = try catalog.snapshot().entries.first(where: { $0.id == session.gameID })?.installation,
                   let mapping = try mapping(installed) {
                    value.phase = .syncingSaves; value.session = session; publish()
                    catalog.captureDiagnosticEvent(for: session.id, message: "Cloud after exit · checking", at: clock.wallTime)
                    value.cloudStatus = await cloud.synchronize(installed, mapping: mapping,
                        preparingSessionID: session.id, authorization: nil)
                    if let status = value.cloudStatus { catalog.captureDiagnosticEvent(for: session.id, message: "Cloud after exit · \(status.state.rawValue)", at: clock.wallTime) }
                }
            } catch {
                value.failure = error as? OperationFailure ?? issue("Save session", "Save recovery could not be checkpointed. Retry before leaving.")
                value.session = session; value.phase = .stopping; publish(); return
            }
        }
        if session.endedAt == nil {
            session.playedSeconds = elapsed(); session.lastCheckpointAt = max(clock.wallTime, session.lastCheckpointAt)
            session.endedAt = session.lastCheckpointAt; session.outcome = outcome
            session.failure = failure
        }
        do { try catalog.saveSession(session) }
        catch {
            active = session
            value.failure = issue("Save session", "The session ended, but its final checkpoint could not be saved. Free space and try quitting again.")
            value.session = session; value.phase = .stopping; publish(); return
        }
        active = nil; worker = nil; playAnchor = nil
        value = .init(phase: .idle, game: value.game, session: session, failure: failure, cloudStatus: value.cloudStatus)
        if !shuttingDown && !starting {
            do { try await queue.setGameplayPaused(false) }
            catch { value.failure = issue("Resume downloads", error.localizedDescription) }
        }
        publish()
    }
    private func elapsed() -> Int64 {
        guard let playAnchor else { return baseSeconds }
        let seconds = max(0, clock.uptime - playAnchor)
        guard seconds.isFinite, seconds < Double(Int64.max - baseSeconds) else { return Int64.max }
        return baseSeconds + Int64(seconds)
    }
    private func mapping(_ installed: InstallationRecord) throws -> SaveMapping? {
        guard cloud != nil else { return nil }
        guard let source = sources[installed.gameID.source], let plan = installed.plan else {
            throw issue("Cloud saves", "The installed game's save mapping is unavailable. Verify its files before syncing.")
        }
        let mapping = try source.installer(for: installed.game).saveMapping(plan)
        // Games without any declared Cloud path can still launch. The page can show unsupported
        // coverage; inventing a remote mapping here would risk syncing unrelated local files.
        return mapping.rules.contains(where: { $0.cloudPrefix != nil }) ? mapping : nil
    }
    private func outcome(_ runtime: RunSnapshot) -> SessionOutcome {
        runtime.forced ? .forced : !runtime.hadWindow ? .launchFailed : runtime.exitCode == 0 ? .clean : runtime.exitCode == nil ? .interrupted : .crash
    }
    private func bottle(_ installation: InstallationRecord) -> GameBottle { .init(gameID: installation.gameID, name: installation.bottleID, ownershipToken: installation.ownershipToken, templateVersion: installation.templateVersion) }
    private func phase(_ runtime: RunSnapshot) -> SessionPhase {
        switch runtime.phase { case .launching: .launching; case .running: .running; case .stopping: .stopping; case .exited: .idle }
    }
    private func publish() { for stream in observers.values { stream.yield(value) } }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func issue(_ stage: String, _ reason: String) -> OperationFailure { .init(stage: stage, reason: reason, output: reason) }
}
