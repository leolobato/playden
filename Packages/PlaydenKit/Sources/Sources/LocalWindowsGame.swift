import Foundation
import Domain

/// A Windows game folder on this Mac. Playden runs it in its own bottle, from the folder or from a
/// copy in Playden storage (PRD 08 §10).
public enum LocalWindowsGame {
    public struct Executable: Equatable, Sendable, Identifiable {
        public var id: String { relativePath }
        /// Inside the game folder, with `/` separators.
        public let relativePath: String
        public let bytes: Int64
        /// Uninstallers, installers, redistributables and crash handlers: listed last.
        public let isLikelyHelper: Bool
    }

    /// Executables in the folder, likely game executables first.
    public static func executables(in folder: URL, depth: Int = 4) -> [Executable] {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [Executable] = []
        for case let url as URL in walker {
            if walker.level > depth { walker.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "exe",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            found.append(Executable(relativePath: relative, bytes: Int64(values.fileSize ?? 0), isLikelyHelper: isLikelyHelper(relative)))
        }
        let title = self.title(for: folder).lowercased().filter(\.isLetter)
        func matchesTitle(_ executable: Executable) -> Bool {
            let name = URL(fileURLWithPath: executable.relativePath).deletingPathExtension().lastPathComponent.lowercased().filter(\.isLetter)
            return !title.isEmpty && !name.isEmpty && (name.contains(title) || title.contains(name))
        }
        return found.sorted { a, b in
            if a.isLikelyHelper != b.isLikelyHelper { return !a.isLikelyHelper }
            if matchesTitle(a) != matchesTitle(b) { return matchesTitle(a) }
            let depthA = a.relativePath.split(separator: "/").count, depthB = b.relativePath.split(separator: "/").count
            if depthA != depthB { return depthA < depthB }
            if a.bytes != b.bytes { return a.bytes > b.bytes }
            return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
        }
    }
    static func isLikelyHelper(_ relativePath: String) -> Bool {
        let parts = relativePath.lowercased().split(separator: "/")
        let name = String(parts.last ?? "")
        let helperNames = ["unins", "setup", "install", "vcredist", "vc_redist", "dxsetup", "dxwebsetup", "directx", "dotnet", "ndp",
                           "physx", "oalinst", "crash", "unitycrashhandler", "bugreport", "errorreport", "reporter", "redist", "ue4prereq",
                           "easyanticheat", "battleye", "uninstall", "update", "patch", "config", "settings", "dxsdk"]
        let helperFolders = ["_redist", "redist", "_commonredist", "commonredist", "redistributables", "__installer", "directx",
                             "support", "dotnet", "vcredist", "_installer", "installers", "easyanticheat", "battleye"]
        return helperNames.contains { name.hasPrefix($0) } || parts.dropLast().contains { helperFolders.contains(String($0)) }
    }
    /// The folder name, or its parent's when the folder has a generic name such as `game` or `bin`.
    public static func title(for folder: URL) -> String {
        let generic: Set<String> = ["game", "games", "bin", "bin32", "bin64", "x64", "x86", "win32", "win64", "binaries", "app", "files", "data"]
        let name = folder.lastPathComponent
        let parent = folder.deletingLastPathComponent().lastPathComponent
        return generic.contains(name.lowercased()) && !parent.isEmpty && parent != "/" ? parent : name
    }

    /// Recorded when the copy is planned, so the copy can resume and be checked without the original.
    struct Payload: Codable, Equatable {
        struct File: Codable, Equatable { let path: String; let bytes: Int64 }
        var version = 1
        let executable: String
        /// Nil for a game that plays from its folder.
        let files: [File]?
    }
    static func launchSpec(executable: String) -> LaunchSpec {
        let folder = (executable as NSString).deletingLastPathComponent
        return LaunchSpec(executableRelativePath: executable, workingDirectoryRelativePath: folder.isEmpty ? "." : folder)
    }
    /// The plan for a game that plays from its folder. It is rebuilt on every scan, so it must not change between scans.
    static func inPlacePlan(for game: SourceGameRecord, executable: String, token: UUID, addedAt: Date) -> InstallPlan {
        InstallPlan(id: token, game: game, manifestIDs: [:], estimate: InstallEstimate(downloadBytes: 0, installedBytes: 0, requiredBytes: 0),
                    launchSpec: launchSpec(executable: executable), sourcePayload: (try? JSONEncoder().encode(Payload(executable: executable, files: nil))) ?? Data(),
                    resolvedAt: addedAt, platform: .windows)
    }
    /// Regular files under the folder, skipping hidden files. Links are followed only when they stay inside.
    static func files(in folder: URL) throws -> [Payload.File] {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            throw OperationFailure(stage: "Resolve", reason: "Playden can’t read the game’s folder.", output: folder.path)
        }
        var files: [Payload.File] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(root.path + "/") else { continue }
            files.append(.init(path: String(url.standardizedFileURL.path.dropFirst(root.path.count + 1)), bytes: Int64(values.fileSize ?? 0)))
        }
        return files.sorted { $0.path < $1.path }
    }
}

