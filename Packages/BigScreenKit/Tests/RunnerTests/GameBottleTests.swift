import XCTest
import Darwin
import Domain
@testable import Runner

private struct ReadyTemplate: BottleManaging {
    func inspect() async -> RuntimeInfo { .init(version: "26.2", templateVersion: "1", templateReady: true) }
    func prepareTemplate(onProgress: @escaping @Sendable (TemplateStage) -> Void) async throws -> RuntimeInfo { await inspect() }
}
private actor BottleCommands: CommandExecuting {
    var copies = 0
    var interruptCopy: Bool
    var failValidation: Bool
    var interruptDelete: Bool
    init(interruptCopy: Bool = false, failValidation: Bool = false, interruptDelete: Bool = false) { self.interruptCopy = interruptCopy; self.failValidation = failValidation; self.interruptDelete = interruptDelete }
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        let destination = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "--bottle")! + 1])
        if let index = arguments.firstIndex(of: "--copy") {
            copies += 1
            if interruptCopy {
                interruptCopy = false
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Data("partial".utf8).write(to: destination.appendingPathComponent("partial.data"))
                return .init(exitCode: 15, output: "", cancelled: true)
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[index + 1]), to: destination)
        } else if arguments.contains("--delete") {
            if interruptDelete {
                interruptDelete = false
                try FileManager.default.removeItem(at: destination.appendingPathComponent("cxbottle.conf"))
                try FileManager.default.removeItem(at: destination.appendingPathComponent(".bigscreen-game-owner.json"))
                return .init(exitCode: 15, output: "", cancelled: true)
            }
            try FileManager.default.removeItem(at: destination)
        }
        else if executable.lastPathComponent == "cxstart", failValidation {
            failValidation = false; return .init(exitCode: 1, output: "fixture runtime failure")
        }
        return .init(exitCode: 0, output: "BIGSCREEN_GAME_BOTTLE_READY")
    }
}
private struct RemovalInspector: RuntimeInspecting {
    var observation = RuntimeObservation(processes: [])
    var identities: [Int32: ProcessIdentity] = [:]
    func inspect(bottle: URL) throws -> RuntimeObservation { observation }
    func identity(of pid: Int32) -> ProcessIdentity? { identities[pid] }
}
final class GameBottleTests: XCTestCase {
    func testRemovalChecksLiveOmittedAndUnreadableWritersByBirthIdentity() async throws {
        let root = try fixture(), bottle = reference(), commands = BottleCommands()
        try await CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands).prepare(bottle)
        let writer = ProcessIdentity(pid: 123, startSeconds: 100, startMicroseconds: 5)
        let previous = RunSnapshot(run: .init(bottle: bottle, launcher: writer))
        let observations = [
            RemovalInspector(observation: .init(processes: [.init(identity: writer, kind: .game, executable: "game.exe")])),
            RemovalInspector(identities: [writer.pid: writer]),
            RemovalInspector(observation: .init(processes: [], unreadablePIDs: [writer.pid]))
        ]
        for inspector in observations {
            let manager = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands, inspector: inspector)
            do { try await manager.checkRemoval(bottle, previousRuntime: previous); XCTFail("A live or unconfirmed writer was accepted") } catch {}
        }
        let reused = ProcessIdentity(pid: writer.pid, startSeconds: 200, startMicroseconds: 0)
        let manager = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands,
            inspector: RemovalInspector(observation: .init(processes: [], unreadablePIDs: [987]), identities: [writer.pid: reused]))
        try await manager.checkRemoval(bottle, previousRuntime: previous)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(bottle.name).path))
    }
    func testInterruptedDeleteWithoutInternalConfigRecoversFromExternalOwnership() async throws {
        let root = try fixture(), bottle = reference(), commands = BottleCommands(interruptDelete: true)
        let manager = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands)
        try await manager.prepare(bottle)
        do { try await manager.remove(bottle); XCTFail("Expected deletion interruption") } catch is CancellationError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(bottle.name).path))
        let ready = try await manager.isReady(bottle); XCTAssertFalse(ready)
        do { try await manager.prepare(bottle); XCTFail("Cannot recreate during removal") } catch {}
        let reopened = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands)
        try await reopened.remove(bottle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(bottle.name).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".bigscreen-removing-\(bottle.ownershipToken.uuidString).json").path))
        try await reopened.remove(bottle)
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BigScreen-bottles-\(UUID().uuidString)")
        let template = root.appendingPathComponent("gn-template-1")
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        try "[EnvironmentVariables]\n\"WINEMSYNC\" = \"1\"\n\"CX_GRAPHICS_BACKEND\" = \"d3dmetal\"\n".write(to: template.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func reference(_ value: String = "100") -> GameBottle {
        let id = GameID(source: "fixture", value: value)
        return .init(gameID: id, name: CrossOverGameBottles.name(for: id), ownershipToken: UUID())
    }
    func testInterruptedCloneCanRetryAndCleanupRemovesOnlyOwnedFiles() async throws {
        let root = try fixture(), commands = BottleCommands(interruptCopy: true), bottle = reference()
        let manager = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands)
        let unrelated = root.appendingPathComponent("user-bottle")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        do { try await manager.prepare(bottle); XCTFail("Expected interruption") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(bottle.name).path))
        try await manager.prepare(bottle)
        let ready = try await manager.isReady(bottle); XCTAssertTrue(ready)
        try await manager.prepare(bottle)
        let count = await commands.copies; XCTAssertEqual(count, 2)
        try await manager.remove(bottle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(bottle.name).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("gn-template-1").path))
    }
    func testValidationFailureResumesPublishedCloneWithoutCopyingAgain() async throws {
        let root = try fixture(), commands = BottleCommands(failValidation: true), bottle = reference()
        let first = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands)
        do { try await first.prepare(bottle); XCTFail("Expected runtime failure") } catch {}
        let ready = try await first.isReady(bottle); XCTAssertFalse(ready)
        let restarted = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands)
        try await restarted.prepare(bottle)
        let count = await commands.copies; XCTAssertEqual(count, 1)
        let recovered = try await restarted.isReady(bottle); XCTAssertTrue(recovered)
        let wrong = GameBottle(gameID: bottle.gameID, name: bottle.name, ownershipToken: UUID())
        do { try await restarted.remove(wrong); XCTFail("Wrong ownership token accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(bottle.name).path))
    }
    func testUnownedDestinationAndSymlinkAreRejected() async throws {
        let root = try fixture(), bottle = reference(), commands = BottleCommands()
        let destination = root.appendingPathComponent(bottle.name)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let manager = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands)
        do { try await manager.prepare(bottle); XCTFail("Unowned bottle adopted") } catch {}
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: root.appendingPathComponent("gn-template-1"))
        do { try await manager.remove(bottle); XCTFail("Symlink accepted") } catch {}
        let count = await commands.copies; XCTAssertEqual(count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }
    func testSaveAccessRequiresAnOwnedReadyBottleAndReturnsPhysicalRoot() async throws {
        let root = try fixture(), bottle = reference(), commands = BottleCommands()
        let manager = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands)
        do { _ = try await manager.ownedDirectory(bottle); XCTFail("Missing bottle exposed") } catch {}
        try await manager.prepare(bottle)
        let directory = try await manager.ownedDirectory(bottle)
        let physical = try XCTUnwrap(realpath(root.appendingPathComponent(bottle.name).path, nil))
        defer { free(physical) }
        XCTAssertEqual(directory.path, String(cString: physical))
        let wrong = GameBottle(gameID: bottle.gameID, name: bottle.name, ownershipToken: UUID())
        do { _ = try await manager.ownedDirectory(wrong); XCTFail("Other ownership token exposed") } catch {}
        let marker = directory.appendingPathComponent(".bigscreen-game-owner.json")
        try FileManager.default.removeItem(at: marker)
        do { _ = try await manager.ownedDirectory(bottle); XCTFail("Unowned save folder exposed") } catch {}
    }
    func testRealCrossOverCloneStartupAndScopedDeleteWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["BIGSCREEN_CROSSOVER_BOTTLE_PROBE"] == "1" else { throw XCTSkip("Opt in to a unique owned game-bottle clone/startup/delete probe") }
        let bottle = reference(UUID().uuidString.lowercased())
        let manager = CrossOverGameBottles()
        try await manager.prepare(bottle)
        let ready = try await manager.isReady(bottle); XCTAssertTrue(ready)
        try await manager.remove(bottle)
        let removed = try await manager.isReady(bottle); XCTAssertFalse(removed)
    }
}
