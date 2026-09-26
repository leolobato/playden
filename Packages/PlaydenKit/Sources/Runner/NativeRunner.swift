import Foundation
import AppKit
import CoreGraphics
import Darwin
import Domain

/// Processes whose executable lives inside an app bundle, and that bundle's windows.
public protocol BundleProcessInspecting: Sendable {
    func inspect(bundle: URL) throws -> RuntimeObservation
    func identity(of pid: Int32) -> ProcessIdentity?
}
extension RuntimeProcessInspector: BundleProcessInspecting {
    public func inspect(bundle: URL) throws -> RuntimeObservation {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { throw POSIXError(.EIO) }
        var pids = [Int32](repeating: 0, count: Int(capacity) + 256)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0, count < pids.count else { throw POSIXError(.EAGAIN) }
        // Foundation's symlink resolution drops /private, but the kernel reports real paths.
        guard let real = realpath(bundle.path, nil) else { return .init(processes: []) }
        defer { free(real) }
        let root = String(cString: real) + "/"
        var processes: [RuntimeProcess] = [], unreadable = Set<Int32>()
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else {
                if kill(pid, 0) == 0 || errno == EPERM { unreadable.insert(pid) }
                continue
            }
            guard info.pbi_uid == getuid() else { continue }
            var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { unreadable.insert(pid); continue }
            let executable = String(cString: path)
            guard executable.hasPrefix(root) else { continue }
            let identity = ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
            guard self.identity(of: pid) == identity else { continue }
            processes.append(.init(identity: identity, kind: .game, executable: executable))
        }
        let values = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return .init(processes: processes, windows: Self.windows(values, processes: processes), unreadablePIDs: unreadable)
    }
}

/// Starts and stops Mac apps through Launch Services, so they activate and appear like any app.
public protocol NativeAppControlling: Sendable {
    /// Returns the process of an instance of this bundle that is already running.
    func runningInstance(of bundle: URL) async -> Int32?
    func open(_ bundle: URL, arguments: [String], environment: [String: String]) async throws -> Int32
    /// Asks the app to quit the way the Quit menu command does; the app may save or refuse.
    func requestQuit(pid: Int32) async
    func forceQuit(pid: Int32) async
    /// Whether macOS wrote a crash report for this executable since the given time.
    func crashReported(executableName: String, since: Date) async -> Bool
}
public struct WorkspaceAppController: NativeAppControlling {
    private let diagnosticReports: URL
    public init(diagnosticReports: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")) {
        self.diagnosticReports = diagnosticReports
    }
    public func runningInstance(of bundle: URL) async -> Int32? {
        let path = bundle.resolvingSymlinksInPath().path
        return await MainActor.run {
            NSWorkspace.shared.runningApplications.first { !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().path == path }?.processIdentifier
        }
    }
    public func open(_ bundle: URL, arguments: [String], environment: [String: String]) async throws -> Int32 {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.arguments = arguments
        if !environment.isEmpty { configuration.environment = environment }
        let app = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        return app.processIdentifier
    }
    public func requestQuit(pid: Int32) async {
        await MainActor.run { _ = NSRunningApplication(processIdentifier: pid)?.terminate() }
    }
    public func forceQuit(pid: Int32) async {
        let handled = await MainActor.run { NSRunningApplication(processIdentifier: pid)?.forceTerminate() ?? false }
        if !handled { kill(pid, SIGKILL) }
    }
    public func crashReported(executableName: String, since: Date) async -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(at: diagnosticReports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return names.contains { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(executableName + "-"), ["ips", "crash"].contains(url.pathExtension) else { return false }
            return ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= since
        }
    }
}

