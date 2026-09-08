import Foundation
import Darwin
import CryptoKit
import Domain

/// Recoverable text mirrors of the authoritative diagnostic journal. File errors never alter
/// installation/session state. Reads and rotation are relative to no-follow directory handles.
public actor DiagnosticArchive {
    public nonisolated let root: URL
    private var written: [UUID: Int64] = [:]
    public init(root: URL) { self.root = root }

    public func synchronize(_ catalog: CatalogStore) throws {
        let references = try catalog.diagnosticReferences()
        let directory = try openDirectory(root)
        defer { close(directory) }
        for (gameID, records) in Dictionary(grouping: references, by: \.gameID) {
            let folder = try childDirectory(directory, name: Self.folderName(gameID))
            defer { close(folder) }
            for record in records {
                let name = Self.fileName(record.id)
                if written[record.id] != record.revision || !regularFile(folder, name: name) {
                    guard let log = try catalog.diagnosticLog(record.id) else { continue }
                    try replace(Data(log.text.utf8), directory: folder, name: name)
                    written[record.id] = record.revision
                }
            }
            let retained = Set(records.map { Self.fileName($0.id) })
            for name in try names(folder) where Self.isLogName(name) && !retained.contains(name) {
                // Do not touch links, directories, or unrelated files in the logs folder.
                guard regularFile(folder, name: name) else { continue }
                guard unlinkat(folder, name, 0) == 0 else { throw failure() }
            }
            guard fsync(folder) == 0 else { throw failure() }
        }
        let retainedIDs = Set(references.map(\.id))
        written = written.filter { retainedIDs.contains($0.key) }
        if let failure = catalog.diagnosticWriteFailure { throw failure }
    }

    public func file(for log: DiagnosticLog) throws -> URL {
        let directory = try openDirectory(root)
        defer { close(directory) }
        let folderName = Self.folderName(log.gameID)
        let folder = try childDirectory(directory, name: folderName)
        defer { close(folder) }
        let name = Self.fileName(log.id)
        guard regularFile(folder, name: name) else { throw failure() }
        return root.appendingPathComponent(folderName).appendingPathComponent(name)
    }
    public static func folderName(_ id: GameID) -> String {
        func component(_ text: String) -> String {
            // Hyphens separate source and game; encoding them avoids ambiguous folder names.
            let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
            if !text.isEmpty, text.count <= 64, text.allSatisfy({ allowed.contains($0) }) { return text }
            return "encoded-" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return component(id.source) + "-" + component(id.value)
    }
    private static func fileName(_ id: UUID) -> String { "operation-\(id.uuidString).log" }
    private static func isLogName(_ name: String) -> Bool {
        name.hasPrefix("operation-") && name.hasSuffix(".log") && UUID(uuidString: String(name.dropFirst(10).dropLast(4))) != nil
    }
    private func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw failure() }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw failure() }
        do {
            for component in url.pathComponents.dropFirst() {
                let next = try childDirectory(directory, name: component)
                close(directory); directory = next
            }
            return directory
        } catch { close(directory); throw error }
    }
    private func childDirectory(_ parent: Int32, name: String) throws -> Int32 {
        guard name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw failure() }
        if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw failure() }
        let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw failure() }
        return child
    }
    private func regularFile(_ directory: Int32, name: String) -> Bool {
        var info = stat()
        return fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
    }
    private func replace(_ data: Data, directory: Int32, name: String) throws {
        var existing = stat()
        let found = fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW)
        guard found != 0 ? errno == ENOENT : (existing.st_mode & S_IFMT == S_IFREG && existing.st_nlink == 1) else { throw failure() }
        let temporary = ".pending-\(UUID().uuidString)"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw failure() }
        defer { close(file); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }; offset += count
            }
        }
        guard fsync(file) == 0, renameat(directory, temporary, directory, name) == 0 else { throw failure() }
    }
    private func names(_ directory: Int32) throws -> [String] {
        let copy = dup(directory)
        guard copy >= 0 else { throw failure() }
        guard let stream = fdopendir(copy) else { close(copy); throw failure() }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { guard errno == 0 else { throw failure() }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            result.append(name)
        }
        return result
    }
    private func failure() -> OperationFailure {
        .init(stage: "Write logs", reason: "Logs could not be written. Check the app's storage and try again.", output: "Diagnostic archive filesystem error (\(errno)).")
    }
}