/// Copies a Windows game folder into Playden storage, or checks one that plays from its folder.
/// The queue owns the folder, the bottle and the catalog; this only moves and checks files.
struct LocalWindowsInstaller: Installer {
    let gameID: GameID
    let game: SourceGameRecord
    let store: LocalLibraryStore

    private func entry() async throws -> LocalLibrary.Entry {
        guard let entry = try await store.load().entries.first(where: { $0.id == gameID.value }), entry.isWindows else {
            throw OperationFailure(stage: "Resolve", reason: "This game is no longer in your library.", output: "")
        }
        return entry
    }
    private func sourceFolder() async throws -> URL {
        let entry = try await entry()
        guard let folder = LocalSource.resolve(entry).url else {
            throw OperationFailure(stage: "Copy files", reason: "Playden can’t find the game’s original folder. Connect its drive or locate it, then try again.",
                                   output: entry.lastKnownPath.path)
        }
        return folder
    }
    private func payload(_ plan: InstallPlan) throws -> LocalWindowsGame.Payload {
        guard let payload = try? JSONDecoder().decode(LocalWindowsGame.Payload.self, from: plan.sourcePayload), payload.version == 1 else {
            throw OperationFailure(stage: "Resolve", reason: "The saved copy plan is unreadable. Cancel and copy the game again.", output: "")
        }
        return payload
    }

    func resolve() async throws -> InstallPlan {
        let entry = try await entry()
        guard let executable = entry.windowsExecutable, let token = entry.ownershipToken else { throw OperationFailure(stage: "Resolve", reason: "This game has no executable.", output: "") }
        let files = try LocalWindowsGame.files(in: try await sourceFolder())
        guard files.contains(where: { $0.path == executable }) else {
            throw OperationFailure(stage: "Resolve", reason: "\(executable) is no longer in the game’s folder.", output: executable)
        }
        let bytes = files.reduce(Int64(0)) { $0 + $1.bytes }
        return InstallPlan(game: game, manifestIDs: ["files": token.uuidString], estimate: InstallEstimate(downloadBytes: bytes, installedBytes: bytes, requiredBytes: bytes),
                           launchSpec: LocalWindowsGame.launchSpec(executable: executable),
                           sourcePayload: try JSONEncoder().encode(LocalWindowsGame.Payload(executable: executable, files: files)), platform: .windows)
    }

    func download(_ plan: InstallPlan, to directory: URL, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        guard let files = try payload(plan).files else { throw OperationFailure(stage: "Copy files", reason: "This game plays from its folder and has nothing to copy.", output: "") }
        let source = try await sourceFolder()
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let from = source.appendingPathComponent(file.path), to = directory.appendingPathComponent(file.path)
            guard to.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
            // A file of the planned size is already copied, so Resume continues where it stopped.
            if (try? to.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == file.bytes {
                completed += file.bytes
                progress(InstallProgress(bytesCompleted: completed, bytesTotal: total, currentFile: file.path, downloadedBytes: completed))
                continue
            }
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
            guard let input = InputStream(url: from), let output = OutputStream(url: to, append: false) else {
                throw OperationFailure(stage: "Copy files", reason: "Playden can’t read \(file.path).", output: from.path)
            }
            input.open(); output.open()
            defer { input.close(); output.close() }
            var buffer = [UInt8](repeating: 0, count: 4 << 20)
            var copied: Int64 = 0
            while true {
                try Task.checkCancellation()
                let read = input.read(&buffer, maxLength: buffer.count)
                if read < 0 { throw input.streamError ?? CocoaError(.fileReadUnknown) }
                if read == 0 { break }
                var offset = 0
                while offset < read {
                    let written = buffer[offset..<read].withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: read - offset) }
                    if written <= 0 { throw output.streamError ?? CocoaError(.fileWriteUnknown) }
                    offset += written
                }
                copied += Int64(read)
                progress(InstallProgress(bytesCompleted: completed + copied, bytesTotal: total, currentFile: file.path, downloadedBytes: completed + copied))
            }
            guard copied == file.bytes else {
                throw OperationFailure(stage: "Copy files", reason: "\(file.path) changed while it was being copied. Retry to copy it again.", output: from.path)
            }
            completed += copied
        }
    }

    func verifyOriginals(_ plan: InstallPlan, at directory: URL, staging: InstallStaging?) async throws -> VerificationResult {
        guard let files = try payload(plan).files else { return VerificationResult() }
        return VerificationResult(invalidFiles: files.filter { file in
            (try? directory.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) != file.bytes
        }.map(\.path))
    }
    func postInstall(_ plan: InstallPlan, at directory: URL) async throws -> InstallStaging { InstallStaging() }
    func validate(_ plan: InstallPlan, at directory: URL, staging: InstallStaging) async throws -> LaunchSpec {
        let executable = try payload(plan).executable
        guard (try? directory.appendingPathComponent(executable).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw OperationFailure(stage: "Verify", reason: "\(executable) is missing from the game’s folder.", output: directory.path)
        }
        return plan.launchSpec
    }
    func uninstall(_ plan: InstallPlan, at directory: URL) async throws {}
}
