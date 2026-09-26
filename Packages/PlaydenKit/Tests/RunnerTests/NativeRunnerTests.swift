import XCTest
import Domain
@testable import Runner

/// A scripted process table: tests move processes and windows in and out of the bundle.
private final class FakeProcesses: BundleProcessInspecting, NativeAppControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var live: [Int32: ProcessIdentity] = [:]
    private var windows: [UInt32: Int32] = [:]
    private(set) var opened: [(URL, [String])] = []
    private(set) var quitRequests: [Int32] = []
    private(set) var forced: [Int32] = []
    var nextPID: Int32 = 500
    var alreadyRunning: Int32?
    var crashed = false
    var quitsOnRequest = true
    func start(_ pid: Int32) { lock.withLock { live[pid] = .init(pid: pid, startSeconds: UInt64(pid), startMicroseconds: 1) } }
    func stop(_ pid: Int32) { lock.withLock { live[pid] = nil; windows = windows.filter { $0.value != pid } } }
    func showWindow(_ id: UInt32, for pid: Int32) { lock.withLock { windows[id] = pid } }

    func inspect(bundle: URL) throws -> RuntimeObservation {
        lock.withLock {
            let processes = live.values.sorted { $0.pid < $1.pid }.map { RuntimeProcess(identity: $0, kind: .game, executable: bundle.path + "/Contents/MacOS/Game") }
            let shown = windows.sorted { $0.key < $1.key }.compactMap { id, pid in live[pid].map { GameWindow(id: id, process: $0) } }
            return RuntimeObservation(processes: processes, windows: shown)
        }
    }
    func identity(of pid: Int32) -> ProcessIdentity? { lock.withLock { live[pid] } }
    func runningInstance(of bundle: URL) async -> Int32? { alreadyRunning }
    func open(_ bundle: URL, arguments: [String], environment: [String: String]) async throws -> Int32 {
        let pid = nextPID
        lock.withLock { opened.append((bundle, arguments)) }
        start(pid); return pid
    }
    func requestQuit(pid: Int32) async {
        lock.withLock { quitRequests.append(pid) }
        if quitsOnRequest { stop(pid) }
    }
    func forceQuit(pid: Int32) async { lock.withLock { forced.append(pid) }; stop(pid) }
    func crashReported(executableName: String, since: Date) async -> Bool { crashed }
}

