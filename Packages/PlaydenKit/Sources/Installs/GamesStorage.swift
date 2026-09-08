import Foundation
import Darwin
import Domain

/// Uses the same remaining-space policy for the install offer, worker and Downloads display.
public enum InstallReservations {
    public static func bytes(_ jobs: [JobRecord], on volumeID: String, excluding id: UUID? = nil) -> Int64 {
        jobs.filter { $0.id != id && $0.volume?.volumeID == volumeID && $0.kind == .install && ![.completed, .cancelled].contains($0.state) }
            .reduce(0) { sum, job in
                let required = max(0, job.plan?.estimate.requiredBytes ?? 0)
                return adding(sum, max(0, required - max(0, job.bytesCompleted)))
            }
    }
    static func adding(_ a: Int64, _ b: Int64) -> Int64 {
        let sum = a.addingReportingOverflow(b); return sum.overflow ? Int64.max : sum.partialValue
    }
}

public struct GamesStorageSnapshot: Equatable, Sendable {
    public let volumeID: String
    public let name: String
    public let root: URL
    public let totalBytes: Int64
    public let freeBytes: Int64
    /// Allocated game-file bytes, including partial downloads; nil when a folder cannot be measured.
    public let gamesBytes: Int64?
    public let reservedBytes: Int64
    public var availableBytes: Int64 { max(0, freeBytes - reservedBytes) }
    public var shortageBytes: Int64 { max(0, reservedBytes - freeBytes) }
    public var otherBytes: Int64 { max(0, totalBytes - freeBytes - (gamesBytes ?? 0)) }
    public init(volumeID: String, name: String, root: URL, totalBytes: Int64, freeBytes: Int64, gamesBytes: Int64?, reservedBytes: Int64) {
        self.volumeID = volumeID; self.name = name; self.root = root
        self.totalBytes = max(0, totalBytes); self.freeBytes = min(max(0, freeBytes), max(0, totalBytes))
        let used = self.totalBytes - self.freeBytes
        self.gamesBytes = gamesBytes.map { min(max(0, $0), used) }
        self.reservedBytes = max(0, reservedBytes)
    }
}

public protocol GamesStorageReading: Sendable {
    func snapshot(on selection: GamesVolumeSelection, installations: [InstallationRecord], jobs: [JobRecord]) async throws -> GamesStorageSnapshot
}

/// Read-only inspection runs off the UI actor. Only verified owned locations are included.
public actor GamesStorageReader: GamesStorageReading {
    private let volumes: any VolumeManaging
    private let storage: any InstallStorageManaging
    public init(volumes: any VolumeManaging = GamesVolumeStore(), storage: (any InstallStorageManaging)? = nil) {
        self.volumes = volumes; self.storage = storage ?? InstallStorage(volumes: volumes)
    }
    public func snapshot(on selection: GamesVolumeSelection, installations: [InstallationRecord], jobs: [JobRecord]) async throws -> GamesStorageSnapshot {
        let root = try await volumes.resolve(selection)
        let values = try root.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        guard let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) else {
            throw OperationFailure(stage: "Storage", reason: "Storage information is unavailable. Check your games drive and try again.", output: "Volume capacity was not reported.")
        }
        var locations = installations.filter { $0.location.volumeID == selection.volumeID }.map { ($0.gameID, $0.ownershipToken, $0.location) }
        locations += jobs.filter { ![.completed, .cancelled].contains($0.state) && $0.location?.volumeID == selection.volumeID }
            .compactMap { job in job.location.map { (job.gameID, job.ownershipToken, $0) } }
        var seen: Set<UUID> = [], files: Set<FileIdentity> = [], bytes: Int64 = 0, incomplete = false
        for (game, owner, location) in locations where seen.insert(owner).inserted {
            try Task.checkCancellation()
            do {
                let directory = try await storage.directory(location, gameID: game, owner: owner)
                bytes = InstallReservations.adding(bytes, try Self.allocatedBytes(in: directory, seen: &files))
            } catch is CancellationError { throw CancellationError() }
            catch { incomplete = true }
        }
        // A drive removed/replaced during enumeration must not leave apparently current figures.
        _ = try await volumes.resolve(selection)
        try Task.checkCancellation()
        return .init(volumeID: selection.volumeID, name: values.volumeName ?? root.lastPathComponent, root: root,
            totalBytes: Int64(total), freeBytes: free, gamesBytes: incomplete ? nil : bytes,
            reservedBytes: InstallReservations.bytes(jobs, on: selection.volumeID))
    }
    private struct FileIdentity: Hashable { let device: dev_t; let inode: ino_t }
    private static func allocatedBytes(in root: URL, seen: inout Set<FileIdentity>) throws -> Int64 {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
        return try walk(fd, device: info.st_dev, seen: &seen, depth: 0)
    }
    private static func walk(_ fd: Int32, device: dev_t, seen: inout Set<FileIdentity>, depth: Int) throws -> Int64 {
        guard depth < 128 else { throw POSIXError(.ELOOP) }
        let copy = dup(fd); guard copy >= 0 else { throw POSIXError(.EIO) }
        guard let directory = fdopendir(copy) else { close(copy); throw POSIXError(.EIO) }
        defer { closedir(directory) }
        var bytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw POSIXError(.EIO) }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError(.EIO) }
            guard info.st_dev == device else { throw POSIXError(.EXDEV) }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw POSIXError(.EIO) }
                defer { close(child) }
                bytes = InstallReservations.adding(bytes, try walk(child, device: device, seen: &seen, depth: depth + 1))
            case S_IFREG:
                if seen.insert(.init(device: info.st_dev, inode: info.st_ino)).inserted {
                    let allocation = max(0, info.st_blocks).multipliedReportingOverflow(by: 512)
                    bytes = InstallReservations.adding(bytes, allocation.overflow ? Int64.max : allocation.partialValue)
                }
            default: break // Symlinks (including Wine links), sockets and devices are never followed.
            }
        }
        return bytes
    }
}
