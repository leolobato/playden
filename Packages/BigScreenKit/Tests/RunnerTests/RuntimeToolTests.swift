import XCTest
import Domain
@testable import Runner

private struct ToolBottle: GameBottleManaging {
    var owned = true
    func prepare(_ bottle: GameBottle) async throws {}
    func remove(_ bottle: GameBottle) async throws {}
    func isReady(_ bottle: GameBottle) async throws -> Bool { owned }
    func ownedDirectory(_ bottle: GameBottle) async throws -> URL {
        guard owned else { throw CocoaError(.fileReadNoPermission) }
        return URL(fileURLWithPath: "/fixture/owned bottle")
    }
}
private actor ToolCommands: CommandExecuting {
    let result: CommandResult
    var calls: [[String]] = []
    init(_ result: CommandResult) { self.result = result }
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        XCTAssertEqual(executable.lastPathComponent, "cxstart")
        XCTAssertEqual(timeout, 120)
        calls.append(arguments); return result
    }
}
final class RuntimeToolTests: XCTestCase {
    private let bottle = GameBottle(gameID: .init(source: "fixture", value: "game"), name: "gn-fixture-game", ownershipToken: UUID())
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
