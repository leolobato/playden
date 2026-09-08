import XCTest
import Domain
import Runner

private actor TemplateCommands: CommandExecuting {
    let bottles: URL
    var creates = 0
    var failValidation: Bool
    init(bottles: URL, failValidation: Bool = false) { self.bottles = bottles; self.failValidation = failValidation }
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        if arguments.contains("--create") {
            creates += 1
            let name = arguments[arguments.firstIndex(of: "--bottle")! + 1]
            let description = arguments[arguments.firstIndex(of: "--description")! + 1]
            let root = bottles.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "[Bottle]\n\"Description\" = \"\(description)\"\n[EnvironmentVariables]\n\"WINEMSYNC\" = \"1\"\n\"CX_GRAPHICS_BACKEND\" = \"d3dmetal\"\n".write(to: root.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)
            return CommandResult(exitCode: 0, output: "")
        }
        if failValidation { failValidation = false; return CommandResult(exitCode: 1, output: "license expired access_token=secret") }
        return CommandResult(exitCode: 0, output: "PLAYDEN_TEMPLATE_READY\n")
    }
}
private struct RuntimeFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Playden-runtime-test-\(UUID().uuidString)")
    var application: URL { root.appendingPathComponent("CrossOver.app") }
    var bottles: URL { root.appendingPathComponent("Bottles") }
    var state: URL { root.appendingPathComponent("state") }
    init() throws {
        let bin = application.appendingPathComponent("Contents/SharedSupport/CrossOver/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bottles, withIntermediateDirectories: true)
        for name in ["cxbottle", "cxstart"] {
            let path = bin.appendingPathComponent(name)
            try Data().write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "26.2"], format: .xml, options: 0).write(to: application.appendingPathComponent("Contents/Info.plist"))
    }
    func runtime(_ commands: TemplateCommands) -> CrossOverRuntime { CrossOverRuntime(application: application, bottles: bottles, stateDirectory: state, commands: commands) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
final class CrossOverRuntimeTests: XCTestCase {
    func testTemplateOwnershipConfigurationAndRestartReuse() async throws {
        let fixture = try RuntimeFixture(); defer { fixture.remove() }
        let commands = TemplateCommands(bottles: fixture.bottles)
        let first = try await fixture.runtime(commands).prepareTemplate()
        XCTAssertTrue(first.templateReady)
        let second = fixture.runtime(commands)
        let info = await second.inspect()
        XCTAssertTrue(info.templateReady)
        _ = try await second.prepareTemplate()
        let creates = await commands.creates
        XCTAssertEqual(creates, 1)
    }
    func testExistingUnownedBottleIsNeverAdopted() async throws {
        let fixture = try RuntimeFixture(); defer { fixture.remove() }
        let folder = fixture.bottles.appendingPathComponent("playden-template-1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let commands = TemplateCommands(bottles: fixture.bottles)
        do { _ = try await fixture.runtime(commands).prepareTemplate(); XCTFail("Must reject unowned bottle") }
        catch { XCTAssertTrue((error as? OperationFailure)?.reason.contains("does not belong") == true) }
        let creates = await commands.creates
        XCTAssertEqual(creates, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".playden-owner.json").path))
    }
    func testPartialTemplateWithForeignDescriptionCannotBeClaimed() async throws {
        let fixture = try RuntimeFixture(); defer { fixture.remove() }
        let commands = TemplateCommands(bottles: fixture.bottles, failValidation: true)
        do { _ = try await fixture.runtime(commands).prepareTemplate(); XCTFail("Expected incomplete setup") } catch {}
        let folder = fixture.bottles.appendingPathComponent("playden-template-1")
        let config = folder.appendingPathComponent("cxbottle.conf")
        let text = try String(contentsOf: config, encoding: .utf8)
            .replacingOccurrences(of: "Playden managed template", with: "Other App managed template")
        try text.write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".playden-owner.json"))
        do { _ = try await fixture.runtime(commands).prepareTemplate(); XCTFail("Must reject a foreign description") }
        catch { XCTAssertTrue((error as? OperationFailure)?.reason.contains("could not be identified safely") == true) }
        let creates = await commands.creates
        XCTAssertEqual(creates, 1, "Leave the foreign template untouched")
    }
    func testLicenseFailurePersistsRedactedAndRetryDoesNotRecreate() async throws {
        let fixture = try RuntimeFixture(); defer { fixture.remove() }
        let commands = TemplateCommands(bottles: fixture.bottles, failValidation: true)
        do { _ = try await fixture.runtime(commands).prepareTemplate(); XCTFail("Validation should fail") } catch {}
        let next = fixture.runtime(commands)
        let info = await next.inspect()
        XCTAssertFalse(info.templateReady)
        XCTAssertTrue(info.failure?.reason.contains("license") == true)
        XCTAssertFalse(info.failure?.output.contains("secret") == true)
        let ready = try await next.prepareTemplate()
        XCTAssertTrue(ready.templateReady)
        let creates = await commands.creates
        XCTAssertEqual(creates, 1)
        let completed = await next.inspect()
        XCTAssertNil(completed.failure)
    }
    func testReplacedTemplateSymlinkIsRejected() async throws {
        let fixture = try RuntimeFixture(); defer { fixture.remove() }
        let commands = TemplateCommands(bottles: fixture.bottles)
        _ = try await fixture.runtime(commands).prepareTemplate()
        let folder = fixture.bottles.appendingPathComponent("playden-template-1")
        let moved = fixture.root.appendingPathComponent("unrelated")
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
        let info = await fixture.runtime(commands).inspect()
        XCTAssertFalse(info.templateReady)
        XCTAssertNotNil(info.failure)
    }
    func testRealCrossOverTemplateWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["PLAYDEN_CROSSOVER_TEMPLATE_PROBE"] == "1" else { throw XCTSkip("Opt in to creating and deleting a unique CrossOver test template") }
        let name = "playden-probe-\(UUID().uuidString.lowercased())-template"
        let state = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: state) }
        let runtime = CrossOverRuntime(stateDirectory: state, templateName: name)
        var failure: Error?
        do {
            let result = try await runtime.prepareTemplate()
            XCTAssertTrue(result.templateReady)
            let restored = await CrossOverRuntime(stateDirectory: state, templateName: name).inspect()
            XCTAssertTrue(restored.templateReady)
        } catch { failure = error }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossOver/Bottles/" + name)
        if FileManager.default.fileExists(atPath: folder.path) {
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".playden-owner.json"))) as? [String: Any]
            guard marker?["name"] as? String == name, try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
            let cleanup = try await CommandExecutor().run(executable: URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxbottle"), arguments: ["--bottle", name, "--delete", "--force"], timeout: 45)
            XCTAssertEqual(cleanup.exitCode, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        }
        if let failure { throw failure }
    }
}
