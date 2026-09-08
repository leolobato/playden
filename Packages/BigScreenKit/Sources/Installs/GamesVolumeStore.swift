import Foundation
import Domain
import Runner

public actor GamesVolumeStore: VolumeManaging {
    private let files = FileManager.default
    private let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    private let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeURLKey, .volumeNameKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey]
    public func availableVolumes() throws -> [GamesVolume] {
        let homeValues = try home.resourceValues(forKeys: keys)
        let mounted = files.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        var result: [GamesVolume] = []
        for path in [home] + mounted {
            guard let values = try? path.resourceValues(forKeys: keys), values.volumeIsLocal == true,
                  values.volumeIsReadOnly != true, let id = values.volumeUUIDString, !result.contains(where: { $0.id == id }) else { continue }
            let isHome = id == homeValues.volumeUUIDString
            let mount = values.volume ?? path
            let root = isHome ? home.appendingPathComponent("Games/Big Screen", isDirectory: true) : mount.appendingPathComponent("Big Screen/games", isDirectory: true)
            guard files.isWritableFile(atPath: path.path) else { continue }
            result.append(GamesVolume(id: id, name: isHome ? "This Mac" : values.volumeName ?? mount.lastPathComponent,
                mountURL: mount, gamesRoot: root, freeBytes: max(0, values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)),
                totalBytes: values.volumeTotalCapacity.map(Int64.init), isRecommended: mount.path == "/Volumes/VM"))
        }
        if !result.contains(where: \.isRecommended), !result.isEmpty { result[0].isRecommended = true }
        return result.sorted { $0.isRecommended && !$1.isRecommended }
    }
    public func select(_ volume: GamesVolume) async throws -> GamesVolumeSelection {
        guard let current = try availableVolumes().first(where: { $0.id == volume.id }), current.gamesRoot == volume.gamesRoot else { throw unavailable() }
        // Filesystem access can wait indefinitely for a macOS removable-volume prompt. Keep those
        // writes in cancellable child processes attributed to this app, with a finite deadline.
        try await checkWriteCommand("/bin/mkdir", ["-p", current.gamesRoot.path])
        try validate(current.gamesRoot, volumeID: current.id)
        let result = try await checkWriteCommand("/usr/bin/mktemp", [current.gamesRoot.appendingPathComponent(".bigscreen-write-check.XXXXXXXX").path])
        let probe = URL(fileURLWithPath: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        guard probe.deletingLastPathComponent().standardizedFileURL == current.gamesRoot.standardizedFileURL,
              probe.lastPathComponent.hasPrefix(".bigscreen-write-check.") else { throw unavailable() }
        try files.removeItem(at: probe)
        let bookmark = try current.gamesRoot.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: keys, relativeTo: nil)
        let mountPath = current.mountURL.resolvingSymlinksInPath().path
        let rootPath = current.gamesRoot.resolvingSymlinksInPath().path
        guard rootPath.hasPrefix(mountPath == "/" ? "/" : mountPath + "/") else { throw unavailable() }
        let relative = String(rootPath.dropFirst(mountPath == "/" ? 1 : mountPath.count + 1))
        return GamesVolumeSelection(volumeID: current.id, rootBookmark: bookmark, lastKnownRoot: current.gamesRoot, relativeRoot: relative)
    }
    @discardableResult private func checkWriteCommand(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        let result = try await CommandExecutor().run(executable: URL(fileURLWithPath: executable), arguments: arguments, timeout: 20)
        if result.cancelled { throw OperationFailure(stage: "Games volume", reason: "Drive selection was stopped. You can choose another drive.", output: result.output) }
        if result.timedOut { throw OperationFailure(stage: "Games volume", reason: "The drive did not respond. Check any macOS access prompt, or choose another drive.", output: result.output) }
        guard result.exitCode == 0 else { throw OperationFailure(stage: "Games volume", reason: "Big Screen couldn’t write to this drive. Allow access in macOS settings, or choose another drive.", output: result.output) }
        try Task.checkCancellation()
        return result
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
