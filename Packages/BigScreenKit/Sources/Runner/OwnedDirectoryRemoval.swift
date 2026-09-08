import Foundation
import Darwin
import Domain

/// Keeps ownership outside the directory being deleted. A partial recursive deletion may remove
/// the internal owner marker first; the device/inode receipt then permits only that same directory
/// to be retried. It never authorizes a replacement directory at the old path.
public struct OwnedDirectoryRemoval<Owner: Codable & Equatable & Sendable>: Sendable {
    public let directory: URL
    private let receipt: URL
    private let owner: Owner
    public init(directory: URL, receipt: URL, owner: Owner) {
        self.directory = directory; self.receipt = receipt; self.owner = owner
    }
    private struct Receipt: Codable, Equatable { let owner: Owner; let path: String; let device: UInt64; let inode: UInt64 }
    public var isPending: Bool { exists(receipt) }

    /// Caller verifies its internal ownership marker before a new receipt can be created.
    public func begin(verifyOwnership: () throws -> Void) throws {
        if isPending { try verify(); return }
        guard exists(directory) else { return }
        try verifyOwnership()
        let value = try identity()
        try Task.checkCancellation()
        let temporary = receipt.deletingLastPathComponent().appendingPathComponent(".removal-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try JSONEncoder().encode(value).write(to: temporary, options: .withoutOverwriting)
        try synchronize(temporary)
        guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, receipt.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try synchronize(receipt.deletingLastPathComponent())
        try verify()
    }
    public func verify() throws {
        guard isPending else {
            guard !exists(directory) else { throw issue() }; return
        }
        let saved = try read()
        guard saved.owner == owner, saved.path == directory.standardizedFileURL.path else { throw issue() }
        if exists(directory) { guard try identity() == saved else { throw issue() } }
    }
    /// For a non-runtime folder, or after a runtime's removal command left an incomplete folder.
    public func removeRemainingFiles() throws {
        try verify(); try Task.checkCancellation()
        if exists(directory) { try FileManager.default.removeItem(at: directory) }
        try verify()
        guard !exists(directory) else { throw issue() }
    }
    public func finish() throws {
        try verify()
        guard !exists(directory) else { throw issue() }
        if isPending { try FileManager.default.removeItem(at: receipt); try synchronize(receipt.deletingLastPathComponent()) }
    }
    private func identity() throws -> Receipt {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw issue() }
        return Receipt(owner: owner, path: directory.standardizedFileURL.path, device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
    }
    private func read() throws -> Receipt {
        let fd = open(receipt.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw issue() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 64 * 1024,
              let data = try file.readToEnd(), let value = try? JSONDecoder().decode(Receipt.self, from: data) else { throw issue() }
        return value
    }
    private func synchronize(_ path: URL) throws {
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func exists(_ path: URL) -> Bool { var info = stat(); return lstat(path.path, &info) == 0 }
    private func issue() -> Domain.OperationFailure {
        .init(stage: "Uninstall", reason: "The folder's removal ownership changed. Its remaining files have been kept.", output: "")
    }
}
