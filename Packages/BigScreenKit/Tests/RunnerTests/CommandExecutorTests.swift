import XCTest
import Runner

final class CommandExecutorTests: XCTestCase {
    func testArgumentsAreLiteralAndOutputIsCollected() async throws {
        let result = try await CommandExecutor().run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", "a space; $(not-a-command)"], timeout: 3)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "a space; $(not-a-command)")
        XCTAssertFalse(result.timedOut)
    }
    func testTimeoutKillsAGroupThatIgnoresTermination() async throws {
        let start = ContinuousClock.now
        let result = try await CommandExecutor().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; sleep 60 & wait"], timeout: 0.1)
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
    }
    func testCancellationReapsTheCommand() async throws {
        let task = Task { try await CommandExecutor().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], timeout: 90) }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.timedOut)
    }
    func testOutputFloodIsBoundedAndCannotPreventTimeout() async throws {
        let result = try await CommandExecutor().run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: ["output"], timeout: 0.1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThanOrEqual(result.output.utf8.count, 256 * 1024)
    }
    func testMissingExecutableFailsBeforeWaiting() async {
        do { _ = try await CommandExecutor().run(executable: URL(fileURLWithPath: "/bigscreen-missing-tool"), arguments: [], timeout: 60); XCTFail("Missing tool must fail") }
        catch { XCTAssertTrue(error is POSIXError) }
    }
}
