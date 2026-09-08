import Foundation
import Darwin

/// Every manifest operation is relative to an open destination directory. Parent walks refuse
/// symlinks, and file replacement uses renameat, so a manifest cannot redirect writes outside it.
final class DownloadWorkspace: @unchecked Sendable {
    private let rootHandle: FileHandle
    private var root: Int32 { rootHandle.fileDescriptor }
    private var lease: FileHandle?
    init(destination: URL, lock: Bool = true) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        let fd = Darwin.open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.systemError() }
        rootHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if lock {
            lease = try openFile(".gn-download/lock", flags: O_RDWR | O_CREAT, createParents: true)
            guard flock(lease!.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw SteamError.download("another download is using this destination") }
        }
    }
    deinit {
        if let lease { flock(lease.fileDescriptor, LOCK_UN); try? lease.close() }
    }
    static func path(_ raw: String, allowState: Bool = false) throws -> String {
        let path = raw.replacingOccurrences(of: "\\", with: "/")
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              allowState || parts[0].lowercased() != ".gn-download" else { throw SteamError.download("invalid manifest path: \(raw)") }
        return path
    }
    private func parent(_ path: String, create: Bool) throws -> (Int32, String) {
        let normalized = try Self.path(path, allowState: true)
        var parts = normalized.split(separator: "/").map(String.init)
        let leaf = parts.removeLast()
        var directory = dup(root)
        guard directory >= 0 else { throw Self.systemError() }
        do {
            for part in parts {
                if create && mkdirat(directory, part, 0o755) != 0 && errno != EEXIST { throw Self.systemError() }
                let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw SteamError.download("unsafe or missing destination directory: \(path)") }
                Darwin.close(directory); directory = next
            }
            return (directory, leaf)
        } catch { Darwin.close(directory); throw error }
    }
    func openFile(_ path: String, flags: Int32, createParents: Bool = false) throws -> FileHandle {
        let (directory, leaf) = try parent(path, create: createParents)
        defer { Darwin.close(directory) }
        let fd = openat(directory, leaf, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.systemError() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(fd); throw SteamError.download("destination is not a private regular file: \(path)")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    func makeDirectory(_ path: String) throws {
        let (directory, leaf) = try parent(path, create: true)
        defer { Darwin.close(directory) }
        if mkdirat(directory, leaf, 0o755) != 0 && errno != EEXIST { throw Self.systemError() }
        let check = openat(directory, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard check >= 0 else { throw SteamError.download("manifest directory is a link or file: \(path)") }
        Darwin.close(check)
    }
    func remove(_ path: String) throws {
        let (directory, leaf) = try parent(path, create: false)
        defer { Darwin.close(directory) }
        if unlinkat(directory, leaf, 0) != 0 && errno != ENOENT { throw Self.systemError() }
    }
    func replace(_ source: String, withDestination destination: String) throws {
        let (from, sourceLeaf) = try parent(source, create: false)
        defer { Darwin.close(from) }
        let (to, destinationLeaf) = try parent(destination, create: true)
        defer { Darwin.close(to) }
        guard renameat(from, sourceLeaf, to, destinationLeaf) == 0 else { throw Self.systemError() }
        try Self.syncDirectory(to)
        try Self.syncDirectory(from)
    }
    func writeAtomic(_ data: Data, path: String) throws {
        let temporary = path + ".new-" + UUID().uuidString
        let handle = try openFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL, createParents: true)
        defer { try? handle.close(); try? remove(temporary) }
        try handle.write(contentsOf: data)
        try Self.sync(handle)
        try replace(temporary, withDestination: path)
    }
    func read(_ path: String, limit: Int = 16 * 1024 * 1024) throws -> Data {
        let handle = try openFile(path, flags: O_RDONLY)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw SteamError.download("download checkpoint is too large") }
        return data
    }
    func createSymlink(_ link: String, path: String) throws {
        let (directory, leaf) = try parent(path, create: true)
        defer { Darwin.close(directory) }
        let temporary = ".gn-link-" + UUID().uuidString
        guard symlinkat(link, directory, temporary) == 0 else { throw Self.systemError() }
        defer { unlinkat(directory, temporary, 0) }
        guard renameat(directory, temporary, directory, leaf) == 0 else { throw Self.systemError() }
        try Self.syncDirectory(directory)
    }
    func symlinkTarget(_ path: String) throws -> String {
        let (directory, leaf) = try parent(path, create: false)
        defer { Darwin.close(directory) }
        var buffer = [UInt8](repeating: 0, count: 32768)
        let count = readlinkat(directory, leaf, &buffer, buffer.count)
        guard count >= 0, count < buffer.count else { throw Self.systemError() }
        return String(decoding: buffer.prefix(count), as: UTF8.self)
    }
    static func sync(_ handle: FileHandle) throws {
        // Download bytes are revalidated against their chunk hashes on resume. fsync
        // orders data before its journal without forcing a drive-wide cache flush
        // for every checkpoint (F_FULLFSYNC can stall USB/HFS+ drives for minutes).
        try handle.synchronize()
    }
    private static func syncDirectory(_ fd: Int32) throws {
        if fsync(fd) == -1 && errno != EINVAL && errno != ENOTSUP { throw systemError() }
    }
    private static func systemError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
