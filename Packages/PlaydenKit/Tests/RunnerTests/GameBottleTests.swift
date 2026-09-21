import XCTest
import Darwin
import Synchronization
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
        } else if executable.lastPathComponent == "cxbottle", arguments.contains("--delete") {
            if interruptDelete {
                interruptDelete = false
                try FileManager.default.removeItem(at: destination.appendingPathComponent("cxbottle.conf"))
                try FileManager.default.removeItem(at: destination.appendingPathComponent(".playden-game-owner.json"))
                return .init(exitCode: 15, output: "", cancelled: true)
            }
            try FileManager.default.removeItem(at: destination)
        }
        else if executable.lastPathComponent == "cxstart", failValidation {
            failValidation = false; return .init(exitCode: 1, output: "fixture runtime failure")
        }
        return .init(exitCode: 0, output: "PLAYDEN_GAME_BOTTLE_READY")
    }
}
private struct RemovalInspector: RuntimeInspecting {
    var observation = RuntimeObservation(processes: [])
    var identities: [Int32: ProcessIdentity] = [:]
    func inspect(bottle: URL) throws -> RuntimeObservation { observation }
    func identity(of pid: Int32) -> ProcessIdentity? { identities[pid] }
}
final class GameBottleTests: XCTestCase {
    func testTitledBottlePreservesOwnershipSavesAndResumableRemoval() async throws {
        let root = try fixture(), bottle = reference(), commands = BottleCommands(interruptDelete: true)
        let manager = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands, inspector: RemovalInspector())
        try await manager.prepare(bottle)
        try await manager.completeSourcePreparation(bottle)
        let old = root.appendingPathComponent(bottle.name)
        let save = Data("save progress".utf8)
        try save.write(to: old.appendingPathComponent("progress.sav"))
        try Data("exe".utf8).write(to: root.appendingPathComponent("game.exe"))
        try await manager.updatePresentation(bottle, title: "FINAL FANTASY VII", directory: root, spec: .init(executableRelativePath: "game.exe", dllOverrides: ["steam_api64=n,b"]))
        let renamed = try CrossOverBottlePresentation.directory(for: bottle, under: root)
        XCTAssertEqual(renamed.lastPathComponent, "FINAL FANTASY VII (\(bottle.name))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try Data(contentsOf: renamed.appendingPathComponent("progress.sav")), save)
        let ready = try await manager.isReady(bottle); XCTAssertTrue(ready)
        let pending = try await manager.requiresSourcePreparation(bottle); XCTAssertFalse(pending)
        let script = try String(contentsOf: renamed.appendingPathComponent(".playden-launch.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("'steam_api64=n,b'"))
        try await manager.updatePresentation(bottle, title: "FINAL FANTASY VII", directory: root, spec: .init(executableRelativePath: "game.exe"))
        do { try await manager.remove(bottle); XCTFail("Expected interrupted delete") } catch is CancellationError {}
        let reopened = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands, inspector: RemovalInspector())
        try await reopened.remove(bottle)
        try await reopened.verifyRemoved(bottle)
    }
    func testPresentationNamesAreBoundedAndDuplicateLocationsAreRejected() throws {
        let root = try fixture(), bottle = reference()
        let name = CrossOverBottlePresentation.name(title: String(repeating: "界", count: 300) + "/$(oops)", bottle: bottle)
        XCTAssertLessThan(name.utf8.count, 255)
        XCTAssertFalse(name.contains("/")); XCTAssertFalse(name.contains("$"))
        for name in [bottle.name, "Game (\(bottle.name))"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        XCTAssertThrowsError(try CrossOverBottlePresentation.directory(for: bottle, under: root))
    }
    func testSourcePreparationRemainsPendingAcrossRestartUntilAcknowledged() async throws {
        let root = try fixture(), bottle = reference(), commands = BottleCommands()
        let first = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands, inspector: RemovalInspector())
        let runner = CrossOverRunner(bottles: root, manager: first, inspector: RemovalInspector())
        let changed = try await runner.prepare(bottle); XCTAssertTrue(changed)
        let baseReady = try await first.isReady(bottle); XCTAssertTrue(baseReady)
        let reopened = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands, inspector: RemovalInspector())
        let restarted = CrossOverRunner(bottles: root, manager: reopened, inspector: RemovalInspector())
        let pending = try await restarted.prepare(bottle); XCTAssertTrue(pending)
        do {
            _ = try await restarted.launch(.init(executableRelativePath: "game.exe"), in: bottle, directory: root)
            XCTFail("Unfinished source preparation launched a writer")
        } catch let failure as OperationFailure { XCTAssertTrue(failure.reason.contains("preparation has not finished")) }
        let wrong = GameBottle(gameID: bottle.gameID, name: bottle.name, ownershipToken: UUID())
        do { try await reopened.completeSourcePreparation(wrong); XCTFail("Foreign ownership acknowledged") } catch {}
        try await restarted.completePreparation(bottle)
        let after = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands, inspector: RemovalInspector())
        let complete = try await after.requiresSourcePreparation(bottle); XCTAssertFalse(complete)
        let unchanged = try await CrossOverRunner(bottles: root, manager: after, inspector: RemovalInspector()).prepare(bottle)
        XCTAssertFalse(unchanged)
        let copies = await commands.copies; XCTAssertEqual(copies, 1)
        try await after.remove(bottle)
        try await after.prepare(bottle)
        let recreated = try await after.requiresSourcePreparation(bottle); XCTAssertTrue(recreated)
    }
    func testLegacyOwnerNeedsOneSourceValidationAndKeepsExistingSave() async throws {
        let root = try fixture(), bottle = reference(), commands = BottleCommands()
        let manager = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands)
        try await manager.prepare(bottle)
        let directory = root.appendingPathComponent(bottle.name), marker = directory.appendingPathComponent(".playden-game-owner.json")
        let save = directory.appendingPathComponent("existing.sav"), bytes = Data("existing progress".utf8)
        try bytes.write(to: save)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        legacy.removeValue(forKey: "sourcePreparationPending")
        try JSONSerialization.data(withJSONObject: legacy).write(to: marker)
        let needsValidation = try await manager.requiresSourcePreparation(bottle); XCTAssertTrue(needsValidation)
        try await manager.completeSourcePreparation(bottle)
        let completed = try await manager.requiresSourcePreparation(bottle); XCTAssertFalse(completed)
        XCTAssertEqual(try Data(contentsOf: save), bytes)
    }
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
    func testCheckConfigurationAcceptsAlternativeGraphicsAndSyncModesButRejectsUnknownBackend() async throws {
        let root = try fixture(), bottle = reference(), commands = BottleCommands()
        let manager = CrossOverGameBottles(bottles: root, runtime: ReadyTemplate(), commands: commands)
        try await manager.prepare(bottle)
        let conf = root.appendingPathComponent(bottle.name).appendingPathComponent("cxbottle.conf")
        _ = try RuntimeMechanisms.rewriteBottleEnvironment(at: conf, values: ["CX_GRAPHICS_BACKEND": "dxvk", "WINEMSYNC": "0", "WINEESYNC": "1"])
        let ready = try await manager.isReady(bottle); XCTAssertTrue(ready)
        _ = try RuntimeMechanisms.rewriteBottleEnvironment(at: conf, values: ["CX_GRAPHICS_BACKEND": "wined3d"])
        do { _ = try await manager.isReady(bottle); XCTFail("Unknown graphics backend accepted") } catch {}
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".playden-removing-\(bottle.ownershipToken.uuidString).json").path))
        try await reopened.remove(bottle)
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Playden-bottles-\(UUID().uuidString)")
        let template = root.appendingPathComponent("playden-template-1")
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("playden-template-1").path))
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
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: root.appendingPathComponent("playden-template-1"))
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
        let marker = directory.appendingPathComponent(".playden-game-owner.json")
        try FileManager.default.removeItem(at: marker)
        do { _ = try await manager.ownedDirectory(bottle); XCTFail("Unowned save folder exposed") } catch {}
    }
    func testRealCrossOverCloneStartupAndScopedDeleteWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["PLAYDEN_CROSSOVER_BOTTLE_PROBE"] == "1" else { throw XCTSkip("Opt in to a unique owned game-bottle clone/startup/delete probe") }
        let bottle = reference(UUID().uuidString.lowercased())
        let manager = CrossOverGameBottles()
        let commands = Mutex<[DiagnosticCommand]>([])
        try await DiagnosticOutputContext.$sink.withValue({ command in commands.withLock { $0.append(command) } }) {
            do {
                try await manager.prepare(bottle)
                let ready = try await manager.isReady(bottle); XCTAssertTrue(ready)
                let pending = try await manager.requiresSourcePreparation(bottle); XCTAssertTrue(pending)
                try await manager.completeSourcePreparation(bottle)
                let reopened = CrossOverGameBottles()
                let acknowledged = try await reopened.requiresSourcePreparation(bottle); XCTAssertFalse(acknowledged)
                try await reopened.prepare(bottle)
                let stillAcknowledged = try await reopened.requiresSourcePreparation(bottle); XCTAssertFalse(stillAcknowledged)
                try await manager.remove(bottle)
                let removed = try await manager.isReady(bottle); XCTAssertFalse(removed)
                try await reopened.prepare(bottle)
                let recreated = try await reopened.requiresSourcePreparation(bottle); XCTAssertTrue(recreated)
                try await reopened.remove(bottle)
            } catch { try? await manager.remove(bottle); throw error }
        }
        XCTAssertTrue(commands.withLock { $0.contains { $0.tool == "cxbottle" && $0.exitCode == 0 } })
        XCTAssertTrue(commands.withLock { $0.contains { $0.tool == "cxstart" && $0.output.contains("PLAYDEN_GAME_BOTTLE_READY") && $0.exitCode == 0 } })
    }
}
