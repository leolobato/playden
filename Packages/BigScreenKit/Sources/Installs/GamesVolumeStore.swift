import Foundation
import Domain

public actor GamesVolumeStore: VolumeManaging {
    private let files = FileManager.default
    private let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    private let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeURLKey, .volumeNameKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
    public func availableVolumes() throws -> [GamesVolume] {
        let homeValues = try home.resourceValues(forKeys: keys)
        let mounted = files.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        var result: [GamesVolume] = []
        for path in [home] + mounted {
            guard let values = try? path.resourceValues(forKeys: keys), values.volumeIsLocal == true,
                  values.volumeIsReadOnly != true, let id = values.volumeUUIDString, !result.contains(where: { $0.id == id }) else { continue }
            let isHome = id == homeValues.volumeUUIDString
            let mount = values.volume ?? path
            let root = isHome ? home.appendingPathComponent("Games/GameNative", isDirectory: true) : mount.appendingPathComponent("GameNative/games", isDirectory: true)
            guard files.isWritableFile(atPath: path.path) else { continue }
            result.append(GamesVolume(id: id, name: isHome ? "This Mac" : values.volumeName ?? mount.lastPathComponent,
                mountURL: mount, gamesRoot: root, freeBytes: max(0, values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)),
                isRecommended: mount.path == "/Volumes/VM"))
        }
        if !result.contains(where: \.isRecommended), !result.isEmpty { result[0].isRecommended = true }
        return result.sorted { $0.isRecommended && !$1.isRecommended }
    }
    public func select(_ volume: GamesVolume) throws -> GamesVolumeSelection {
        guard let current = try availableVolumes().first(where: { $0.id == volume.id }), current.gamesRoot == volume.gamesRoot else { throw unavailable() }
        try files.createDirectory(at: current.gamesRoot, withIntermediateDirectories: true)
        try validate(current.gamesRoot, volumeID: current.id)
        let probe = current.gamesRoot.appendingPathComponent(".bigscreen-write-check-\(UUID().uuidString)")
        try Data().write(to: probe, options: .withoutOverwriting)
        try files.removeItem(at: probe)
        let bookmark = try current.gamesRoot.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: keys, relativeTo: nil)
        let mountPath = current.mountURL.resolvingSymlinksInPath().path
        let rootPath = current.gamesRoot.resolvingSymlinksInPath().path
        guard rootPath.hasPrefix(mountPath == "/" ? "/" : mountPath + "/") else { throw unavailable() }
        let relative = String(rootPath.dropFirst(mountPath == "/" ? 1 : mountPath.count + 1))
        return GamesVolumeSelection(volumeID: current.id, rootBookmark: bookmark, lastKnownRoot: current.gamesRoot, relativeRoot: relative)
    }
    public func resolve(_ selection: GamesVolumeSelection) throws -> URL {
        var stale = false
        if let root = try? URL(resolvingBookmarkData: selection.rootBookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
           (try? validate(root, volumeID: selection.volumeID)) != nil { return root }
        // Never reuse a mount path merely because another disk has appeared there.
        guard !selection.relativeRoot.hasPrefix("/"), !selection.relativeRoot.split(separator: "/").contains(".."),
              let mounted = try availableVolumes().first(where: { $0.id == selection.volumeID }) else { throw unavailable() }
        let root = mounted.mountURL.appendingPathComponent(selection.relativeRoot, isDirectory: true)
        try validate(root, volumeID: selection.volumeID)
        return root
    }
    private func validate(_ root: URL, volumeID: String) throws {
        let values = try root.resourceValues(forKeys: keys.union([.isDirectoryKey]))
        guard values.isDirectory == true, values.volumeUUIDString == volumeID, values.volumeIsLocal == true,
              values.volumeIsReadOnly != true, files.isWritableFile(atPath: root.path) else { throw unavailable() }
    }
    private func unavailable() -> OperationFailure {
        OperationFailure(stage: "Games volume", reason: "Reconnect your games drive, or choose another volume.", output: "The saved volume identity or writable games folder could not be verified.")
    }
}
