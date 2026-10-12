import Foundation
import CryptoKit

/// An optimization for normal resume, not a content-integrity guarantee. Full verification
/// remains available for corruption that preserves filesystem identity and timestamps.
struct DownloadFileMetadata: Codable, Hashable, Sendable {
    let device: Int32
    let inode: UInt64
    let generation: UInt32
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
}

struct DownloadCompletionReceipt: Codable {
    var version = 1
    let depotID: UInt32
    let gid: UInt64
    var entries: [String: Entry] = [:]
    struct Entry: Codable {
        let fingerprint: Data
        let metadata: DownloadFileMetadata
    }
}

/// One store is shared by all workers in a download. The lock serializes both mutations and
/// atomic snapshots, so a late checkpoint cannot overwrite a newer worker's completion.
final class DownloadCompletionReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private let workspace: DownloadWorkspace
    let path: String
    private var receipt: DownloadCompletionReceipt
    private var dirty = false
    private var bytesSinceCheckpoint: UInt64 = 0
    private var lastCheckpoint: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant

    init(workspace: DownloadWorkspace, manifest: DepotManifest, sizingManifest: DepotManifest? = nil,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) throws {
        if let sizingManifest, sizingManifest.depotID != manifest.depotID || sizingManifest.gid != manifest.gid {
            throw SteamError.download("receipt sizing context does not match pinned depot manifest")
        }
        let limit = try Self.readLimit(manifest: sizingManifest ?? manifest, mappedManifest: sizingManifest == nil ? nil : manifest)
        self.workspace = workspace; self.now = now; lastCheckpoint = now()
        path = ".gn-download/receipts/\(manifest.depotID)-\(manifest.gid).json"
        let saved = (try? workspace.read(path, limit: limit)).flatMap { try? JSONDecoder().decode(DownloadCompletionReceipt.self, from: $0) }
        if let saved, saved.version == 1, saved.depotID == manifest.depotID, saved.gid == manifest.gid {
            receipt = saved
        } else { receipt = DownloadCompletionReceipt(depotID: manifest.depotID, gid: manifest.gid) }
    }
    /// Fixed-width metadata/fingerprints need less than 1 KiB per entry. JSON string escaping
    /// can expand each path byte by at most six. Additional mapped-path space accommodates
    /// explicitly excluded backups without coupling entry trust to the sizing context.
    private static func readLimit(manifest: DepotManifest, mappedManifest: DepotManifest?) throws -> Int {
        var limit = 1024
        func add(_ value: Int) throws {
            let sum = limit.addingReportingOverflow(value)
            guard !sum.overflow, sum.partialValue < Int.max else { throw SteamError.download("receipt size bound overflows") }
            limit = sum.partialValue
        }
        func addPath(_ path: String) throws {
            let escaped = path.utf8.count.multipliedReportingOverflow(by: 6)
            guard !escaped.overflow else { throw SteamError.download("receipt path size bound overflows") }
            try add(escaped.partialValue)
        }
        for file in manifest.files {
            try add(1024)
            try addPath(file.path)
        }
        if let mappedManifest {
            for file in mappedManifest.files { try addPath(file.path) }
        }
        return max(16 * 1024 * 1024, limit)
    }
    private func fingerprint(_ file: DepotManifest.File) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(file)
        return workspace.diagnostics.measure(.sha256, bytes: UInt64(data.count)) { Data(SHA256.hash(data: data)) }
    }
    func matches(_ file: DepotManifest.File, path: String) throws -> Bool {
        try lock.withLock {
            guard let entry = receipt.entries[path], entry.fingerprint == (try fingerprint(file)),
                  let metadata = try? workspace.metadata(path), metadata == entry.metadata,
                  metadata.size >= 0, UInt64(metadata.size) == file.size else { return false }
            return true
        }
    }
    func record(_ file: DepotManifest.File, path: String, metadata: DownloadFileMetadata, countVerifiedBytes: Bool = true) throws {
        try lock.withLock {
            receipt.entries[path] = .init(fingerprint: try fingerprint(file), metadata: metadata)
            dirty = true
            if countVerifiedBytes { bytesSinceCheckpoint = min(128 * 1024 * 1024, bytesSinceCheckpoint + file.size) }
            try checkpointIfNeeded()
        }
    }
    func invalidate(_ path: String) {
        lock.withLock { if receipt.entries.removeValue(forKey: path) != nil { dirty = true } }
    }
    /// Called as transfer makes progress as well as when completed entries change.
    func checkpoint(processedBytes: UInt64 = 0, force: Bool = false) throws {
        try lock.withLock {
            bytesSinceCheckpoint = min(128 * 1024 * 1024, bytesSinceCheckpoint + min(processedBytes, 128 * 1024 * 1024))
            try checkpointIfNeeded(force: force)
        }
    }
    private func checkpointIfNeeded(force: Bool = false) throws {
        guard dirty, force || bytesSinceCheckpoint >= 128 * 1024 * 1024 || lastCheckpoint.duration(to: now()) >= .seconds(5) else { return }
        let started = workspace.diagnostics?.start()
        defer { workspace.diagnostics?.finish(.checkpoint, since: started) }
        try workspace.writeAtomic(try JSONEncoder().encode(receipt), path: path)
        dirty = false; bytesSinceCheckpoint = 0; lastCheckpoint = now()
    }
}