final class NativeRunnerTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeRunnerTests-\(UUID().uuidString)")
        let macOS = root.appendingPathComponent("Game.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.game", "CFBundleExecutable": "Game", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: root.appendingPathComponent("Game.app/Contents/Info.plist"))
        try Data().write(to: macOS.appendingPathComponent("Game"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private let bottle = GameBottle(gameID: GameID(source: "local", value: "game"), name: "", ownershipToken: UUID())
    private func until(_ runner: NativeRunner, _ run: RunningGame, file: StaticString = #filePath, line: UInt = #line,
                       _ condition: (RunSnapshot) -> Bool) async throws -> RunSnapshot {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        for await snapshot in await runner.observe(run) {
            if condition(snapshot) { return snapshot }
            if ContinuousClock.now > limit { break }
        }
        XCTFail("Condition not reached", file: file, line: line); throw CancellationError()
    }

    func testLaunchTracksWindowsAndCleanExit() async throws {
        let root = try folder(), processes = FakeProcesses()
        let runner = NativeRunner(inspector: processes, apps: processes, exitSettle: .milliseconds(50))
        let needsPreparation = try await runner.prepare(bottle)
        XCTAssertFalse(needsPreparation, "Mac apps need no runtime preparation")
        let run = try await runner.launch(LaunchSpec(executableRelativePath: "Game.app", arguments: ["-fullscreen"]), in: bottle, directory: root)
        XCTAssertEqual(run.native?.bundleIdentifier, "com.example.game")
        XCTAssertEqual(processes.opened.first?.1, ["-fullscreen"])
        processes.showWindow(7, for: 500)
        let running = try await until(runner, run) { $0.phase == .running }
        XCTAssertEqual(running.window?.id, 7)
        processes.stop(500)
        let exited = try await until(runner, run) { $0.phase == .exited }
        XCTAssertEqual(exited.exitCode, 0); XCTAssertTrue(exited.hadWindow); XCTAssertNil(exited.failure)
    }

    func testLauncherHandOffKeepsTheSessionUntilTheGameExits() async throws {
        let root = try folder(), processes = FakeProcesses()
        let runner = NativeRunner(inspector: processes, apps: processes, exitSettle: .milliseconds(300))
        let run = try await runner.launch(LaunchSpec(executableRelativePath: "Game.app"), in: bottle, directory: root)
        processes.stop(500)
        try await Task.sleep(for: .milliseconds(100))
        processes.start(501); processes.showWindow(9, for: 501)
        let running = try await until(runner, run) { $0.phase == .running }
        XCTAssertEqual(running.window?.process.pid, 501, "The real game behind a launcher stub is followed")
        processes.stop(501)
        _ = try await until(runner, run) { $0.phase == .exited }
    }

    func testCrashReportAndEarlyExitAreReported() async throws {
        let root = try folder(), processes = FakeProcesses()
        processes.crashed = true
        let runner = NativeRunner(inspector: processes, apps: processes, exitSettle: .milliseconds(50))
        let run = try await runner.launch(LaunchSpec(executableRelativePath: "Game.app"), in: bottle, directory: root)
        processes.stop(500)
        let exited = try await until(runner, run) { $0.phase == .exited }
        XCTAssertEqual(exited.exitCode, 1)
        XCTAssertEqual(exited.failure?.stage, "Launch game", "Quitting before any window is a launch failure")
    }

    func testAlreadyRunningAppIsAdoptedNotOpenedAgain() async throws {
        let root = try folder(), processes = FakeProcesses()
        processes.start(42); processes.alreadyRunning = 42
        let runner = NativeRunner(inspector: processes, apps: processes, exitSettle: .milliseconds(50))
        let run = try await runner.launch(LaunchSpec(executableRelativePath: "Game.app"), in: bottle, directory: root)
        XCTAssertEqual(run.launcher.pid, 42); XCTAssertTrue(processes.opened.isEmpty)
    }

    func testQuitRequestsThenForcesEveryTrackedProcess() async throws {
        let root = try folder(), processes = FakeProcesses()
        processes.quitsOnRequest = false
        let runner = NativeRunner(inspector: processes, apps: processes, exitSettle: .milliseconds(50))
        let run = try await runner.launch(LaunchSpec(executableRelativePath: "Game.app"), in: bottle, directory: root)
        processes.showWindow(3, for: 500)
        _ = try await until(runner, run) { $0.phase == .running }
        try await runner.terminate(run, force: false)
        XCTAssertEqual(processes.quitRequests, [500]); XCTAssertTrue(processes.forced.isEmpty)
        try await runner.terminate(run, force: true)
        XCTAssertEqual(processes.forced, [500])
        let exited = try await until(runner, run) { $0.phase == .exited }
        XCTAssertTrue(exited.forced)
    }

    func testRecoveryReattachesByProcessIdentityOrReportsExit() async throws {
        let root = try folder(), processes = FakeProcesses()
        let bundle = root.appendingPathComponent("Game.app")
        processes.start(77)
        let identity = try XCTUnwrap(processes.identity(of: 77))
        let run = RunningGame(bottle: bottle, launcher: identity, native: NativeRun(bundleURL: bundle, bundleIdentifier: nil))
        let saved = RunSnapshot(run: run, phase: .running, processes: [.init(identity: identity, kind: .game, executable: bundle.path)], hadWindow: true)
        let runner = NativeRunner(inspector: processes, apps: processes, exitSettle: .milliseconds(50))
        let recovered = try await runner.recover(saved)
        XCTAssertEqual(recovered.phase, .running)
        processes.stop(77)
        _ = try await until(runner, run) { $0.phase == .exited }

        let gone = try await NativeRunner(inspector: processes, apps: processes).recover(saved)
        XCTAssertEqual(gone.phase, .exited); XCTAssertNil(gone.exitCode, "An unobserved exit has no known status")
    }

    func testLaunchRejectsPathsOutsideTheFolderAndNonApps() async throws {
        let root = try folder(), processes = FakeProcesses()
        let runner = NativeRunner(inspector: processes, apps: processes)
        for path in ["../Game.app", "/Applications/Game.app", "Game.app/Contents/MacOS/Game", "Other.app"] {
            do { _ = try await runner.launch(LaunchSpec(executableRelativePath: path), in: bottle, directory: root); XCTFail(path) }
            catch let failure as OperationFailure { XCTAssertEqual(failure.stage, "Launch game") }
        }
        XCTAssertTrue(processes.opened.isEmpty)
    }
}

final class BundleProcessInspectionTests: XCTestCase {
    func testFindsRealProcessesOnlyInsideTheBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BundleInspection-\(UUID().uuidString)")
        let macOS = root.appendingPathComponent("Fixture.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let tool = macOS.appendingPathComponent("fixture")
        // A copied system binary is refused by macOS; build a tiny one the way a game ships its own.
        let source = root.appendingPathComponent("fixture.c")
        try "#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); compile.arguments = ["clang", "-o", tool.path, source.path]
        try compile.run(); compile.waitUntilExit()
        try XCTSkipUnless(compile.terminationStatus == 0, "A C compiler is needed for this fixture")
        let process = Process()
        process.executableURL = tool; process.arguments = ["30"]
        try process.run()
        addTeardownBlock { process.terminate() }
        let inspector = RuntimeProcessInspector()
        let found = try inspector.inspect(bundle: root.appendingPathComponent("Fixture.app"))
        XCTAssertEqual(found.processes.map(\.identity.pid), [process.processIdentifier])
        XCTAssertEqual(found.processes.first?.identity, inspector.identity(of: process.processIdentifier))
        let elsewhere = try inspector.inspect(bundle: root.appendingPathComponent("Other.app"))
        XCTAssertTrue(elsewhere.processes.isEmpty)
    }
}
