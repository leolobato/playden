import Foundation
import Darwin

/// Every manifest operation is relative to an open destination directory. Parent walks refuse
/// symlinks, and file replacement uses renameat, so a manifest cannot redirect writes outside it.
final class DownloadWorkspace: @unchecked Sendable {
    // Internal fault-injection seam for persistence ordering tests; production uses a no-op.
    enum PersistenceBoundary: Equatable {
        case write(String)
        case fileSync
        case rename(String, String)
        case directorySync
    }
    let diagnostics: SteamPerformanceDiagnostics?
    private let beforePersistence: @Sendable (PersistenceBoundary) throws -> Void
    private let rootHandle: FileHandle
    private var root: Int32 { rootHandle.fileDescriptor }
    private var lease: FileHandle?
    init(destination: URL, lock: Bool = true, diagnostics: SteamPerformanceDiagnostics? = nil,
         beforePersistence: @escaping @Sendable (PersistenceBoundary) throws -> Void = { _ in }) throws {
        self.diagnostics = diagnostics
        self.beforePersistence = beforePersistence
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
        let started = diagnostics?.start()
        defer { diagnostics?.finish(.directoryWalk, since: started) }
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
    func metadata(_ path: String) throws -> DownloadFileMetadata {
        let handle = try openFile(path, flags: O_RDONLY)
        defer { try? handle.close() }
        return try metadata(handle)
    }
    func metadata(_ handle: FileHandle) throws -> DownloadFileMetadata {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw Self.systemError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw SteamError.download("destination is not a private regular file")
        }
        return DownloadFileMetadata(device: info.st_dev, inode: info.st_ino, generation: info.st_gen,
            size: info.st_size, modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec), changeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(info.st_ctimespec.tv_nsec), birthSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
    }
    /// Delete only this depot's private checkpoint tree after it completes. Directory descriptors
    /// stay anchored and symlinks are unlinked, never followed. Receipts and the leased lock survive.
    func cleanCheckpoints(depotID: UInt32, keepingGID: UInt64) throws {
        let (directory, leaf) = try parent(".gn-download/\(depotID)", create: false)
        defer { Darwin.close(directory) }
        try removeTree(at: directory, leaf: leaf)
        try syncDirectory(directory)
        let receipts = openat(directory, "receipts", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if receipts < 0 {
            if errno == ENOENT { return }; throw Self.systemError()
        }
        defer { Darwin.close(receipts) }
        for name in try childNames(receipts) where name.hasPrefix("\(depotID)-") {
            let suffix = String(name.dropFirst("\(depotID)-".count))
            let parts = suffix.components(separatedBy: ".json")
            guard parts.count == 2, let gid = UInt64(parts[0]),
                  parts[1].isEmpty || parts[1].hasPrefix(".new-") else { continue }
            if gid != keepingGID || !parts[1].isEmpty { try removeTree(at: receipts, leaf: name) }
        }
        try syncDirectory(receipts)
    }
    private func childNames(_ directory: Int32) throws -> [String] {
        let fd = dup(directory)
        guard fd >= 0 else { throw Self.systemError() }
        guard let stream = fdopendir(fd) else { Darwin.close(fd); throw Self.systemError() }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw Self.systemError() }; return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }
    private func removeTree(at directory: Int32, leaf: String) throws {
        var info = stat()
        if fstatat(directory, leaf, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }; throw Self.systemError()
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            let fd = openat(directory, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Self.systemError() }
            defer { Darwin.close(fd) }
            for name in try childNames(fd) { try removeTree(at: fd, leaf: name) }
            guard unlinkat(directory, leaf, AT_REMOVEDIR) == 0 || errno == ENOENT else { throw Self.systemError() }
        } else {
            guard unlinkat(directory, leaf, 0) == 0 || errno == ENOENT else { throw Self.systemError() }
        }
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
        var sourceInfo = stat(), destinationInfo = stat()
        guard fstat(from, &sourceInfo) == 0, fstat(to, &destinationInfo) == 0 else { throw Self.systemError() }
        let sameDirectory = sourceInfo.st_dev == destinationInfo.st_dev && sourceInfo.st_ino == destinationInfo.st_ino
        try beforePersistence(.rename(source, destination))
        guard renameat(from, sourceLeaf, to, destinationLeaf) == 0 else { throw Self.systemError() }
        try syncDirectory(to)
        if !sameDirectory { try syncDirectory(from) }
    }
    func writeAtomic(_ data: Data, path: String) throws {
        let temporary = path + ".new-" + UUID().uuidString
        let handle = try openFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL, createParents: true)
        defer { try? handle.close(); try? remove(temporary) }
        try write(data, to: handle, path: path)
        try syncFile(handle)
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
        try syncDirectory(directory)
    }
    func symlinkTarget(_ path: String) throws -> String {
        let (directory, leaf) = try parent(path, create: false)
        defer { Darwin.close(directory) }
        var buffer = [UInt8](repeating: 0, count: 32768)
        let count = readlinkat(directory, leaf, &buffer, buffer.count)
        guard count >= 0, count < buffer.count else { throw Self.systemError() }
        return String(decoding: buffer.prefix(count), as: UTF8.self)
    }
    func write(_ data: Data, to handle: FileHandle, path: String) throws {
        try beforePersistence(.write(path))
        try diagnostics.measure(.fileWrite, bytes: UInt64(data.count)) { try handle.write(contentsOf: data) }
    }
    func syncFile(_ handle: FileHandle) throws {
        try beforePersistence(.fileSync)
        try Self.sync(handle, diagnostics: diagnostics)
    }
    static func sync(_ handle: FileHandle, diagnostics: SteamPerformanceDiagnostics? = nil) throws {
        // Download bytes are revalidated against their chunk hashes on resume. fsync
        // orders data before its journal without forcing a drive-wide cache flush
        // for every checkpoint (F_FULLFSYNC can stall USB/HFS+ drives for minutes).
        try diagnostics.measure(.fileSync) { try handle.synchronize() }
    }
    private func syncDirectory(_ fd: Int32) throws {
        let started = diagnostics?.start()
        defer { diagnostics?.finish(.directorySync, since: started) }
        try beforePersistence(.directorySync)
        if fsync(fd) == -1 && errno != EINVAL && errno != ENOTSUP { throw Self.systemError() }
    }
    private static func systemError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
