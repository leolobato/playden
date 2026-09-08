import XCTest
import Runner
import Domain
import Synchronization

final class CommandExecutorTests: XCTestCase {
    func testConcurrentDiagnosticScopesKeepSuccessAndFailureOutputSeparate() async throws {
        let first = Mutex<[DiagnosticCommand]>([]), second = Mutex<[DiagnosticCommand]>([])
        let one = Task {
            try await DiagnosticOutputContext.$sink.withValue({ command in first.withLock { $0.append(command) } }) {
                try await CommandExecutor().run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", "first output"], timeout: 3)
            }
        }
        let two = Task {
            try await DiagnosticOutputContext.$sink.withValue({ command in second.withLock { $0.append(command) } }) {
                try await CommandExecutor().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'second output\\n'; printf 'password=EXAMPLE_SECRET\\n' >&2; exit 7"], timeout: 3)
            }
        }
        let success = try await one.value, failure = try await two.value
        XCTAssertEqual(success.exitCode, 0); XCTAssertEqual(failure.exitCode, 7)
        XCTAssertEqual(first.withLock { $0.count }, 1); XCTAssertEqual(second.withLock { $0.count }, 1)
        XCTAssertEqual(first.withLock { $0.first?.output }, "first output")
        XCTAssertTrue(second.withLock { $0.first?.output.contains("second output") == true })
        XCTAssertFalse(second.withLock { $0.first?.output.contains("EXAMPLE_SECRET") == true })
        XCTAssertNil(DiagnosticOutputContext.sink, "A finished task must not leak its operation scope")
    }
    func testDiagnosticReportsTimeoutAndSpawnFailureWithoutChangingResult() async throws {
        let commands = Mutex<[DiagnosticCommand]>([])
        try await DiagnosticOutputContext.$sink.withValue({ command in commands.withLock { $0.append(command) } }) {
            let result = try await CommandExecutor().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], timeout: 0.05)
            XCTAssertTrue(result.timedOut)
            do { _ = try await CommandExecutor().run(executable: URL(fileURLWithPath: "/missing-diagnostic-test-tool"), arguments: [], timeout: 1); XCTFail("Must retain spawn failure") }
            catch { XCTAssertTrue(error is POSIXError) }
        }
        XCTAssertTrue(commands.withLock { $0[0].timedOut }); XCTAssertNil(commands.withLock { $0[1].exitCode })
    }
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
