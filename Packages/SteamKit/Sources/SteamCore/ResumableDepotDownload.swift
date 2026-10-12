import Foundation
import CryptoKit
import Darwin

/// The CDN boundary supplies decrypted, content-validated chunks. The writer checks ranges and writes them, then
/// periodically syncs bytes before atomically checkpointing completion. Reopening validates
/// every retained range; abrupt termination may redownload the last uncheckpointed batch.
public struct ResumableDepotDownload: Sendable {
    public let destination: URL
    public var chunkConcurrency = 8
    /// Force known-invalid targets without scanning unrelated files again.
    public var forceDownloadPaths: Set<String> = []
    /// Prepared files and mapped backups must bypass and never acquire receipt trust.
    public var receiptExcludedPaths: Set<String> = []
    /// Set false when passing a projection instead of the complete pinned depot manifest.
    /// Forced repair subsets always defer cleanup until the caller confirms depot completion.
    public var cleanupCompletedDepot = true
    /// Full pinned manifest context for sizing receipt reads when the operation uses a subset.
    /// This context never determines entry trust; depot/GID must match the operation.
    public var receiptManifest: DepotManifest?
    public enum VerificationMode: Sendable {
        /// Hash every file without modifying receipt state (the default).
        case full
        /// Hash every file and retain stable verified metadata for subsequent normal checks.
        case fullRefreshingReceipts
        /// Reuse matching receipts and fully verify any missing or mismatched entries.
        case receiptAssisted
    }
    public var onProgress: @Sendable (DownloadProgress) -> Void = { _ in }
    public let diagnostics: SteamPerformanceDiagnostics?
    public init(destination: URL, diagnostics: SteamPerformanceDiagnostics? = nil) {
        self.destination = destination; self.diagnostics = diagnostics
    }

    private func report(_ progress: DownloadProgress) {
        diagnostics.measure(.progressCallback) { onProgress(progress) }
    }

    /// `fetchChunk` must return plaintext already validated with `chunk.validate` (as CDNClient.fetchChunk does).
    /// Fetchers own retrying corrupt responses. The writer checks length and ranges, and restore revalidates disk bytes.
    public func download(manifest: DepotManifest,
                         fetchChunk: @escaping @Sendable (DepotManifest.Chunk) async throws -> Data) async throws {
        let entries = try Self.validate(manifest)
        let workspace = try DownloadWorkspace(destination: destination, diagnostics: diagnostics)
        let receipts = try DownloadCompletionReceipts(workspace: workspace, manifest: manifest, sizingManifest: receiptManifest)
        for path in receiptExcludedPaths { receipts.invalidate(path) }
        let total = entries.filter { !$0.file.isDirectory && !$0.file.isSymlink }.reduce(UInt64(0)) { $0 + $1.file.size }
        var done: UInt64 = 0, written: UInt64 = 0
        do {
            for entry in entries where !entry.file.isSymlink {
                try Task.checkCancellation()
                if entry.file.isDirectory { try workspace.makeDirectory(entry.path); continue }
                let before = done, freshBefore = written
                let checkingExisting: @Sendable (UInt64) -> Void = { checked in
                    report(DownloadProgress(depotID: manifest.depotID, file: entry.path, bytesDone: before,
                        bytesTotal: total, bytesWritten: freshBefore,
                        verification: .init(bytesChecked: checked, bytesTotal: entry.file.size)))
                }
                let eligible = !receiptExcludedPaths.contains(entry.path)
                let valid: Bool
                if forceDownloadPaths.contains(entry.path) {
                    receipts.invalidate(entry.path); valid = false
                } else {
                    valid = try Self.check(entry.file, path: entry.path, workspace: workspace, receipts: receipts,
                        useReceipt: eligible, recordReceipt: eligible, onVerification: checkingExisting)
                }
                if valid {
                    try receipts.checkpoint()
                    done += entry.file.size
                    report(DownloadProgress(depotID: manifest.depotID, file: entry.path, bytesDone: done, bytesTotal: total, bytesWritten: written))
                    continue
                }
                let pathBytes = Data(entry.path.utf8)
                let key = diagnostics.measure(.sha256, bytes: UInt64(pathBytes.count)) { SHA256.hash(data: pathBytes) }.map { String(format: "%02x", $0) }.joined()
                let base = ".gn-download/\(manifest.depotID)/\(manifest.gid)/\(key)"
                let writer = try ChunkCheckpointWriter(workspace: workspace, file: entry.file, base: base)
                let resumed = try await writer.restore { checked, checkTotal, retained in
                    report(DownloadProgress(depotID: manifest.depotID, file: entry.path,
                        bytesDone: before + retained, bytesTotal: total, bytesWritten: freshBefore,
                        verification: .init(bytesChecked: checked, bytesTotal: checkTotal)))
                }
                var completed = resumed.bytes
                report(DownloadProgress(depotID: manifest.depotID, file: entry.path, bytesDone: done + completed, bytesTotal: total, bytesWritten: written))
                let pending = entry.file.chunks.enumerated().filter { !resumed.indices.contains($0.offset) }
                    .sorted { $0.element.offset < $1.element.offset }
                var iterator = pending.makeIterator()
                do {
                    try await withThrowingTaskGroup(of: UInt64.self) { group in
                        func next() {
                            guard let (index, chunk) = iterator.next() else { return }
                            group.addTask {
                                try Task.checkCancellation()
                                let data = try await fetchChunk(chunk)
                                try Task.checkCancellation()
                                try await writer.commit(data, index: index)
                                return UInt64(data.count)
                            }
                        }
                        for _ in 0..<max(1, min(16, chunkConcurrency)) { next() }
                        while let count = try await group.next() {
                            try Task.checkCancellation()
                            try receipts.checkpoint(processedBytes: count)
                            completed += count; written += count
                            report(DownloadProgress(depotID: manifest.depotID, file: entry.path, bytesDone: done + completed, bytesTotal: total, bytesWritten: written))
                            next()
                        }
                    }
                    try Task.checkCancellation()
                    let assembled = done + completed, fresh = written
                    let metadata = try await writer.finish(to: entry.path)
                    if eligible { try receipts.record(entry.file, path: entry.path, metadata: metadata, countVerifiedBytes: false) }
                    report(DownloadProgress(depotID: manifest.depotID, file: entry.path,
                        bytesDone: assembled, bytesTotal: total, bytesWritten: fresh))
                } catch {
                    // Task groups drain their children before this catch, so no writer can
                    // race the final checkpoint. Pause/network failure keeps received chunks.
                    try await writer.checkpoint()
                    throw error
                }
                done += entry.file.size
            }
            // Links are applied last. No later file write in this manifest can traverse a newly created link.
            for entry in entries where entry.file.isSymlink {
                try Task.checkCancellation()
                try workspace.createSymlink(entry.link, path: entry.path)
            }
            try receipts.checkpoint(force: true)
            if cleanupCompletedDepot && forceDownloadPaths.isEmpty {
                try workspace.cleanCheckpoints(depotID: manifest.depotID, keepingGID: manifest.gid)
            }
        } catch {
            try receipts.checkpoint(force: true)
            throw error
        }
    }

