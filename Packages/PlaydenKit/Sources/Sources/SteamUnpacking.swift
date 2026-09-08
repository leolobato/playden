import Foundation
import CryptoKit
import Domain
import SteamCore

enum SteamUnpacking {
    static let version = "3.1.0.5"
    static func executable() throws -> URL {
        guard let root = Bundle.module.url(forResource: "Steamless", withExtension: nil) else { throw failure("The game preparation tool is missing. Reinstall Playden.") }
        let data = try Data(contentsOf: root.appendingPathComponent("checksums.json"))
        guard hex(data) == "817b6edd5c8adaba777eb4d1a4f88ccbe01a5460bd3919260ba6327ebd6fbdef" else { throw failure("The game preparation tool could not be verified. Reinstall Playden.") }
        for (path, checksum) in try JSONDecoder().decode([String: String].self, from: data) {
            guard hex(try Data(contentsOf: root.appendingPathComponent(path))) == checksum else { throw failure("The game preparation tool changed. Reinstall Playden.") }
        }
        return root.appendingPathComponent("Steamless.CLI.exe")
    }
    /// The tool sees only a disposable copy; callers retain and verify the pinned original.
    /// No output beside the installed executable is trusted as proof of successful unpacking.
    static func unpack(_ original: URL, in bottle: GameBottle, tools: any RuntimeToolRunning) async throws -> Data {
        let before = try PEInspector.inspect(original)
        guard before.requiresSteamStubRuntime else { throw failure("The executable does not require this preparation step.") }
        let bundledTool = try executable()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Playden-unpack-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let toolRoot = work.appendingPathComponent("Steamless")
        try FileManager.default.copyItem(at: bundledTool.deletingLastPathComponent(), to: toolRoot)
        // Wine Mono resolves the CLI's API field types before Main installs its Plugins
        // assembly resolver. Keep identical verified dependencies next to the CLI as well.
        for library in ["Steamless.API.dll", "SharpDisasm.dll"] {
            try FileManager.default.copyItem(at: toolRoot.appendingPathComponent("Plugins/" + library),
                to: toolRoot.appendingPathComponent(library))
        }
        let tool = toolRoot.appendingPathComponent(bundledTool.lastPathComponent)
        let input = work.appendingPathComponent("game.exe"), output = work.appendingPathComponent("game.exe.unpacked.exe")
        try FileManager.default.copyItem(at: original, to: input)
        try await tools.runTool(executable: tool, arguments: ["--quiet", "Z:" + input.path.replacingOccurrences(of: "/", with: "\\")], in: bottle)
        try Task.checkCancellation()
        let properties = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw failure("Game preparation did not produce a valid executable.") }
        let after = try PEInspector.inspect(output)
        guard after.architecture == before.architecture, after.entryPointSection != nil,
              !after.requiresSteamStubRuntime else { throw failure("The prepared executable failed validation. Its original has been kept.") }
        return try Data(contentsOf: output)
    }
    private static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func failure(_ reason: String) -> OperationFailure { .init(stage: "Prepare executable", reason: reason, output: "") }
}
