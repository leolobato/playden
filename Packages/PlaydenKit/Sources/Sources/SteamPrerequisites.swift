import Foundation
import CryptoKit
import Domain
import SteamCore

enum SteamPrerequisites {
    static func prepare(_ plan: InstallPlan, gameID: GameID, at directory: URL, in bottle: GameBottle,
                        tools: (any RuntimeToolRunning)?) async throws {
        let payload = try SteamPlanBuilder.payload(plan, for: gameID)
        let steps = try SteamRecipes.steps(for: gameID, version: plan.recipeVersion)
        guard !steps.isEmpty else { return }
        guard bottle.gameID == gameID, let tools else { throw failure("The game's prerequisite runtime is unavailable. Retry installation in Playden.") }
        let paths = try SteamPreparationPaths(root: directory)
        for step in steps {
            try Task.checkCancellation()
            let inputs = try SteamRecipes.inputs(step, files: payload.manifests.flatMap(\.files))
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            var identity = plan.sourcePayload
            identity.append(try encoder.encode(step)); identity.append(Data(String(plan.recipeVersion).utf8))
            let prerequisite = RuntimePrerequisite(id: step.id, title: step.title, arguments: step.arguments, fingerprint: Data(SHA256.hash(data: identity)))
            let ready = try await tools.prerequisiteReady(prerequisite, in: bottle)
            try paths.checkRoot()
            if ready { continue }
            let manifest = DepotManifest(depotID: 0, gid: 0, files: inputs, totalSize: inputs.reduce(0) { $0 + $1.size })
            guard try ResumableDepotDownload(destination: directory).invalidFiles(in: manifest).isEmpty else {
                throw failure("A game prerequisite is missing or damaged. Verify files before retrying.")
            }
            let inputBytes = try inputs.reduce(Int64(0)) { try InstallSpace.add($0, Int64($1.size)) }
            try InstallSpace.require(InstallSpace.add(inputBytes, InstallSpace.headroom), at: FileManager.default.temporaryDirectory)
            try await tools.checkSpace(in: bottle, minimumBytes: InstallSpace.headroom)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("Playden-prerequisites-" + UUID().uuidString)
            try SteamPreparationPaths.checkStorageDirectory(work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let workspace = try SteamPreparationPaths(root: work)
            defer { if (try? workspace.checkRoot()) != nil { try? FileManager.default.removeItem(at: work) } }
            var executable: URL?
            for input in inputs {
                try Task.checkCancellation()
                let path = try SteamPlanBuilder.relativePath(input.path), target = work.appendingPathComponent(path)
                try paths.check(directory.appendingPathComponent(path)); try workspace.check(target)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: directory.appendingPathComponent(path), to: target)
                if path.lowercased() == step.executable.lowercased() { executable = target }
            }
            guard let executable, try ResumableDepotDownload(destination: work).invalidFiles(in: manifest).isEmpty else {
                throw failure("The prerequisite files changed during preparation. Verify files before retrying.")
            }
            try await tools.preparePrerequisite(prerequisite, executable: executable, in: bottle)
            try Task.checkCancellation()
            try paths.checkRoot(); try workspace.checkRoot()
        }
    }
    private static func failure(_ reason: String) -> OperationFailure { .init(stage: "Game prerequisites", reason: reason, output: "") }
}
