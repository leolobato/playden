import XCTest
import Domain
@testable import Runner

final class GameDisplayTests: XCTestCase {
    func testMonitorGeometryPreservesDisplaysLeftAndAbovePrimary() throws {
        let target = GameDisplayTarget(bounds: CGRect(x: -1920, y: -300, width: 1920, height: 1080),
                                       primaryBounds: CGRect(x: 0, y: 0, width: 3008, height: 1692))
        XCTAssertEqual(try target.arguments(), ["-1920", "-300", "1920", "1080", "3008", "1692"])
        XCTAssertThrowsError(try GameDisplayTarget(bounds: .zero, primaryBounds: target.primaryBounds).arguments())
        XCTAssertThrowsError(try GameDisplayTarget(bounds: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10), primaryBounds: target.primaryBounds).arguments())
    }
    func testDisplayWrapperPreservesGameArgumentsWorkingDirectoryAndOverrides() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Display wrapper \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("A game.exe"), helper = root.appendingPathComponent("PlaydenDisplay.exe")
        try Data().write(to: executable); try Data().write(to: helper)
        let spec = LaunchSpec(executableRelativePath: executable.lastPathComponent,
            arguments: ["Unicode 🎮", "", "quoted \"value\"", "trailing\\", "$(touch bad)", "--bottle", "other"], dllOverrides: ["steam_api=n,b"])
        let target = GameDisplayTarget(bounds: CGRect(x: 3008, y: 458, width: 1512, height: 982), primaryBounds: CGRect(x: 0, y: 0, width: 3008, height: 1692))
        let plain = try CrossOverRunner.arguments(spec, bottle: root, directory: root)
        let wrapped = try CrossOverRunner.arguments(spec, bottle: root, directory: root, display: target, helper: helper)
        let offset = try XCTUnwrap(wrapped.firstIndex(of: "Z:" + helper.path.replacingOccurrences(of: "/", with: "\\")))
        XCTAssertEqual(Array(wrapped.prefix(offset)), Array(plain.prefix(offset)))
        XCTAssertEqual(wrapped.count, offset + 1)
        // Arbitrary game arguments must bypass cxstart's quoting entirely.
        XCTAssertFalse(wrapped.contains("Unicode 🎮"))
        let input = try target.launchInput(executable: "Z:\\A game.exe", arguments: spec.arguments)
        XCTAssertEqual(Array(input.prefix(4)), [0xc0, 0x0b, 0, 0]) // x = 3008, little endian
        XCTAssertNotNil(input.range(of: Data("Unicode 🎮".utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })))
        XCTAssertThrowsError(try target.launchInput(executable: "game.exe", arguments: ["embedded\0null"]))
        XCTAssertThrowsError(try CrossOverRunner.arguments(spec, bottle: root, directory: root, display: target))
        XCTAssertThrowsError(try CrossOverRunner.arguments(.init(executableRelativePath: "../escape.exe"), bottle: root, directory: root, display: target, helper: helper))
    }
    func testChildReceivesLargeInputWithoutBlockingLaunch() async throws {
        let input = Data(repeating: 65, count: 200_000)
        let process = try GameProcessLauncher().start(executable: URL(fileURLWithPath: "/usr/bin/wc"),
            arguments: ["-c"], environment: [:], input: input)
        var result = process.poll()
        let deadline = Date().addingTimeInterval(3)
        while !result.exited && Date() < deadline { try await Task.sleep(for: .milliseconds(10)); result = process.poll() }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "200000")
    }
    func testChildDoesNotInheritUnrelatedAppDescriptors() async throws {
        let source = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(source, 0)
        defer { close(source) }
        let descriptor = fcntl(source, F_DUPFD, 200)
        XCTAssertGreaterThanOrEqual(descriptor, 200)
        defer { close(descriptor) }
        let process = try GameProcessLauncher().start(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "test ! -e /dev/fd/\(descriptor)"], environment: [:])
        var result = process.poll()
        let deadline = Date().addingTimeInterval(3)
        while !result.exited && Date() < deadline { try await Task.sleep(for: .milliseconds(10)); result = process.poll() }
        XCTAssertEqual(result.exitCode, 0)
    }
}
