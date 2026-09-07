import XCTest
import Domain
@testable import Runner

private struct ReadyGame: GameBottleManaging {
    func prepare(_ bottle: GameBottle) async throws {}
    func isReady(_ bottle: GameBottle) async throws -> Bool { true }
    func remove(_ bottle: GameBottle) async throws {}
}
private final class ProcessFixture: GameProcess, GameProcessLaunching, @unchecked Sendable {
    let identity = ProcessIdentity(pid: 100, startSeconds: 1, startMicroseconds: 0)
    let lock = NSLock()
    var status: Int32? = nil
    var signals: [Int32] = []
    func start(executable: URL, arguments: [String], environment: [String: String], input: Data?) throws -> any GameProcess { self }
    func poll() -> GameProcessPoll { lock.withLock { .init(exitCode: status, output: "access_token=fixture-secret") } }
    func signalGroup(_ signal: Int32) { lock.withLock { signals.append(signal); status = 0 } }
    func exit(_ code: Int32) { lock.withLock { status = code } }
}
private final class InspectionFixture: RuntimeInspecting, @unchecked Sendable {
    let lock = NSLock()
    var value = RuntimeObservation(processes: [])
    var unavailable = false
    var omittedButAlive: [ProcessIdentity] = []
    func inspect(bottle: URL) throws -> RuntimeObservation { try lock.withLock { if unavailable { throw CocoaError(.fileReadUnknown) }; return value } }
    func identity(of pid: Int32) -> ProcessIdentity? { lock.withLock { value.processes.first { $0.identity.pid == pid }?.identity ?? omittedButAlive.first { $0.pid == pid } } }
    func omitLive(_ identities: [ProcessIdentity]) { lock.withLock { omittedButAlive = identities; value = .init(processes: []) } }
    func set(_ value: RuntimeObservation, unavailable: Bool = false) { lock.withLock { self.value = value; self.unavailable = unavailable } }
}
private actor StopCommands: CommandExecuting {
    var calls: [[String]] = []
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandResult { calls.append(arguments); return .init(exitCode: 0, output: "") }
}
final class CrossOverRunnerTests: XCTestCase {
    private func fixture() throws -> (URL, GameBottle) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BigScreen-run-\(UUID().uuidString)")
        let bottle = GameBottle(gameID: .init(source: "fixture", value: "one"), name: "gn-fixture-one", ownershipToken: UUID())
        try FileManager.default.createDirectory(at: root.appendingPathComponent(bottle.name), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: root.appendingPathComponent("game.exe"))
        struct Receipt: Encodable { let bottle: GameBottle }
        try JSONEncoder().encode(Receipt(bottle: bottle)).write(to: root.appendingPathComponent(bottle.name + "/.bigscreen-game-owner.json"))
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, bottle)
    }
    private func process(_ pid: Int32, _ kind: RuntimeProcessKind, birth: UInt64 = 1) -> RuntimeProcess {
        .init(identity: .init(pid: pid, startSeconds: birth, startMicroseconds: 0), kind: kind, executable: kind == .game ? "game.exe" : "service")
    }
    private func wait(_ runner: CrossOverRunner, _ run: RunningGame, phase: RunPhase) async throws -> RunSnapshot {
        try await withThrowingTaskGroup(of: RunSnapshot.self) { group in
            group.addTask { for await value in await runner.observe(run) where value.phase == phase { return value }; throw CocoaError(.fileReadUnknown) }
            group.addTask { try await Task.sleep(for: .seconds(3)); throw CocoaError(.fileReadUnknown) }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    func testWrapperExitDoesNotEndLiveGameAndServicesDoNotKeepItAlive() async throws {
        let (root, bottle) = try fixture(), inspector = InspectionFixture(), child = ProcessFixture()
        let runner = CrossOverRunner(bottles: root, manager: ReadyGame(), inspector: inspector, launcher: child)
        let run = try await runner.launch(.init(executableRelativePath: "game.exe"), in: bottle, directory: root)
        let game = process(101, .game), server = process(102, .server)
        inspector.set(.init(processes: [game, server], windows: [.init(id: 1, process: game.identity)]))
        child.exit(0)
        _ = try await wait(runner, run, phase: .running)
        try await Task.sleep(for: .milliseconds(800))
        let stillRunning = try await wait(runner, run, phase: .running)
        XCTAssertTrue(stillRunning.hadWindow)
        inspector.set(.init(processes: [server, process(103, .service)]))
        let exited = try await wait(runner, run, phase: .exited)
        XCTAssertEqual(exited.exitCode, 0)
        XCTAssertNil(exited.failure)
    }
    func testUnreadableProcessIsNotTreatedAsExitAndReusedServerIsNotSignalled() async throws {
        let (root, bottle) = try fixture(), inspector = InspectionFixture(), child = ProcessFixture(), commands = StopCommands()
        let runner = CrossOverRunner(bottles: root, manager: ReadyGame(), inspector: inspector, launcher: child, commands: commands)
        let run = try await runner.launch(.init(executableRelativePath: "game.exe"), in: bottle, directory: root)
        let game = process(101, .game), server = process(102, .server)
        inspector.set(.init(processes: [game, server], windows: [.init(id: 1, process: game.identity)]))
        _ = try await wait(runner, run, phase: .running)
        inspector.set(.init(processes: [server], unreadablePIDs: [101]))
        try await Task.sleep(for: .milliseconds(800))
        _ = try await wait(runner, run, phase: .running)
        inspector.set(.init(processes: [game, process(102, .server, birth: 2)]))
        try await runner.terminate(run, force: true)
        let calls = await commands.calls
        XCTAssertTrue(calls.isEmpty)
        _ = try await wait(runner, run, phase: .exited)
    }
    func testEarlyExitReportsLaunchFailureAndSingleGameIsEnforced() async throws {
        let (root, bottle) = try fixture(), inspector = InspectionFixture(), child = ProcessFixture()
        let runner = CrossOverRunner(bottles: root, manager: ReadyGame(), inspector: inspector, launcher: child)
        let run = try await runner.launch(.init(executableRelativePath: "game.exe"), in: bottle, directory: root)
        do { _ = try await runner.launch(.init(executableRelativePath: "game.exe"), in: bottle, directory: root); XCTFail("Second game accepted") } catch {}
        child.exit(9)
        let exited = try await wait(runner, run, phase: .exited)
        XCTAssertFalse(exited.hadWindow)
        XCTAssertEqual(exited.exitCode, 9)
        XCTAssertEqual(exited.failure?.stage, "Launch game")
        XCTAssertFalse(exited.output.contains("fixture-secret"))
    }
    func testMissingPrefixObservationDoesNotEndProcessesWithMatchingBirthIdentity() async throws {
        let (root, bottle) = try fixture(), inspector = InspectionFixture(), child = ProcessFixture()
        let runner = CrossOverRunner(bottles: root, manager: ReadyGame(), inspector: inspector, launcher: child)
        let run = try await runner.launch(.init(executableRelativePath: "game.exe"), in: bottle, directory: root)
        let game = process(101, .game), server = process(102, .server)
        inspector.set(.init(processes: [game, server], windows: [.init(id: 1, process: game.identity)]))
        _ = try await wait(runner, run, phase: .running)
        inspector.omitLive([game.identity, server.identity])
        try await Task.sleep(for: .milliseconds(800))
        let running = try await wait(runner, run, phase: .running)
        XCTAssertEqual(Set(running.processes.map(\.identity)), Set([game.identity, server.identity]))
        inspector.omitLive([]); child.exit(0)
        _ = try await wait(runner, run, phase: .exited)
    }
    func testBootstrapApplicationExitDoesNotAbortALiveLauncherBeforeItsFirstWindow() async throws {
        let (root, bottle) = try fixture(), inspector = InspectionFixture(), child = ProcessFixture()
        let runner = CrossOverRunner(bottles: root, manager: ReadyGame(), inspector: inspector, launcher: child)
        let run = try await runner.launch(.init(executableRelativePath: "game.exe"), in: bottle, directory: root)
        inspector.set(.init(processes: [process(103, .game), process(102, .server)]))
        try await Task.sleep(for: .milliseconds(200))
        inspector.set(.init(processes: [process(104, .wrapper)]))
        try await Task.sleep(for: .milliseconds(800))
        _ = try await wait(runner, run, phase: .launching)
        child.exit(9)
        let exited = try await wait(runner, run, phase: .exited)
        XCTAssertEqual(exited.exitCode, 9)
        XCTAssertEqual(exited.failure?.stage, "Launch game")
    }
    func testAnIdleBaselineServerCanExpireBeforeTheNewGameStarts() async throws {
        let (root, bottle) = try fixture(), inspector = InspectionFixture(), child = ProcessFixture()
        inspector.set(.init(processes: [process(102, .server)]))
        let runner = CrossOverRunner(bottles: root, manager: ReadyGame(), inspector: inspector, launcher: child)
        let run = try await runner.launch(.init(executableRelativePath: "game.exe"), in: bottle, directory: root)
        inspector.set(.init(processes: [process(104, .wrapper), process(102, .server)]))
        try await Task.sleep(for: .milliseconds(200))
        inspector.set(.init(processes: [process(104, .wrapper)]))
        try await Task.sleep(for: .milliseconds(800))
        _ = try await wait(runner, run, phase: .launching)
        let game = process(101, .game), newServer = process(102, .server, birth: 2)
        inspector.set(.init(processes: [game, newServer], windows: [.init(id: 10, process: game.identity)]))
        _ = try await wait(runner, run, phase: .running)
        child.exit(0); inspector.set(.init(processes: [newServer]))
        let exited = try await wait(runner, run, phase: .exited)
        XCTAssertTrue(exited.hadWindow)
        XCTAssertEqual(exited.exitCode, 0)
    }
    func testRecoveryUsesBirthIdentityAndDoesNotInventAnExitStatus() async throws {
        let (root, bottle) = try fixture(), inspector = InspectionFixture()
        let game = process(101, .game), server = process(102, .server)
        let run = RunningGame(bottle: bottle, launcher: .init(pid: 100, startSeconds: 1, startMicroseconds: 0))
        let snapshot = RunSnapshot(run: run, phase: .running, processes: [game, server], hadWindow: true)
        inspector.set(.init(processes: [game, server], windows: [.init(id: 1, process: game.identity)]))
        let runner = CrossOverRunner(bottles: root, manager: ReadyGame(), inspector: inspector)
        let recovered = try await runner.recover(snapshot)
        XCTAssertEqual(recovered.phase, .running)
        inspector.set(.init(processes: [server]))
        let exited = try await wait(runner, run, phase: .exited)
        XCTAssertNil(exited.exitCode)
        let next = CrossOverRunner(bottles: root, manager: ReadyGame(), inspector: inspector)
        inspector.set(.init(processes: [process(101, .game, birth: 2), server]))
        let reused = try await next.recover(snapshot)
        XCTAssertEqual(reused.phase, .exited)
    }
    func testLaunchArgumentsStayLiteralAndCannotEscapeOwnedPaths() throws {
        let (root, bottle) = try fixture()
        let spec = LaunchSpec(executableRelativePath: "game.exe", arguments: ["$(touch bad)", "space value", "--workdir=/tmp"], dllOverrides: ["steam_api=n,b"])
        let args = try CrossOverRunner.arguments(spec, bottle: root.appendingPathComponent(bottle.name), directory: root)
        XCTAssertEqual(Array(args.suffix(3)), spec.arguments)
        XCTAssertTrue(args.contains("--no-convert"))
        XCTAssertThrowsError(try CrossOverRunner.arguments(.init(executableRelativePath: "../game.exe"), bottle: root, directory: root))
        XCTAssertThrowsError(try CrossOverRunner.arguments(.init(executableRelativePath: "game.exe", environment: ["WINEPREFIX": "/tmp/other"]), bottle: root, directory: root))
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try Data().write(to: external); defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.exe"), withDestinationURL: external)
        XCTAssertThrowsError(try CrossOverRunner.arguments(.init(executableRelativePath: "linked.exe"), bottle: root, directory: root))
    }
    func testKernelArgumentDecoderRetainsOnlyBottleIdentityAndRejectsTruncation() {
        var argc: Int32 = 2
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/host/path\0\0C:\\windows\\system32\\services.exe\0arg\0WINEPREFIX=/bottle\0SECRET_TOKEN=not-retained\0".utf8)
        let parsed = RuntimeProcessInspector.decodeArguments(bytes)
        XCTAssertEqual(parsed?.argv.count, 2)
        XCTAssertEqual(parsed?.environment, ["WINEPREFIX": "/bottle"])
        XCTAssertNil(RuntimeProcessInspector.decodeArguments(Array(bytes.prefix(9))))
        XCTAssertEqual(RuntimeProcessInspector.kind("C:\\windows\\system32\\services.exe"), .service)
        XCTAssertEqual(RuntimeProcessInspector.kind("Z:\\games\\services.exe"), .game)
        XCTAssertEqual(RuntimeProcessInspector.kind("wineloader"), .wrapper)
        XCTAssertEqual(RuntimeProcessInspector.kind("/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wineloader"), .wrapper)
    }
    func testRealChildExitCodeAndBoundedRedactedOutput() async throws {
        let child = try GameProcessLauncher().start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "/usr/bin/head -c 400000 /dev/zero | /usr/bin/tr '\\000' x; printf '\\naccess_token=fixture-secret\\n'; exit 7"], environment: [:])
        let deadline = Date().addingTimeInterval(3)
        var result = child.poll()
        while result.exitCode == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)); result = child.poll() }
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertLessThanOrEqual(result.output.utf8.count, 256 * 1024)
        XCTAssertTrue(result.output.contains("[REDACTED]"))
        XCTAssertFalse(result.output.contains("fixture-secret"))
    }
}

extension CrossOverRunnerTests {
    func testWindowAttributionIncludesExclusiveFullscreenButExcludesUnownedWindows() {
        let identity = ProcessIdentity(pid: 100, startSeconds: 1, startMicroseconds: 0)
        let service = ProcessIdentity(pid: 101, startSeconds: 1, startMicroseconds: 0)
        let processes = [RuntimeProcess(identity: identity, kind: .game, executable: "game.exe"), RuntimeProcess(identity: service, kind: .service, executable: "explorer.exe")]
        func window(_ id: UInt32, pid: Int32 = 100, layer: Int = 0, height: Double = 1080) -> [String: Any] {
            ["kCGWindowOwnerPID": pid, "kCGWindowNumber": id, "kCGWindowLayer": layer, "kCGWindowBounds": ["Width": 1920.0, "Height": height]]
        }
        var fullscreen = window(2, layer: 26); fullscreen["kCGWindowIsOnscreen"] = true
        let windows = RuntimeProcessInspector.windows([window(1), fullscreen, window(3, pid: 101), window(4, pid: 999), window(5, height: 33)], processes: processes)
        XCTAssertEqual(windows, [.init(id: 2, process: identity), .init(id: 1, process: identity)])
    }
}
