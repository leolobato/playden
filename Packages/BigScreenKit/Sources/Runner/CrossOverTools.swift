import Foundation
import Domain

public struct CrossOverTools: RuntimeToolRunning {
    private let manager: any GameBottleManaging
    private let application: URL
    private let commands: any CommandExecuting
    public init(manager: any GameBottleManaging = CrossOverGameBottles(),
                application: URL = URL(fileURLWithPath: "/Applications/CrossOver.app"),
                commands: any CommandExecuting = CommandExecutor()) {
        self.manager = manager; self.application = application; self.commands = commands
    }
    public func runTool(executable: URL, arguments: [String], in bottle: GameBottle) async throws {
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
