import XCTest
import CryptoKit
import Synchronization
import Domain
@testable import Runner

private struct ToolBottle: GameBottleManaging {
    var owned = true
    var root = URL(fileURLWithPath: "/fixture/owned bottle")
    func prepare(_ bottle: GameBottle) async throws {}
    func remove(_ bottle: GameBottle) async throws {}
    func isReady(_ bottle: GameBottle) async throws -> Bool { owned }
    func ownedDirectory(_ bottle: GameBottle) async throws -> URL {
        guard owned else { throw CocoaError(.fileReadNoPermission) }
        return root
    }
}
private actor ToolCommands: CommandExecuting {
    var result: CommandResult
    var replaceRoot: URL?
    var calls: [[String]] = []
    init(_ result: CommandResult) { self.result = result }
    func configure(_ result: CommandResult, replaceRoot: URL? = nil) { self.result = result; self.replaceRoot = replaceRoot }
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        XCTAssertEqual(executable.lastPathComponent, "cxstart")
        XCTAssertEqual(timeout, 120)
        calls.append(arguments)
        if let replaceRoot {
            try FileManager.default.removeItem(at: replaceRoot)
            try FileManager.default.createDirectory(at: replaceRoot, withIntermediateDirectories: true)
        }
        return result
    }
}
final class RuntimeToolTests: XCTestCase {
    private let bottle = GameBottle(gameID: .init(source: "fixture", value: "game"), name: "gn-fixture-game", ownershipToken: UUID())
    private func receiptRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrerequisiteReceipts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func prerequisite(_ id: String) -> RuntimePrerequisite {
        .init(id: id, title: "Fixture prerequisite", arguments: ["/quiet"], fingerprint: Data(repeating: UInt8(id.utf8.first!), count: 32))
    }
    func testPrerequisiteReceiptSurvivesRestartAndReplaysAfterBottleRecreation() async throws {
        let root = try receiptRoot(), commands = ToolCommands(.init(exitCode: 0, output: "ready"))
        let manager = ToolBottle(root: root), step = prerequisite("first"), exe = root.appendingPathComponent("fixture.exe")
        try await CrossOverTools(manager: manager, commands: commands).preparePrerequisite(step, executable: exe, in: bottle)
        let reopened = CrossOverTools(manager: manager, commands: commands)
        let ready = try await reopened.prerequisiteReady(step, in: bottle); XCTAssertTrue(ready)
        try await reopened.preparePrerequisite(step, executable: exe, in: bottle)
        let once = await commands.calls.count; XCTAssertEqual(once, 1)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missing = try await reopened.prerequisiteReady(step, in: bottle); XCTAssertFalse(missing)
        try await reopened.preparePrerequisite(step, executable: exe, in: bottle)
        let twice = await commands.calls.count; XCTAssertEqual(twice, 2)
    }
    func testPrerequisiteFailureKeepsCompletedStepsAndRejectsForeignReceipt() async throws {
        let root = try receiptRoot(), commands = ToolCommands(.init(exitCode: 0, output: "ready"))
        let tools = CrossOverTools(manager: ToolBottle(root: root), commands: commands), exe = root.appendingPathComponent("fixture.exe")
        try await tools.preparePrerequisite(prerequisite("first"), executable: exe, in: bottle)
        await commands.configure(.init(exitCode: 1, output: "failure"))
        do { try await tools.preparePrerequisite(prerequisite("second"), executable: exe, in: bottle); XCTFail("Failure recorded as ready") } catch {}
        let firstReady = try await tools.prerequisiteReady(prerequisite("first"), in: bottle)
        let secondReady = try await tools.prerequisiteReady(prerequisite("second"), in: bottle)
        XCTAssertTrue(firstReady); XCTAssertFalse(secondReady)
        await commands.configure(.init(exitCode: 0, output: "ready"))
        try await tools.preparePrerequisite(prerequisite("second"), executable: exe, in: bottle)
        let foreign = GameBottle(gameID: bottle.gameID, name: bottle.name, ownershipToken: UUID())
        do { _ = try await tools.prerequisiteReady(prerequisite("first"), in: foreign); XCTFail("Foreign ownership accepted") } catch {}
        let calls = await commands.calls.count; XCTAssertEqual(calls, 3)
    }
    func testRuntimeReplacedDuringPrerequisiteCannotReceiveCompletionReceipt() async throws {
        let root = try receiptRoot(), commands = ToolCommands(.init(exitCode: 0, output: "ready"))
        await commands.configure(.init(exitCode: 0, output: "ready"), replaceRoot: root)
        let tools = CrossOverTools(manager: ToolBottle(root: root), commands: commands)
        do { try await tools.preparePrerequisite(prerequisite("first"), executable: root.appendingPathComponent("fixture.exe"), in: bottle); XCTFail("Replaced runtime was marked ready") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".bigscreen-prerequisites.json").path))
    }
    func testRealGamePrerequisitesWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["BIGSCREEN_PREREQUISITES"] else {
            throw XCTSkip("Opt in with a bundled prerequisites folder; only disposable copies and a bottle are used")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("BigScreen-prerequisites-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: work)
        defer { try? FileManager.default.removeItem(at: work) }
        let id = GameID(source: "probe", value: UUID().uuidString.lowercased())
        let bottle = GameBottle(gameID: id, name: CrossOverGameBottles.name(for: id), ownershipToken: UUID())
        let manager = CrossOverGameBottles()
        do {
            try await manager.prepare(bottle)
            let directory = try await manager.ownedDirectory(bottle)
            let components = ["msvcr100.dll", "d3dx9_43.dll", "d3dx11_43.dll"]
            func component(_ name: String) -> Data? { try? Data(contentsOf: directory.appendingPathComponent("drive_c/windows/syswow64/" + name)) }
            let before = Dictionary(uniqueKeysWithValues: components.map { ($0, component($0).map { Data(SHA256.hash(data: $0)) }) })
            let tools = CrossOverTools(manager: manager), commands = Mutex<[DiagnosticCommand]>([])
            let steps = [("vcredist_x86_vs2008sp1.exe", ["/q", "/norestart"]),
                         ("vcredist_x86_vs2010sp1.exe", ["/q", "/norestart"]),
                         ("directx_Jun2010_redist/DXSETUP.exe", ["/silent"])]
            var prerequisites: [RuntimePrerequisite] = []
            for (file, arguments) in steps {
                let executable = work.appendingPathComponent(file)
                let step = RuntimePrerequisite(id: file, title: file, arguments: arguments,
                    fingerprint: Data(SHA256.hash(data: try Data(contentsOf: executable))))
                prerequisites.append(step)
                try await DiagnosticOutputContext.$sink.withValue({ value in commands.withLock { $0.append(value) } }) {
                    try await tools.preparePrerequisite(step, executable: executable, in: bottle)
                }
                let ready = try await tools.prerequisiteReady(step, in: bottle); XCTAssertTrue(ready)
            }
            XCTAssertEqual(commands.withLock { $0.count }, 3)
            XCTAssertTrue(commands.withLock { $0.allSatisfy { $0.exitCode == 0 && !$0.timedOut && !$0.cancelled } })
            let reopened = CrossOverTools(manager: manager)
            for (index, step) in prerequisites.enumerated() {
                try await DiagnosticOutputContext.$sink.withValue({ value in commands.withLock { $0.append(value) } }) {
                    try await reopened.preparePrerequisite(step, executable: work.appendingPathComponent(steps[index].0), in: bottle)
                }
            }
            XCTAssertEqual(commands.withLock { $0.count }, 3, "Completed prerequisites must not execute again")
            for name in components {
                let data = try XCTUnwrap(component(name)), digest = Data(SHA256.hash(data: data))
                XCTAssertNotEqual(digest, before[name] ?? nil, name + " was not installed")
                print("Installed prerequisite component: \(name), bytes=\(data.count), sha256=\(digest.map { String(format: "%02x", $0) }.joined())")
            }
            let assembly = directory.appendingPathComponent("drive_c/windows/winsxs")
            let files = FileManager.default.enumerator(at: assembly, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            XCTAssertTrue(files.contains { $0.path.lowercased().contains("microsoft.vc90.crt") && $0.lastPathComponent.lowercased() == "msvcr90.dll" })
            try await manager.remove(bottle)
        } catch { try? await manager.remove(bottle); throw error }
    }
    func testToolUsesVerifiedBottleAndLiteralArguments() async throws {
        let commands = ToolCommands(.init(exitCode: 0, output: "prepared"))
        let tool = CrossOverTools(manager: ToolBottle(), commands: commands)
        try await tool.runTool(executable: URL(fileURLWithPath: "/fixture/tool.exe"), arguments: ["C:\\two words\\file.exe", "$(literal)"], in: bottle)
        let calls = await commands.calls
        XCTAssertEqual(calls, [["--bottle", "/fixture/owned bottle", "--no-gui", "--wait-children", "/fixture/tool.exe", "C:\\two words\\file.exe", "$(literal)"]])
    }
    func testUnownedBottleNeverExecutesTool() async throws {
        let commands = ToolCommands(.init(exitCode: 0, output: ""))
        do {
            try await CrossOverTools(manager: ToolBottle(owned: false), commands: commands)
                .runTool(executable: URL(fileURLWithPath: "/fixture/tool.exe"), arguments: [], in: bottle)
            XCTFail("An unowned runtime was accepted")
        } catch {}
        let calls = await commands.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testToolFailureTimeoutAndCancellationRemainActionable() async throws {
        for result in [CommandResult(exitCode: 1, output: "unpacker failed"),
                       .init(exitCode: 0, output: "still running", timedOut: true),
                       .init(exitCode: 0, output: "late result", cancelled: true)] {
            do {
                try await CrossOverTools(manager: ToolBottle(), commands: ToolCommands(result))
                    .runTool(executable: URL(fileURLWithPath: "/fixture/tool.exe"), arguments: [], in: bottle)
                XCTFail("Unsuccessful tool result accepted")
            } catch is CancellationError { XCTAssertTrue(result.cancelled) }
            catch let failure as OperationFailure {
                XCTAssertEqual(failure.stage, "Prepare executable")
                XCTAssertEqual(failure.output, result.output)
                XCTAssertTrue(failure.reason.lowercased().contains("retry"))
            }
        }
    }
}