/// Runs one Mac app at a time. The bundle bounds which processes belong to the game, the way
/// a bottle prefix does for CrossOver. Observation belongs to this service, not to UI streams.
public actor NativeRunner: GameRunner {
    private let inspector: any BundleProcessInspecting
    private let apps: any NativeAppControlling
    private let exitSettle: Duration
    private var active: RunningGame?
    private var worker: Task<Void, Never>?
    private var latest: [UUID: RunSnapshot] = [:]
    private var observers: [UUID: [UUID: AsyncStream<RunSnapshot>.Continuation]] = [:]
    public init(inspector: any BundleProcessInspecting = RuntimeProcessInspector(), apps: any NativeAppControlling = WorkspaceAppController(),
                exitSettle: Duration = .milliseconds(600)) {
        self.inspector = inspector; self.apps = apps; self.exitSettle = exitSettle
    }
    /// A Mac app needs no runtime preparation.
    @discardableResult public func prepare(_ bottle: GameBottle) async throws -> Bool {
        guard active == nil else { throw failure("Prepare game", "Quit the current game before preparing another game.") }
        return false
    }
    public func launch(_ spec: LaunchSpec, in bottle: GameBottle, directory: URL) async throws -> RunningGame {
        guard active == nil else { throw failure("Launch game", "Quit the current game before starting another game.") }
        let bundle = try Self.bundle(spec, in: directory)
        let pid: Int32
        do {
            if let running = await apps.runningInstance(of: bundle) { pid = running }
            else { pid = try await apps.open(bundle, arguments: spec.arguments, environment: spec.environment) }
        } catch {
            throw failure("Launch game", "macOS couldn’t open this app.", output: error.localizedDescription)
        }
        guard let identity = inspector.identity(of: pid) else { throw failure("Launch game", "The app quit as soon as it opened.") }
        let run = RunningGame(bottle: bottle, launcher: identity,
                              native: NativeRun(bundleURL: bundle, bundleIdentifier: Bundle(url: bundle)?.bundleIdentifier))
        let snapshot = RunSnapshot(run: run, processes: [.init(identity: identity, kind: .game, executable: bundle.path)])
        active = run; latest[run.id] = snapshot
        worker = Task { await self.watch(run) }
        return run
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
        guard active == nil else { throw failure("Recover game", "Another game is already being tracked.") }
        guard let native = saved.run.native else { throw failure("Recover game", "This session was not a Mac app.") }
        let current = try inspector.inspect(bundle: native.bundleURL)
        let known = Set(saved.processes.map(\.identity) + [saved.run.launcher])
        var snapshot = saved
        guard saved.phase != .exited, current.processes.contains(where: { known.contains($0.identity) }) else {
            if known.contains(where: { current.unreadablePIDs.contains($0.pid) }) { throw failure("Recover game", "The previous game could not be checked yet. Try again.") }
            snapshot.phase = .exited
            snapshot.exitCode = saved.phase == .exited ? saved.exitCode : nil
            latest[saved.run.id] = snapshot; return snapshot
        }
        snapshot.processes = current.processes
        snapshot.window = current.windows.first
        snapshot.hadWindow = saved.hadWindow || snapshot.window != nil
        snapshot.phase = saved.phase == .stopping ? .stopping : snapshot.hadWindow ? .running : .launching
        active = saved.run; latest[saved.run.id] = snapshot
        worker = Task { await self.watch(saved.run) }
        return snapshot
    }
    public func terminate(_ run: RunningGame, force: Bool) async throws {
        guard active == run, var snapshot = latest[run.id], snapshot.phase != .exited, let native = run.native else { return }
        // Recheck birth identities immediately before signalling, so a reused PID is never touched.
        let current = try inspector.inspect(bundle: native.bundleURL)
        let targets = current.processes.filter { process in snapshot.processes.contains { $0.identity == process.identity } || process.identity == run.launcher }
        snapshot.phase = .stopping; snapshot.forced = snapshot.forced || force; latest[run.id] = snapshot; publish(snapshot)
        for process in targets {
            if force { await apps.forceQuit(pid: process.identity.pid) } else { await apps.requestQuit(pid: process.identity.pid) }
        }
    }
    private func watch(_ run: RunningGame) async {
        guard let native = run.native else { return }
        var emptySince: ContinuousClock.Instant?
        while active == run {
            do {
                let observation = try inspector.inspect(bundle: native.bundleURL)
                guard var snapshot = latest[run.id] else { return }
                if snapshot.failure?.stage == "Observe game" { snapshot.failure = nil }
                var processes = observation.processes
                // A briefly unreadable process is not evidence that it exited.
                for previous in snapshot.processes where !processes.contains(where: { $0.identity == previous.identity })
                    && observation.unreadablePIDs.contains(previous.identity.pid) {
                    processes.append(previous)
                }
                snapshot.processes = processes
                snapshot.window = observation.windows.first
                if snapshot.window != nil { snapshot.hadWindow = true; if snapshot.phase != .stopping { snapshot.phase = .running } }
                // A launcher stub may hand off to the real game; a short empty gap must not end it.
                if processes.isEmpty { if emptySince == nil { emptySince = .now } } else { emptySince = nil }
                if let emptySince, emptySince.duration(to: .now) >= exitSettle {
                    let executable = Bundle(url: native.bundleURL)?.executableURL?.lastPathComponent ?? native.bundleURL.deletingPathExtension().lastPathComponent
                    let crashed = await apps.crashReported(executableName: executable, since: run.startedAt)
                    snapshot.phase = .exited
                    snapshot.exitCode = crashed ? 1 : 0
                    if !snapshot.hadWindow && !snapshot.forced {
                        snapshot.failure = failure("Launch game", "The game quit before opening a window.")
                    }
                    finish(snapshot); return
                }
                latest[run.id] = snapshot; publish(snapshot)
            } catch {
                if var snapshot = latest[run.id] {
                    snapshot.failure = failure("Observe game", "Game observation is temporarily unavailable. Quit controls remain available.", output: error.localizedDescription)
                    latest[run.id] = snapshot; publish(snapshot)
                }
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }
    private func finish(_ snapshot: RunSnapshot) {
        latest[snapshot.run.id] = snapshot; publish(snapshot)
        for stream in observers.removeValue(forKey: snapshot.run.id)?.values ?? [:].values { stream.finish() }
        active = nil; worker = nil
        if latest.count > 8, let oldest = latest.values.filter({ $0.phase == .exited && $0.run.id != snapshot.run.id }).min(by: { $0.run.startedAt < $1.run.startedAt }) { latest[oldest.run.id] = nil }
    }
    private func removeObserver(_ runID: UUID, id: UUID) { observers[runID]?[id] = nil }
    private func publish(_ snapshot: RunSnapshot) { for stream in observers[snapshot.run.id]?.values ?? [:].values { stream.yield(snapshot) } }
    /// The launch spec names an app bundle relative to its install folder, never a path outside it.
    static func bundle(_ spec: LaunchSpec, in directory: URL) throws -> URL {
        let parts = spec.executableRelativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(".."), !spec.executableRelativePath.hasPrefix("/"),
              spec.executableRelativePath.lowercased().hasSuffix(".app") else {
            throw OperationFailure(stage: "Launch game", reason: "The saved launch entry is not a Mac app.", output: spec.executableRelativePath)
        }
        let bundle = directory.appendingPathComponent(spec.executableRelativePath).standardizedFileURL
        guard bundle.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else {
            throw OperationFailure(stage: "Launch game", reason: "The saved app is outside its folder.", output: bundle.path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundle.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OperationFailure(stage: "Launch game", reason: "The app is missing from its folder.", output: bundle.path)
        }
        return bundle
    }
    private func failure(_ stage: String, _ reason: String, output: String = "") -> OperationFailure { .init(stage: stage, reason: reason, output: output) }
}
