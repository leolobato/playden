import Foundation
import Darwin
import CryptoKit
import Domain

func saveFailure(_ reason: String) -> OperationFailure {
    .init(stage: "Save files", reason: reason, output: reason)
}

/// All traversal is relative to open directory descriptors. Neither Wine links nor a replaced
/// path component can redirect an in-progress read/write into the user's other files.
final class SaveDirectory {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }
    deinit { close(fd) }
    convenience init(url: URL, create: Bool = false) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw saveFailure("The save folder is invalid.") }
        let root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw Self.posix() }
        let parent = SaveDirectory(fd: root)
        guard let result = try parent.directory(String(url.path.dropFirst()), create: create) else {
            throw saveFailure("The save folder is unavailable.")
        }
        let copied = fcntl(result.fd, F_DUPFD_CLOEXEC, 0)
        guard copied >= 0 else { throw Self.posix() }
        self.init(fd: copied)
    }
    static func components(_ path: String) throws -> [String] {
        if path.isEmpty { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") && !$0.contains(":") }) else {
            throw saveFailure("A save path leaves its designated folder.")
        }
        return parts
    }
    func directory(_ path: String, create: Bool = false) throws -> SaveDirectory? {
        let initial = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard initial >= 0 else { throw Self.posix() }
        var current = SaveDirectory(fd: initial)
        for name in try Self.components(path) {
            if create && mkdirat(current.fd, name, 0o700) != 0 && errno != EEXIST { throw Self.posix() }
            let next = openat(current.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if !create && errno == ENOENT { return nil }
                throw saveFailure("A save folder is inaccessible or is a symbolic link (\(name), error \(errno)). The original files have been kept.")
            }
            current = SaveDirectory(fd: next)
        }
        return current
    }
    func parent(_ path: String, create: Bool = false) throws -> (SaveDirectory, String)? {
        let parts = try Self.components(path)
        guard let name = parts.last else { throw saveFailure("A save filename is missing.") }
        guard let directory = try directory(parts.dropLast().joined(separator: "/"), create: create) else { return nil }
        return (directory, name)
    }
    func info(_ name: String) throws -> stat? {
        guard try Self.components(name).count == 1 else { throw saveFailure("A save filename is invalid.") }
        var value = stat()
        if fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
        if errno == ENOENT { return nil }
        throw Self.posix()
    }
    func names() throws -> [String] {
        // openat creates a separate directory offset; dup alone shares the enumeration cursor.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { throw Self.posix() }
        guard let stream = fdopendir(copy) else { close(copy); throw Self.posix() }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { throw Self.posix() }
                break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw saveFailure("A save filename cannot be read.") }
            if name != "." && name != ".." { result.append(name) }
        }
        return result.sorted()
    }
    func file(_ path: String) throws -> SaveFile? {
        guard let (parent, name) = try parent(path) else { return nil }
        let descriptor = openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw saveFailure("A save file is inaccessible or is a symbolic link.")
        }
        return try SaveFile(fd: descriptor)
    }
    /// Publishes without replacing any existing file. A conflicting restore leaves both copies.
    func write(_ path: String, body: (Int32) throws -> Void) throws {
        guard let (parent, name) = try parent(path, create: true) else { throw Self.posix() }
        let temporary = ".bigscreen-save-\(UUID().uuidString).tmp"
        let descriptor = openat(parent.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.posix() }
        defer { close(descriptor); unlinkat(parent.fd, temporary, 0) }
        try body(descriptor)
        guard fsync(descriptor) == 0 else { throw Self.posix() }
        guard linkat(parent.fd, temporary, parent.fd, name, 0) == 0 else {
            if errno == EEXIST { throw saveFailure("A local save already exists. Both copies have been kept; choose which save to use.") }
            throw Self.posix()
        }
        guard unlinkat(parent.fd, temporary, 0) == 0, fsync(parent.fd) == 0 else { throw Self.posix() }
    }
    func write(_ data: Data, to path: String) throws {
        try write(path) { try Self.writeAll(data, to: $0) }
    }
    /// Only used for this operation's unpublished staging folder, never a game/save source.
    func discardStaging(_ name: String) throws {
        guard name.hasPrefix(".partial-"), UUID(uuidString: String(name.dropFirst(9))) != nil else {
            throw saveFailure("The temporary backup identity is invalid.")
        }
        func removeContents(_ directory: SaveDirectory) throws {
            for child in try directory.names() {
                guard let info = try directory.info(child) else { continue }
                if info.st_mode & S_IFMT == S_IFDIR {
                    guard let nested = try directory.directory(child) else { continue }
                    try removeContents(nested)
                    guard unlinkat(directory.fd, child, AT_REMOVEDIR) == 0 else { throw Self.posix() }
                } else if unlinkat(directory.fd, child, 0) != 0 { throw Self.posix() }
            }
        }
        if let directory = try directory(name) {
            try removeContents(directory)
            guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw Self.posix() }
        }
    }
    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posix() }
                offset += count
            }
        }
    }
    static func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

final class SaveFile {
    let fd: Int32
    private let original: stat
    init(fd: Int32) throws {
        self.fd = fd
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else {
            close(fd)
            throw saveFailure("A save is not a private regular file. The original files have been kept.")
        }
        original = value
    }
    deinit { close(fd) }
    var modifiedAt: Date { Date(timeIntervalSince1970: Double(original.st_mtimespec.tv_sec) + Double(original.st_mtimespec.tv_nsec) / 1e9) }
    func contents(maximum: Int) throws -> Data {
        guard original.st_size <= maximum else { throw saveFailure("The save index is too large.") }
        var output = Data()
        _ = try stream { output.append($0) }
        return output
    }
    func stream(_ consume: (Data) throws -> Void = { _ in }) throws -> SaveDigest {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw SaveDirectory.posix() }
        var sha256 = SHA256(), sha1 = Insecure.SHA1(), bytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw SaveDirectory.posix() }
            if count == 0 { break }
            let data = Data(buffer.prefix(count))
            bytes += Int64(count); sha256.update(data: data); sha1.update(data: data)
            guard bytes <= original.st_size else { throw saveFailure("A save grew while it was being copied. Close the game and try again.") }
            try consume(data)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == original.st_size, bytes == original.st_size,
              after.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec,
              after.st_nlink == 1 else { throw saveFailure("A save changed while it was being copied. Close the game and try again.") }
        return SaveDigest(bytes: bytes, sha256: Data(sha256.finalize()), sha1: Data(sha1.finalize()))
    }
}

struct SaveDigest: Codable, Equatable, Sendable {
    let bytes: Int64
    let sha256: Data
    let sha1: Data
}