    /// Returns corrupt/missing original manifest files. The caller maps emulation-transformed files
    /// to their retained originals before using this for a repair; this API never stages emulation.
    public func invalidFiles(in manifest: DepotManifest, mode: VerificationMode = .full, onVerification: (String, UInt64, UInt64) -> Void = { _, _, _ in }) throws -> [String] {
        func reportVerification(_ file: String, _ checked: UInt64, _ total: UInt64) {
            diagnostics.measure(.progressCallback) { onVerification(file, checked, total) }
        }
        let entries = try Self.validate(manifest)
        guard FileManager.default.fileExists(atPath: destination.path) else { return entries.filter { !$0.file.isDirectory }.map(\.path) }
        let workspace = try DownloadWorkspace(destination: destination, lock: mode != .full, diagnostics: diagnostics)
        let receipts = try mode != .full ? DownloadCompletionReceipts(workspace: workspace, manifest: manifest, sizingManifest: receiptManifest) : nil
        for path in receiptExcludedPaths { receipts?.invalidate(path) }
        var invalid: [String] = []
        let total = entries.filter { !$0.file.isDirectory && !$0.file.isSymlink }.reduce(UInt64(0)) { $0 + $1.file.size }
        var completed: UInt64 = 0
        reportVerification("", 0, total)
        do {
            for entry in entries where !entry.file.isDirectory {
                try Task.checkCancellation()
                if entry.file.isSymlink {
                    if (try? workspace.symlinkTarget(entry.path)) != entry.link { invalid.append(entry.path) }
                } else {
                    reportVerification(entry.path, completed, total)
                    if try !Self.check(entry.file, path: entry.path, workspace: workspace, receipts: receipts,
                        useReceipt: mode == .receiptAssisted && !receiptExcludedPaths.contains(entry.path),
                        recordReceipt: mode != .full && !receiptExcludedPaths.contains(entry.path), onVerification: { checked in
                        reportVerification(entry.path, completed + checked, total)
                    }) { invalid.append(entry.path) }
                    // Examined bytes include files found missing/corrupt; completion is not validity.
                    try receipts?.checkpoint()
                    completed += entry.file.size
                    reportVerification(entry.path, completed, total)
                }
            }
            try receipts?.checkpoint(force: true)
            return invalid
        } catch {
            try receipts?.checkpoint(force: true)
            throw error
        }
    }
    /// Call only after all files in the pinned depot have completed, including any repair subsets.
    public func cleanCompletedDepotState(depotID: UInt32, gid: UInt64) throws {
        let workspace = try DownloadWorkspace(destination: destination, diagnostics: diagnostics)
        try workspace.cleanCheckpoints(depotID: depotID, keepingGID: gid)
    }
    private struct Entry { let file: DepotManifest.File; let path: String; let link: String }
    /// Validate a resolved manifest before reserving storage or touching a destination.
    public static func validateManifest(_ manifest: DepotManifest) throws { _ = try validate(manifest) }
    private static func validate(_ manifest: DepotManifest) throws -> [Entry] {
        var entries: [Entry] = [], names = Set<String>(), total: UInt64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            let path = try DownloadWorkspace.path(file.path)
            let folded = path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
            guard names.insert(folded).inserted else { throw SteamError.download("manifest has conflicting file names: \(path)") }
            guard file.size <= UInt64(Int64.max), file.contentSHA1 == nil || file.contentSHA1?.count == 20 else { throw SteamError.download("manifest has invalid file metadata: \(path)") }
            var end: UInt64 = 0
            if !file.isDirectory && !file.isSymlink {
                for chunk in file.chunks.sorted(by: { $0.offset < $1.offset }) {
                    guard chunk.sha.count == 20, chunk.uncompressedSize > 0, chunk.offset == end,
                          UInt64(chunk.uncompressedSize) <= file.size - end else { throw SteamError.download("manifest has overlapping or incomplete chunks: \(path)") }
                    end += UInt64(chunk.uncompressedSize)
                }
                guard end == file.size else { throw SteamError.download("manifest has incomplete file ranges: \(path)") }
                let sum = total.addingReportingOverflow(file.size)
                guard !sum.overflow else { throw SteamError.download("manifest total size overflows") }
                total = sum.partialValue
            }
            let link = file.linkTarget.replacingOccurrences(of: "\\", with: "/")
            if file.isSymlink {
                guard !link.hasPrefix("/"), !link.contains(":"), !link.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SteamError.download("manifest link escapes destination: \(path)") }
                var resolved = path.split(separator: "/").dropLast().map(String.init)
                for part in link.split(separator: "/") {
                    if part == ".." { guard !resolved.isEmpty else { throw SteamError.download("manifest link escapes destination: \(path)") }; resolved.removeLast() }
                    else if part != "." { resolved.append(String(part)) }
                }
                guard !resolved.isEmpty, resolved.first?.lowercased() != ".gn-download" else { throw SteamError.download("manifest link points into download state: \(path)") }
            }
            entries.append(Entry(file: file, path: path, link: link))
        }
        // A manifest file/link cannot also be a parent directory of another entry.
        let nonDirectories = Set(entries.filter { !$0.file.isDirectory }.map { $0.path.lowercased() })
        for entry in entries {
            var prefix = ""
            for part in entry.path.split(separator: "/").dropLast() {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                guard !nonDirectories.contains(prefix.lowercased()) else { throw SteamError.download("manifest writes through a file or link: \(entry.path)") }
            }
        }
        return entries
    }
    private static func check(_ file: DepotManifest.File, path: String, workspace: DownloadWorkspace,
                              receipts: DownloadCompletionReceipts?, useReceipt: Bool, recordReceipt: Bool,
                              onVerification: (UInt64) -> Void) throws -> Bool {
        if useReceipt, try receipts?.matches(file, path: path) == true { return true }
        receipts?.invalidate(path)
        guard let metadata = try verifiedMetadata(file, path: path, workspace: workspace, onVerification: onVerification) else { return false }
        if recordReceipt { try receipts?.record(file, path: path, metadata: metadata) }
        return true
    }
    private static func verifiedMetadata(_ file: DepotManifest.File, path: String, workspace: DownloadWorkspace,
                                         onVerification: (UInt64) -> Void) throws -> DownloadFileMetadata? {
        let started = workspace.diagnostics?.start()
        defer { workspace.diagnostics?.finish(.fileValidation, since: started) }
        let handle: FileHandle
        do { handle = try workspace.openFile(path, flags: O_RDONLY) }
        catch { return nil }
        defer { try? handle.close() }
        let before = try workspace.metadata(handle)
        guard before.size >= 0, UInt64(before.size) == file.size else { return nil }
        func stableMetadata() throws -> DownloadFileMetadata? {
            guard (try? workspace.metadata(handle)) == before, (try? workspace.metadata(path)) == before else { return nil }
            return before
        }
        // Steam uses an all-zero digest for some empty placeholder files (for example
        // KAMI's Adobe AIR runtime). The exact zero length is their verification.
        if file.size == 0, file.contentSHA1 == Data(repeating: 0, count: 20) { return try stableMetadata() }
        var checked: UInt64 = 0
        var lastReport = ContinuousClock.now
        workspace.diagnostics.measure(.progressCallback) { onVerification(0) }
        func report(_ count: Int) {
            checked += UInt64(count)
            if checked == file.size || lastReport.duration(to: .now) >= .milliseconds(250) {
                workspace.diagnostics.measure(.progressCallback) { onVerification(checked) }; lastReport = .now
            }
        }
        if let sha = file.contentSHA1 {
            try handle.seek(toOffset: 0)
            var hash = Insecure.SHA1()
            while true {
                try Task.checkCancellation()
                // Foundation reads may autorelease their buffers. Release each block even
                // on a long-lived async worker checking a multi-gigabyte archive.
                let count = try autoreleasepool {
                    let data = try workspace.diagnostics.readContent { try handle.read(upToCount: 1024 * 1024) ?? Data() }
                    workspace.diagnostics.measure(.sha1, bytes: UInt64(data.count)) { hash.update(data: data) }
                    return data.count
                }
                if count == 0 { break }; report(count)
            }
            guard workspace.diagnostics.measure(.sha1, { Data(hash.finalize()) }) == sha else { return nil }
            return try stableMetadata()
        }
        for chunk in file.chunks {
            try Task.checkCancellation(); try handle.seek(toOffset: chunk.offset)
            let valid = try autoreleasepool {
                let data = try workspace.diagnostics.readContent { try handle.read(upToCount: Int(chunk.uncompressedSize)) ?? Data() }
                return (try? chunk.validate(data, diagnostics: workspace.diagnostics)) != nil
            }
            guard valid else { return nil }
            report(Int(chunk.uncompressedSize))
        }
        return try stableMetadata()
    }
}

