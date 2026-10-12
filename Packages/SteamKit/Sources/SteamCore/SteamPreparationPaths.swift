import Foundation
import Darwin

/// Authorizes only the files an uninterrupted preparation operation uses. Retain this value
/// across awaited tools, then check again: a new directory at the same path is not the same game.
/// This is path validation, not a recursive asset scan or a cache of earlier authorization.
public struct SteamPreparationPaths: Sendable {
    public let root: URL
    private let device: dev_t
    private let inode: ino_t

    public init(root: URL) throws {
        self.root = try Self.storageURL(root)
        try Self.checkComponents(self.root, directory: true)
        guard let info = try Self.metadata(self.root) else { throw SteamError.prepare("game directory is unavailable") }
        device = info.st_dev; inode = info.st_ino
    }

    public func checkRoot() throws {
        try Self.checkComponents(root, directory: true)
        guard let info = try Self.metadata(root), info.st_dev == device, info.st_ino == inode else {
            throw SteamError.prepare("the installation directory changed during preparation")
        }
    }

    /// Missing leaves/parents may be created after this check. Existing files must be private
    /// regular files; existing parents must be directories, never links (including dangling ones).
    public func check(_ url: URL, directory: Bool = false) throws {
        try checkRoot()
        let target = try Self.storageURL(url), prefix = root.path == "/" ? "/" : root.path + "/"
        guard target.path == root.path || target.path.hasPrefix(prefix) else {
            throw SteamError.prepare("a preparation path leaves the installation folder")
        }
        try Self.checkComponents(target, directory: directory)
    }

    /// Saves and temporary workspaces have declared storage destinations outside the game.
    /// Validate their entire parent chain before creating them; allow macOS's standard aliases.
    public static func checkStorageDirectory(_ url: URL) throws {
        try checkComponents(storageURL(url), directory: true)
    }

    private static func storageURL(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.pathComponents.contains(".."), !url.pathComponents.contains("."),
              !url.path.contains("\0") else { throw SteamError.prepare("invalid preparation path") }
        let path = url.standardizedFileURL.path
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: alias)
            if target == "private" + alias || target == "/private" + alias {
                return URL(fileURLWithPath: "/private" + alias + path.dropFirst(alias.count))
            }
        }
        return url.standardizedFileURL
    }

    private static func metadata(_ url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func checkComponents(_ url: URL, directory: Bool) throws {
        let parts = url.pathComponents.dropFirst()
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(part)
            guard let info = try metadata(current) else { continue }
            let requiresDirectory = index < parts.count - 1 || directory
            guard requiresDirectory ? info.st_mode & S_IFMT == S_IFDIR
                : (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1) else {
                throw SteamError.prepare("a preparation path is linked or has an unexpected file type: \(current.path)")
            }
        }
    }
}
