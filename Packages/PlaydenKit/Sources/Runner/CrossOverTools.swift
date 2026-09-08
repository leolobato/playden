import Foundation
import Domain
import Darwin

public actor CrossOverTools: RuntimeToolRunning {
    private let manager: any GameBottleManaging
    private let application: URL
    private let commands: any CommandExecuting
    private var busy = Set<String>()
    public init(manager: any GameBottleManaging = CrossOverGameBottles(),
                application: URL = URL(fileURLWithPath: "/Applications/CrossOver.app"),
                commands: any CommandExecuting = CommandExecutor()) {
        self.manager = manager; self.application = application; self.commands = commands
    }
    public func runTool(executable: URL, arguments: [String], in bottle: GameBottle) async throws {
        guard busy.insert(bottle.name).inserted else { throw prerequisiteFailure("Game preparation is already running.") }
        defer { busy.remove(bottle.name) }
        try await execute(executable: executable, arguments: arguments, in: bottle)
    }
    public func prerequisiteReady(_ prerequisite: RuntimePrerequisite, in bottle: GameBottle) async throws -> Bool {
        let root = try await manager.ownedDirectory(bottle)
        return try receipt(at: root, bottle: bottle).steps[prerequisite.id] == prerequisite.fingerprint
    }
    public func preparePrerequisite(_ prerequisite: RuntimePrerequisite, executable: URL, in bottle: GameBottle) async throws {
        guard prerequisite.fingerprint.count == 32, !prerequisite.id.isEmpty,
              busy.insert(bottle.name).inserted else { throw prerequisiteFailure("The game prerequisite is invalid or already running.") }
        defer { busy.remove(bottle.name) }
        let root = try await manager.ownedDirectory(bottle)
        let identity = try rootIdentity(root)
        var saved = try receipt(at: root, bottle: bottle)
        if saved.steps[prerequisite.id] == prerequisite.fingerprint { return }
        do { try await execute(executable: executable, arguments: prerequisite.arguments, in: bottle) }
        catch let failure as OperationFailure {
            throw OperationFailure(stage: prerequisite.title, reason: "This game prerequisite could not finish. Retry to continue.", output: failure.output)
        }
        try Task.checkCancellation()
        guard try await manager.ownedDirectory(bottle) == root, try rootIdentity(root) == identity else { throw prerequisiteFailure("The game's runtime changed during preparation. Retry to continue.") }
        saved.steps[prerequisite.id] = prerequisite.fingerprint
        let path = root.appendingPathComponent(".playden-prerequisites.json")
        try JSONEncoder().encode(saved).write(to: path, options: .atomic)
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    private struct PrerequisiteReceipt: Codable {
        var version = 1
        var bottle: GameBottle
        var steps: [String: Data] = [:]
    }
    private func receipt(at root: URL, bottle: GameBottle) throws -> PrerequisiteReceipt {
        let path = root.appendingPathComponent(".playden-prerequisites.json")
        let properties: URLResourceValues
        do { properties = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .init(bottle: bottle) }
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
            throw prerequisiteFailure("The saved prerequisite record could not be verified. Its files have been kept.")
        }
        let value = try JSONDecoder().decode(PrerequisiteReceipt.self, from: Data(contentsOf: path))
        guard value.version == 1, value.bottle == bottle else { throw prerequisiteFailure("The prerequisite record belongs to another runtime. Its files have been kept.") }
        return value
    }
    private func rootIdentity(_ root: URL) throws -> SaveRootIdentity {
        var value = stat()
        guard lstat(root.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw prerequisiteFailure("The game's runtime folder is unavailable.") }
        return .init(device: Int64(value.st_dev), inode: UInt64(value.st_ino), birthSeconds: Int64(value.st_birthtimespec.tv_sec), birthNanoseconds: Int64(value.st_birthtimespec.tv_nsec))
    }
    private func prerequisiteFailure(_ reason: String) -> OperationFailure { .init(stage: "Game prerequisites", reason: reason, output: "") }
    private func execute(executable: URL, arguments: [String], in bottle: GameBottle) async throws {
        try Task.checkCancellation()
        let directory = try await manager.ownedDirectory(bottle)
        let result = try await commands.run(executable: application.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/cxstart"),
            arguments: ["--bottle", directory.path, "--no-gui", "--wait-children", executable.path] + arguments, timeout: 120)
        if result.cancelled || Task.isCancelled { throw CancellationError() }
        guard !result.timedOut, result.exitCode == 0 else {
            throw OperationFailure(stage: "Prepare executable", reason: result.timedOut
                ? "Game preparation took too long. Retry to continue."
                : "The game executable could not be prepared. View logs for details, then retry.", output: result.output)
        }
    }
}
