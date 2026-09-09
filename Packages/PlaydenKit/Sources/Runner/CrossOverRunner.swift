import Foundation
import Darwin
import Domain

/// One owned bottle at a time. Observation belongs to this service, independently of UI streams.
public actor CrossOverRunner: GameRunner {
    private let application: URL
    private let bottles: URL
    private let manager: any GameBottleManaging
    private let inspector: any RuntimeInspecting
    private let launcher: any GameProcessLaunching
    private let commands: any CommandExecuting
    private let displayHelper: URL?
    private let displayTarget: @Sendable () async throws -> GameDisplayTarget?
    private let audioDeviceUID: @Sendable () async throws -> String?
    private let runtimeSettings: @Sendable (GameID) async throws -> RuntimeSettings
    private var starting = false
    private var active: RunningGame?
    private var child: (any GameProcess)?
    private var worker: Task<Void, Never>?
    private var latest: [UUID: RunSnapshot] = [:]
    private var observers: [UUID: [UUID: AsyncStream<RunSnapshot>.Continuation]] = [:]
    public init(application: URL = URL(fileURLWithPath: "/Applications/CrossOver.app"),
                bottles: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossOver/Bottles"),
                manager: any GameBottleManaging = CrossOverGameBottles(), inspector: any RuntimeInspecting = RuntimeProcessInspector(),
                launcher: any GameProcessLaunching = GameProcessLauncher(), commands: any CommandExecuting = CommandExecutor(),
                displayHelper: URL? = nil, displayTarget: @escaping @Sendable () async throws -> GameDisplayTarget? = { nil },
                audioDeviceUID: @escaping @Sendable () async throws -> String? = { nil },
                runtimeSettings: @escaping @Sendable (GameID) async throws -> RuntimeSettings = { _ in .playdenDefault }) {
        self.application = application; self.bottles = bottles; self.manager = manager; self.inspector = inspector
        self.launcher = launcher; self.commands = commands
        self.displayHelper = displayHelper; self.displayTarget = displayTarget; self.audioDeviceUID = audioDeviceUID; self.runtimeSettings = runtimeSettings
    }
    @discardableResult public func prepare(_ bottle: GameBottle) async throws -> Bool {
        guard !starting, active == nil else { throw failure("Prepare game", "Quit the current game before preparing another game.") }
        starting = true; defer { starting = false }
        let observations = try inspector.inspect(bottle: prefix(bottle))
        guard !observations.processes.contains(where: { $0.kind == .game }) else { throw failure("Prepare game", "This game's bottle already has an application running.") }
        let ready = (try? await manager.isReady(bottle)) == true
        try await manager.prepare(bottle)
        let pending = try await manager.requiresSourcePreparation(bottle)
        return !ready || pending
    }
    public func completePreparation(_ bottle: GameBottle) async throws {
        guard !starting, active == nil else { throw failure("Prepare game", "Quit the current game before completing preparation.") }
        starting = true; defer { starting = false }
        try await manager.completeSourcePreparation(bottle)
    }
    public func launch(_ spec: LaunchSpec, in bottle: GameBottle, directory: URL) async throws -> RunningGame {
        guard !starting, active == nil else { throw failure("Launch game", "Quit the current game before starting another game.") }
        starting = true; defer { starting = false }
        guard try await manager.isReady(bottle) else { throw failure("Launch game", "The game's runtime needs to be prepared again.") }
        guard try await !manager.requiresSourcePreparation(bottle) else { throw failure("Launch game", "The game's preparation has not finished. Retry to continue.") }
        let prefix = try prefix(bottle)
        var baseline = try inspector.inspect(bottle: prefix)
        guard !baseline.processes.contains(where: { $0.kind == .game }) else { throw failure("Launch game", "This game's bottle already has an application running.") }
        let target = try await displayTarget()
        let audioUID = try await audioDeviceUID()
        guard audioUID.map({ !$0.isEmpty && $0.utf16.count < 440 && !$0.utf8.contains(0) && !$0.contains("\\") }) ?? true else {
            throw failure("Launch game", "The preferred audio device is invalid. Choose it again in Settings → Audio.")
        }
        let settings = try await runtimeSettings(bottle.gameID)
        let spec = try RuntimeMechanisms.effectiveSpec(spec, settings: settings)
        let useHelper = displayHelper != nil || target != nil || audioUID != nil
        let plainArguments = try Self.arguments(spec, bottle: prefix, directory: directory, winver: RuntimeMechanisms.winver(settings))
        let input = try useHelper ? GameDisplayTarget.launchInput(display: target, executable: plainArguments[plainArguments.count - spec.arguments.count - 1], arguments: spec.arguments) : nil
        let arguments = try Self.arguments(spec, bottle: prefix, directory: directory, winver: RuntimeMechanisms.winver(settings), display: target, helper: displayHelper, forceHelper: useHelper)
        try verifyOwnership(bottle, at: prefix)
        try await applyRuntimeSettings(settings, bottle: bottle, prefix: prefix, knownProcesses: baseline.processes)
        baseline = try inspector.inspect(bottle: prefix)
        guard baseline.processes.isEmpty else {
            throw failure("Apply game settings", "The game runtime is still busy. Close its other applications and retry.")
        }
        try Task.checkCancellation()
        let process = try launcher.start(executable: tool("cxstart"), arguments: arguments, environment: spec.environment.merging(audioUID.map { ["PLAYDEN_AUDIO_DEVICE_UID": $0] } ?? [:]) { _, preferred in preferred }, input: input)
        let run = RunningGame(bottle: bottle, launcher: process.identity)
        active = run; child = process; latest[run.id] = .init(run: run, processes: baseline.processes)
        worker = Task { await self.watch(run, process: process) }
        return run
    }
    /// Settings are applied only at launch, after ownership and executable validation.
    /// Restart the owned idle runtime so WineBus and the bottle configuration reload before the
    /// game starts.
    private func applyRuntimeSettings(_ settings: RuntimeSettings, bottle: GameBottle, prefix: URL, knownProcesses: [RuntimeProcess]) async throws {
        var knownPIDs = Set(knownProcesses.map { $0.identity.pid })
        func requireIdle() throws {
            try verifyOwnership(bottle, at: prefix)
            let current = try inspector.inspect(bottle: prefix)
            guard current.unreadablePIDs.isDisjoint(with: knownPIDs), !current.processes.contains(where: { $0.kind == .game }) else {
                throw failure("Apply game settings", "Close this game's other applications before changing game settings.")
            }
            knownPIDs.formUnion(current.processes.map { $0.identity.pid })
        }
        try requireIdle()
        _ = try RuntimeMechanisms.rewriteBottleEnvironment(at: prefix.appendingPathComponent("cxbottle.conf"), values: RuntimeMechanisms.bottleEnvironment(settings))
        let script = prefix.appendingPathComponent(".playden-settings.reg")
        try RuntimeMechanisms.registryData(settings).write(to: script, options: .atomic)
        let imported = try await commands.run(executable: tool("cxstart"), arguments: [
            "--bottle", prefix.path, "--no-gui", "--wait-children", "reg.exe", "import",
            "Z:" + script.path.replacingOccurrences(of: "/", with: "\\")
        ], timeout: 30)
        try settingsCommandSucceeded(imported)
        try requireIdle()
        for flag in ["-k", "-w"] {
            try Task.checkCancellation()
            let result = try await commands.run(executable: tool("wine"), arguments: [
                "--bottle", prefix.path, "--ux-app", "wineserver", flag
            ], timeout: 15)
            try settingsCommandSucceeded(result)
        }
    }
    private func settingsCommandSucceeded(_ result: CommandResult) throws {
        if result.cancelled || Task.isCancelled { throw CancellationError() }
        guard !result.timedOut, result.exitCode == 0 else {
            throw failure("Apply game settings", "Game settings could not be applied. Retry the launch.", output: result.output)
        }
    }
    public func observe(_ run: RunningGame) -> AsyncStream<RunSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { stream in
            guard let snapshot = latest[run.id], snapshot.run == run else {
                stream.yield(.init(run: run, phase: .exited, failure: failure("Observe game", "This play session is no longer tracked."))); stream.finish(); return
            }
            stream.yield(snapshot)
            if snapshot.phase == .exited { stream.finish(); return }
            observers[run.id, default: [:]][id] = stream
            stream.onTermination = { @Sendable _ in Task { await self.removeObserver(run.id, id: id) } }
        }
    }
    public func recover(_ saved: RunSnapshot) throws -> RunSnapshot {
        guard !starting, active == nil else { throw failure("Recover game", "Another game is already being tracked.") }
        let prefix = try prefix(saved.run.bottle)
        try verifyOwnership(saved.run.bottle, at: prefix)
        let current = try inspector.inspect(bottle: prefix)
        let knownGames = Set(saved.processes.filter { $0.kind == .game }.map(\.identity))
        let liveGame = current.processes.contains { $0.kind == .game && knownGames.contains($0.identity) }
        let liveLauncher = inspector.identity(of: saved.run.launcher.pid) == saved.run.launcher
        var snapshot = saved
        snapshot.output = DiagnosticRedactor.redact(saved.output)
        let previousServer = saved.processes.first(where: { $0.kind == .server })
        let serverMatches = previousServer.map { old in current.processes.contains { $0.identity == old.identity && $0.kind == .server } } ?? true
        guard saved.phase != .exited, serverMatches, liveGame || liveLauncher else {
            if saved.processes.contains(where: { current.unreadablePIDs.contains($0.identity.pid) }) || current.unreadablePIDs.contains(saved.run.launcher.pid) {
                throw failure("Recover game", "The previous game could not be checked yet. Try again.")
            }
            snapshot.phase = .exited
            // A durably observed exit can outlive the launcher while post-exit Cloud sync is
            // pending. Preserve that result; only an unobserved exit has an unknown status.
            snapshot.exitCode = saved.phase == .exited ? saved.exitCode : nil
            latest[saved.run.id] = snapshot; return snapshot
        }
        snapshot.processes = current.processes
        snapshot.window = current.windows.first
        snapshot.hadWindow = saved.hadWindow || snapshot.window != nil
        snapshot.phase = saved.phase == .stopping ? .stopping : snapshot.hadWindow ? .running : .launching
        let process = RecoveredGameProcess(identity: saved.run.launcher, output: saved.output, inspector: inspector)
        active = saved.run; child = process; latest[saved.run.id] = snapshot
        worker = Task { await self.watch(saved.run, process: process) }
        return snapshot
    }
    public func terminate(_ run: RunningGame, force: Bool) async throws {
        guard active == run, var snapshot = latest[run.id], snapshot.phase != .exited else { return }
        // Recheck the ownership receipt and process birth times immediately before a scoped command.
        let prefix = try prefix(run.bottle)
        try verifyOwnership(run.bottle, at: prefix)
        let current = try inspector.inspect(bottle: prefix)
        if let server = snapshot.processes.first(where: { $0.kind == .server }),
           !current.processes.contains(where: { $0.identity == server.identity && $0.kind == .server }) {
            if current.unreadablePIDs.contains(server.identity.pid) { throw failure("Quit game", "The game process could not be checked. Try again.") }
            return
        }
        snapshot.phase = .stopping; snapshot.forced = snapshot.forced || force; latest[run.id] = snapshot; publish(snapshot)
        if force {
            child?.signalGroup(SIGTERM)
            let result = try await commands.run(executable: tool("wine"), arguments: ["--bottle", prefix.path, "--ux-app", "wineserver", "-k"], timeout: 10)
            if !result.timedOut && result.exitCode != 0 { throw failure("Quit game", "The game's runtime could not be stopped.", output: result.output) }
            if active == run { child?.signalGroup(SIGTERM) }
        } else {
            // WM_QUERYENDSESSION/WM_ENDSESSION lets applications save or refuse closure. The
            // session service owns the ten-second deadline and explicit force escalation.
            let result = try await commands.run(executable: tool("wine"), arguments: ["--bottle", prefix.path, "--wl-app", "wineboot.exe", "--", "--end-session", "--shutdown"], timeout: 10)
            if !result.timedOut && result.exitCode != 0 && active == run { throw failure("Quit game", "The game did not accept the close request.", output: result.output) }
        }
    }
    private func watch(_ run: RunningGame, process: any GameProcess) async {
        // An idle wineserver in the pre-launch baseline may expire while Wine starts a new
        // one. Bind server lifetime only after the game has opened a window.
        var server = latest[run.id]?.hadWindow == true ? latest[run.id]?.processes.first(where: { $0.kind == .server })?.identity : nil
        var emptySince: ContinuousClock.Instant?
        while active == run {
            let poll = process.poll()
            do {
                let observation = try inspector.inspect(bottle: prefix(run.bottle))
                guard var snapshot = latest[run.id] else { return }
                if snapshot.failure?.stage == "Observe game" { snapshot.failure = nil }
                var processes = observation.processes
                for previous in snapshot.processes where !processes.contains(where: { $0.identity.pid == previous.identity.pid }) {
                    // A kernel prefix scan can briefly omit a live Wine process.
                    // Keep an already attributed process while its birth identity still matches;
                    // a missing prefix is not exit evidence and must not abort a live launch.
                    if observation.unreadablePIDs.contains(previous.identity.pid) || inspector.identity(of: previous.identity.pid) == previous.identity {
                        processes.append(previous)
                    }
                }
                let games = processes.filter { $0.kind == .game }
                if (snapshot.hadWindow || !observation.windows.isEmpty) && server == nil { server = processes.first(where: { $0.kind == .server })?.identity }
                let serverGone = server.map { expected in !processes.contains { $0.identity == expected } } ?? false
                snapshot.processes = processes; snapshot.output = DiagnosticRedactor.redact(poll.output)
                snapshot.window = observation.windows.first
                if snapshot.window != nil { snapshot.hadWindow = true; if snapshot.phase != .stopping { snapshot.phase = .running } }
                // Before the first window, Wine bootstrap processes can look like applications
                // and disappear again. The live launcher still owns startup in that interval.
                let empty = games.isEmpty && (snapshot.hadWindow || poll.exited)
                if empty { if emptySince == nil { emptySince = .now } } else { emptySince = nil }
                // A launcher may hand off to a child. A short empty transition must not end it;
                // lingering system services must not keep a finished game alive indefinitely.
                if (serverGone && snapshot.hadWindow) || emptySince.map({ $0.duration(to: .now) >= .milliseconds(600) }) == true {
                    snapshot.phase = .exited; snapshot.exitCode = poll.exitCode
                    if !snapshot.hadWindow && !snapshot.forced {
                        snapshot.failure = failure("Launch game", "The game exited before opening a window.", output: poll.output)
                    }
                    finish(snapshot, process: process); return
                }
                latest[run.id] = snapshot; publish(snapshot)
            } catch {
                // Keep observing the same run after a transient kernel/window-query failure.
                if var snapshot = latest[run.id] {
                    snapshot.failure = failure("Observe game", "Game observation is temporarily unavailable. Quit controls remain available.", output: error.localizedDescription)
                    latest[run.id] = snapshot; publish(snapshot)
                }
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }
    private func finish(_ snapshot: RunSnapshot, process: any GameProcess) {
        latest[snapshot.run.id] = snapshot; publish(snapshot)
        for stream in observers.removeValue(forKey: snapshot.run.id)?.values ?? [:].values { stream.finish() }
        active = nil; child = nil; worker = nil
        // Reap a lingering launcher without signalling another bottle or a reused PID.
        Task.detached {
            if !process.poll().exited { process.signalGroup(SIGTERM) }
            for _ in 0..<20 {
                if process.poll().exited { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            process.signalGroup(SIGKILL)
            for _ in 0..<20 {
                if process.poll().exited { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if latest.count > 8, let oldest = latest.values.filter({ $0.phase == .exited && $0.run.id != snapshot.run.id }).min(by: { $0.run.startedAt < $1.run.startedAt }) { latest[oldest.run.id] = nil }
    }
    private func removeObserver(_ runID: UUID, id: UUID) { observers[runID]?[id] = nil }
    private func publish(_ snapshot: RunSnapshot) { for stream in observers[snapshot.run.id]?.values ?? [:].values { stream.yield(snapshot) } }
    private func tool(_ name: String) -> URL { application.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/" + name) }
    private func prefix(_ bottle: GameBottle) throws -> URL {
        guard bottle.name == CrossOverGameBottles.name(for: bottle.gameID) else { throw failure("Game runtime", "The saved bottle does not match this game.") }
        return bottles.appendingPathComponent(bottle.name)
    }
    private func verifyOwnership(_ bottle: GameBottle, at prefix: URL) throws {
        struct Receipt: Decodable { let bottle: GameBottle }
        var info = stat()
        let marker = prefix.appendingPathComponent(".playden-game-owner.json")
        guard lstat(prefix.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              lstat(marker.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: marker)).bottle == bottle else { throw failure("Game runtime", "The game's runtime ownership could not be verified.") }
    }
    static func arguments(_ spec: LaunchSpec, bottle: URL, directory: URL, winver: String? = nil, display: GameDisplayTarget? = nil, helper: URL? = nil, forceHelper: Bool = false) throws -> [String] {
        func path(_ value: String, folder: Bool) throws -> URL {
            let normalized = value.replacingOccurrences(of: "\\", with: "/")
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains(":"), !normalized.utf8.contains(0),
                  (normalized == "." && folder) || components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CocoaError(.fileReadInvalidFileName) }
            let result = directory.appendingPathComponent(normalized).standardizedFileURL
            let resolved = result.resolvingSymlinksInPath(), root = directory.resolvingSymlinksInPath()
            guard resolved == root || resolved.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
            let values = try result.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            guard folder ? values.isDirectory == true : values.isRegularFile == true else { throw CocoaError(.fileReadNoSuchFile) }
            return result
        }
        guard spec.environment.keys.allSatisfy({ key in
            key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil &&
            !["HOME", "PATH", "WINEPREFIX", "CX_BOTTLE", "CX_ROOT", "XDG_CONFIG_HOME", "CX_DIRECT_DESKTOP", "CODEX_HOME", "PLAYDEN_AUDIO_DEVICE_UID"].contains(key) && !key.hasPrefix("DYLD_")
        }), spec.dllOverrides.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.*-]+=(n|b|d|n,b|b,n)$"#, options: .regularExpression) != nil }) else { throw CocoaError(.fileReadCorruptFile) }
        let executable = try path(spec.executableRelativePath, folder: false), working = try path(spec.workingDirectoryRelativePath, folder: true)
        func windows(_ path: URL) -> String { "Z:" + path.path.replacingOccurrences(of: "/", with: "\\") }
        var result = ["--bottle", bottle.path, "--no-gui"] + (winver.map { ["--winver", $0] } ?? []) + ["--no-convert", "--wait-children", "--workdir", windows(working)]
        for value in spec.dllOverrides { result += ["--dll", value] }
        if display != nil || forceHelper {
            guard let helper, helper.isFileURL, !helper.path.utf8.contains(0),
                  try helper.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw OperationFailure(stage: "Launch game", reason: "The display helper is missing. Rebuild or reinstall Playden.", output: "")
            }
            _ = try display?.arguments()
            return result + [windows(helper)]
        }
        return result + [windows(executable)] + spec.arguments
    }
    private func failure(_ stage: String, _ reason: String, output: String = "") -> OperationFailure { .init(stage: stage, reason: reason, output: output) }
}
