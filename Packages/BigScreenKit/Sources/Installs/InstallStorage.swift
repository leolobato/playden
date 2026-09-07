import Foundation
import Darwin
import Domain
import Runner

public protocol InstallStorageManaging: Sendable {
    func freeBytes(on volume: GamesVolumeSelection) async throws -> Int64
    func prepare(gameID: GameID, owner: UUID, on volume: GamesVolumeSelection) async throws -> GameLocation
    func directory(_ location: GameLocation, gameID: GameID, owner: UUID) async throws -> URL
    func remove(_ location: GameLocation, gameID: GameID, owner: UUID) async throws
}

/// Ownership metadata is outside downloadable content, so a depot cannot overwrite its own owner.
public actor InstallStorage: InstallStorageManaging {
    private let volumes: any VolumeManaging
    private let files = FileManager.default
    public init(volumes: any VolumeManaging = GamesVolumeStore()) { self.volumes = volumes }
    public func freeBytes(on volume: GamesVolumeSelection) async throws -> Int64 {
        let root = try await volumes.resolve(volume)
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) else {
            throw issue("Storage", "Free space on the games drive could not be checked.")
        }
        return max(0, bytes)
    }
    public func prepare(gameID: GameID, owner: UUID, on volume: GamesVolumeSelection) async throws -> GameLocation {
        let root = try await volumes.resolve(volume)
        try physicalDirectory(root)
        let name = CrossOverGameBottles.name(for: gameID)
        let container = root.appendingPathComponent(name, isDirectory: true)
        let marker = Owner(gameID: gameID, token: owner)
        if !exists(container) {
            guard mkdir(container.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            do {
                let path = container.appendingPathComponent(".bigscreen-install.json")
                try JSONEncoder().encode(marker).write(to: path, options: .atomic)
                let handle = try FileHandle(forWritingTo: path); defer { try? handle.close() }; try handle.synchronize()
            } catch { _ = rmdir(container.path); throw error }
        }
        try verify(container, owner: marker)
        let game = container.appendingPathComponent("game", isDirectory: true)
        if !exists(game) { try files.createDirectory(at: game, withIntermediateDirectories: false) }
        try physicalDirectory(game)
        var location = GameLocation(volumeID: volume.volumeID, rootBookmark: volume.rootBookmark, lastKnownRoot: root, relativePath: name + "/game")
        location.relativeRoot = volume.relativeRoot
        return location
    }
    public func directory(_ location: GameLocation, gameID: GameID, owner: UUID) async throws -> URL {
        let container = try await container(location, gameID: gameID, owner: owner)
        let game = container.appendingPathComponent("game", isDirectory: true)
        try physicalDirectory(game); return game
    }
    public func remove(_ location: GameLocation, gameID: GameID, owner: UUID) async throws {
        let root = try await resolveRoot(location)
        try validate(location, gameID: gameID)
        let container = root.appendingPathComponent(CrossOverGameBottles.name(for: gameID))
        guard exists(container) else { return }
        try verify(container, owner: Owner(gameID: gameID, token: owner))
        try Task.checkCancellation()
        try files.removeItem(at: container)
    }
    private func container(_ location: GameLocation, gameID: GameID, owner: UUID) async throws -> URL {
        try validate(location, gameID: gameID)
        let root = try await resolveRoot(location)
        let container = root.appendingPathComponent(CrossOverGameBottles.name(for: gameID))
        try verify(container, owner: Owner(gameID: gameID, token: owner))
        return container
    }
    private func resolveRoot(_ location: GameLocation) async throws -> URL {
        guard let bookmark = location.rootBookmark, let relativeRoot = location.relativeRoot else {
            throw issue("Games volume", "This installation has no saved games-drive identity.")
        }
        let root = try await volumes.resolve(GamesVolumeSelection(volumeID: location.volumeID, rootBookmark: bookmark, lastKnownRoot: location.lastKnownRoot, relativeRoot: relativeRoot))
        try physicalDirectory(root); return root
    }
    private func validate(_ location: GameLocation, gameID: GameID) throws {
        guard location.relativePath == CrossOverGameBottles.name(for: gameID) + "/game" else { throw issue("Storage", "The saved game folder does not match this installation.") }
    }
    private struct Owner: Codable, Equatable { let gameID: GameID; let token: UUID }
    private func verify(_ container: URL, owner: Owner) throws {
        try physicalDirectory(container)
        let path = container.appendingPathComponent(".bigscreen-install.json")
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              let data = try? Data(contentsOf: path), let saved = try? JSONDecoder().decode(Owner.self, from: data), saved == owner else {
            throw issue("Storage", "This folder does not belong to this installation. Its files have been kept.")
        }
    }
    private func physicalDirectory(_ path: URL) throws {
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw issue("Storage", "The game folder is missing or has become a symbolic link.") }
    }
    private func exists(_ path: URL) -> Bool { var info = stat(); return lstat(path.path, &info) == 0 }
    private func issue(_ stage: String, _ reason: String) -> OperationFailure { .init(stage: stage, reason: reason, output: reason) }
}