private struct ChunkJournal: Codable {
    let version = 2
    let fingerprint: Data
    var completed: Set<Int> = []

    init(fingerprint: Data) { self.fingerprint = fingerprint }
    private enum CodingKeys: String, CodingKey { case version, fingerprint, completed }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let savedVersion = try values.decode(Int.self, forKey: .version)
        fingerprint = try values.decode(Data.self, forKey: .fingerprint)
        switch savedVersion {
        case 1:
            // The pinned manifest and restored chunk checks replace legacy content hashes.
            completed = Set(try values.decode([Int: Data].self, forKey: .completed).keys)
        case 2:
            completed = Set(try values.decode([Int].self, forKey: .completed))
        default:
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "unsupported chunk journal version")
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(fingerprint, forKey: .fingerprint)
        try values.encode(completed.sorted(), forKey: .completed)
    }
}
actor ChunkCheckpointWriter {
    let workspace: DownloadWorkspace
    let file: DepotManifest.File
    let partial: String
    let journalPath: String
    let handle: FileHandle
    private var journal: ChunkJournal
    private var uncheckpointedBytes: UInt64 = 0
    private var lastCheckpoint = ContinuousClock.now
    init(workspace: DownloadWorkspace, file: DepotManifest.File, base: String) throws {
        self.workspace = workspace; self.file = file; partial = base + ".partial"; journalPath = base + ".json"
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(file)
        let fingerprint = workspace.diagnostics.measure(.sha256, bytes: UInt64(encoded.count)) { Data(SHA256.hash(data: encoded)) }
        let saved = (try? workspace.read(journalPath)).flatMap { try? JSONDecoder().decode(ChunkJournal.self, from: $0) }
        let canResume = saved?.fingerprint == fingerprint
        var restoredJournal = canResume ? saved! : ChunkJournal(fingerprint: fingerprint)
        let openedHandle = try workspace.openFile(base + ".partial", flags: O_RDWR | O_CREAT, createParents: true)
        // Grow only as chunks arrive. HFS+ allocates/zero-fills the entire length
        // when truncating upward, which can block a multi-GB download before it starts.
        if try !canResume || openedHandle.seekToEnd() > file.size {
            restoredJournal.completed = []; try openedHandle.truncate(atOffset: 0)
        }
        journal = restoredJournal
        handle = openedHandle
    }
    func restore(onVerification: @Sendable (UInt64, UInt64, UInt64) -> Void) throws -> (indices: Set<Int>, bytes: UInt64) {
        var retained = Set<Int>(), bytes: UInt64 = 0
        // Sort completion indices by offset to avoid random seeks across partials on external disks.
        let saved = journal.completed.filter { file.chunks.indices.contains($0) }
            .sorted { file.chunks[$0].offset < file.chunks[$1].offset }
        let total = saved.reduce(UInt64(0)) { $0 + UInt64(file.chunks[$1].uncompressedSize) }
        var checked: UInt64 = 0
        var lastReport = ContinuousClock.now
        if total > 0 { workspace.diagnostics.measure(.progressCallback) { onVerification(0, total, 0) } }
        for index in saved {
            try Task.checkCancellation()
            let chunk = file.chunks[index]
            let valid = try autoreleasepool {
                try handle.seek(toOffset: chunk.offset)
                let data = try workspace.diagnostics.readContent { try handle.read(upToCount: Int(chunk.uncompressedSize)) ?? Data() }
                return (try? chunk.validate(data, diagnostics: workspace.diagnostics)) != nil
            }
            if valid { retained.insert(index); bytes += UInt64(chunk.uncompressedSize) }
            // Checked ranges include rejected chunks; only valid bytes count as retained.
            checked += UInt64(chunk.uncompressedSize)
            if checked == total || lastReport.duration(to: .now) >= .milliseconds(250) {
                workspace.diagnostics.measure(.progressCallback) { onVerification(checked, total, bytes) }; lastReport = .now
            }
        }
        journal.completed = retained
        return (retained, bytes)
    }
    func commit(_ data: Data, index: Int) throws {
        try Task.checkCancellation()
        guard file.chunks.indices.contains(index) else { throw SteamError.download("chunk index out of range") }
        let chunk = file.chunks[index]
        guard data.count == Int(chunk.uncompressedSize) else { throw SteamError.download("chunk length mismatch") }
        guard chunk.offset <= file.size, UInt64(data.count) <= file.size - chunk.offset else {
            throw SteamError.download("chunk range outside file")
        }
        try handle.seek(toOffset: chunk.offset)
        try workspace.write(data, to: handle, path: partial)
        journal.completed.insert(index)
        uncheckpointedBytes += UInt64(data.count)
        // Complete files use publication as their next durability checkpoint.
        if journal.completed.count < file.chunks.count,
           uncheckpointedBytes >= 128 * 1024 * 1024 || lastCheckpoint.duration(to: .now) >= .seconds(5) {
            try checkpoint()
        }
    }
    func checkpoint() throws {
        guard uncheckpointedBytes > 0 else { return }
        let started = workspace.diagnostics?.start()
        defer { workspace.diagnostics?.finish(.checkpoint, since: started) }
        try workspace.syncFile(handle)
        try workspace.writeAtomic(try JSONEncoder().encode(journal), path: journalPath)
        uncheckpointedBytes = 0; lastCheckpoint = .now
    }
    @discardableResult
    func finish(to target: String) throws -> DownloadFileMetadata {
        try Task.checkCancellation()
        // Fetch validated new bytes; restore validated retained bytes. Check coverage and
        // length here without rereading content. Explicit repair still hashes whole files.
        guard journal.completed == Set(file.chunks.indices),
              try handle.seekToEnd() == file.size else {
            journal.completed = []
            try workspace.writeAtomic(try JSONEncoder().encode(journal), path: journalPath)
            throw SteamError.download("assembled file has incomplete chunks or wrong size: \(file.path)")
        }
        if file.isExecutable { guard fchmod(handle.fileDescriptor, 0o755) == 0 else { throw POSIXError(.EIO) } }
        let beforePublication = try workspace.metadata(handle)
        try workspace.syncFile(handle)
        try Task.checkCancellation()
        // Publication is the commit point. Once rename begins, finish durability and
        // journal cleanup even if cancellation arrives during a directory sync.
        try workspace.replace(partial, withDestination: target)
        try workspace.remove(journalPath)
        let metadata = try workspace.metadata(handle)
        guard metadata.size == beforePublication.size,
              metadata.modificationSeconds == beforePublication.modificationSeconds,
              metadata.modificationNanoseconds == beforePublication.modificationNanoseconds,
              (try? workspace.metadata(target)) == metadata else {
            throw SteamError.download("published file changed before recording completion: \(target)")
        }
        return metadata
    }
}
