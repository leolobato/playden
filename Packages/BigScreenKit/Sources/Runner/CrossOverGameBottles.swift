import Foundation
import CryptoKit
import Darwin
import Domain

public protocol GameBottleManaging: Sendable {
    func prepare(_ bottle: GameBottle) async throws
    func isReady(_ bottle: GameBottle) async throws -> Bool
    /// Caller must stop the game's session and retain saves before destroying an installed bottle.
    func remove(_ bottle: GameBottle) async throws
}

/// Clones inside an owned container, then publishes into CrossOver's private bottle directory.
/// A partial clone is never mistaken for a ready bottle or adopted from another application.
public actor CrossOverGameBottles: GameBottleManaging {
    private let bottles: URL
    private let application: URL
    private let templateName: String
    private let runtime: any BottleManaging
    private let commands: any CommandExecuting
    private let files = FileManager.default
    private var busy = Set<String>()
    public init(application: URL = URL(fileURLWithPath: "/Applications/CrossOver.app"),
                bottles: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossOver/Bottles"),
                templateName: String = "gn-template-1", runtime: any BottleManaging = CrossOverRuntime(),
                commands: any CommandExecuting = CommandExecutor()) {
        self.application = application; self.bottles = bottles; self.templateName = templateName
        self.runtime = runtime; self.commands = commands
    }
    public static func name(for id: GameID) -> String {
        let plain = "gn-\(id.source)-\(id.value)"
        if plain.utf8.count <= 120, plain.range(of: #"^gn-[a-z0-9]+-[a-z0-9-]+$"#, options: .regularExpression) != nil { return plain }
        let digest = SHA256.hash(data: Data((String(id.source.utf8.count) + ":" + id.source + id.value).utf8)).map { String(format: "%02x", $0) }.joined()
        return "gn-game-" + digest
    }
    public func isReady(_ bottle: GameBottle) throws -> Bool {
        try validateIdentity(bottle)
        let destination = bottles.appendingPathComponent(bottle.name)
        guard exists(destination) else { return false }
        guard try readMarker(at: destination, matching: bottle).ready else { return false }
        try checkConfiguration(destination)
        return true
    }
    public func prepare(_ bottle: GameBottle) async throws {
        try validateIdentity(bottle)
        guard busy.insert(bottle.name).inserted else { throw problem("Game runtime setup is already running.") }
        defer { busy.remove(bottle.name) }
        try Task.checkCancellation()
        var info = await runtime.inspect()
        if !info.templateReady { info = try await runtime.prepareTemplate(onProgress: { _ in }) }
        guard info.templateReady, info.templateVersion == bottle.templateVersion else { throw problem("The required game runtime template is unavailable.") }
        let destination = bottles.appendingPathComponent(bottle.name)
        if exists(destination) {
            let marker = try readMarker(at: destination, matching: bottle)
            if marker.ready { try checkConfiguration(destination); return }
        } else {
            let container = try ownedContainer(bottle, create: true)
            let clone = container.appendingPathComponent("clone")
            // The container marker predates the command, including copies interrupted before
            // CrossOver writes any recognizable bottle metadata.
            if exists(clone) { try files.removeItem(at: clone) }
            let template = bottles.appendingPathComponent(templateName)
            try requireDirectory(template, under: bottles)
            try await run("cxbottle", ["--bottle", clone.path, "--copy", template.path], timeout: 120)
            try requireDirectory(clone, under: container)
            try checkConfiguration(clone)
            try write(Marker(bottle: bottle, ready: false), at: clone)
            try Task.checkCancellation()
            guard !exists(destination) else { throw problem("A bottle with this name appeared during setup. Its files have been kept.") }
            try files.moveItem(at: clone, to: destination)
        }
        // Repairs path-dependent CrossOver metadata after the atomic directory move.
        try await run("cxbottle", ["--bottle", destination.path, "--restored"], timeout: 45)
        try checkConfiguration(destination)
        let result = try await run("cxstart", ["--bottle", destination.path, "--no-gui", "--wait-children", "cmd.exe", "/c", "echo BIGSCREEN_GAME_BOTTLE_READY"], timeout: 45)
        guard result.output.contains("BIGSCREEN_GAME_BOTTLE_READY") else { throw problem("The game's runtime did not finish its startup check.", output: result.output) }
        try Task.checkCancellation()
        _ = try readMarker(at: destination, matching: bottle)
        try write(Marker(bottle: bottle, ready: true), at: destination)
        try removeContainerIfPresent(bottle)
    }
    public func remove(_ bottle: GameBottle) async throws {
        try validateIdentity(bottle)
        guard busy.insert(bottle.name).inserted else { throw problem("Wait for the game's runtime setup to stop before removing it.") }
        defer { busy.remove(bottle.name) }
        let destination = bottles.appendingPathComponent(bottle.name)
        if exists(destination) {
            _ = try readMarker(at: destination, matching: bottle)
            try await run("cxbottle", ["--bottle", destination.path, "--delete", "--force"], timeout: 45)
            guard !exists(destination) else { throw problem("The game's runtime folder could not be removed.") }
        }
        try removeContainerIfPresent(bottle)
    }
    private struct Marker: Codable, Equatable { let bottle: GameBottle; var ready: Bool }
    private let markerName = ".bigscreen-game-owner.json"
    private func validateIdentity(_ bottle: GameBottle) throws {
        guard bottle.name == Self.name(for: bottle.gameID), bottle.name != templateName,
              bottle.templateVersion == CrossOverRuntime.templateVersion,
              templateName.range(of: #"^gn-[a-z0-9-]+$"#, options: .regularExpression) != nil else { throw problem("The saved game runtime identity is invalid.") }
    }
    private func ownedContainer(_ bottle: GameBottle, create: Bool) throws -> URL {
        let parent = bottles.appendingPathComponent(".bigscreen-staging")
        if create { try files.createDirectory(at: parent, withIntermediateDirectories: true) }
        try requireDirectory(parent, under: bottles)
        let container = parent.appendingPathComponent(bottle.ownershipToken.uuidString)
        if create && !exists(container) {
            guard mkdir(container.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            do { try write(Marker(bottle: bottle, ready: false), at: container) }
            catch { _ = rmdir(container.path); throw error }
        }
        _ = try readMarker(at: container, matching: bottle)
        return container
    }
    private func removeContainerIfPresent(_ bottle: GameBottle) throws {
        let container = bottles.appendingPathComponent(".bigscreen-staging").appendingPathComponent(bottle.ownershipToken.uuidString)
        guard exists(container) else { return }
        let owned = try ownedContainer(bottle, create: false)
        try files.removeItem(at: owned)
    }
    private func readMarker(at directory: URL, matching bottle: GameBottle) throws -> Marker {
        try requireDirectory(directory, under: directory.deletingLastPathComponent())
        let file = directory.appendingPathComponent(markerName)
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              let data = try? Data(contentsOf: file), let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker.bottle == bottle else { throw problem("This runtime folder does not belong to this Big Screen installation. Its files have been kept.") }
        return marker
    }
    private func requireDirectory(_ directory: URL, under parent: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              directory.resolvingSymlinksInPath().deletingLastPathComponent() == parent.resolvingSymlinksInPath() else { throw problem("A game runtime folder moved or became a symbolic link.") }
    }
    private func checkConfiguration(_ directory: URL) throws {
        let config = directory.appendingPathComponent("cxbottle.conf")
        guard (try? config.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { throw problem("The game runtime configuration is unavailable.") }
        let text = try String(contentsOf: config, encoding: .utf8)
        var section = "", values: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            if section == "[EnvironmentVariables]", let equals = line.firstIndex(of: "=") {
                values[String(line[..<equals]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard values["\"WINEMSYNC\""] == "\"1\"", values["\"CX_GRAPHICS_BACKEND\""] == "\"d3dmetal\"" else { throw problem("The game runtime settings do not match the template.") }
    }
    private func write(_ marker: Marker, at directory: URL) throws {
        let destination = directory.appendingPathComponent(markerName)
        try JSONEncoder().encode(marker).write(to: destination, options: .atomic)
        let file = try FileHandle(forWritingTo: destination); defer { try? file.close() }
        try file.synchronize()
    }
    private func exists(_ path: URL) -> Bool { var info = stat(); return lstat(path.path, &info) == 0 }
    @discardableResult private func run(_ name: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        let executable = application.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/" + name)
        let result = try await commands.run(executable: executable, arguments: arguments, timeout: timeout)
        if result.cancelled { throw CancellationError() }
        guard !result.timedOut, result.exitCode == 0 else {
            throw problem(result.timedOut ? "The game's runtime setup took too long. Retry to continue." : "The game's runtime setup could not finish.", output: result.output)
        }
        try Task.checkCancellation(); return result
    }
    private func problem(_ reason: String, output: String = "") -> OperationFailure { .init(stage: "Game runtime", reason: reason, output: output) }
}
