import Foundation
import CryptoKit
import Darwin

/// The CDN boundary supplies decrypted chunks. The writer validates and writes them, then
/// periodically syncs bytes before atomically checkpointing completion. Reopening validates
/// every retained range; abrupt termination may redownload the last uncheckpointed batch.
public struct ResumableDepotDownload: Sendable {
    public let destination: URL
    public var chunkConcurrency = 8
    public var onProgress: @Sendable (DownloadProgress) -> Void = { _ in }
    public init(destination: URL) { self.destination = destination }

    public func download(manifest: DepotManifest,
                         fetchChunk: @escaping @Sendable (DepotManifest.Chunk) async throws -> Data) async throws {
        let entries = try Self.validate(manifest)
        let workspace = try DownloadWorkspace(destination: destination)
        let total = entries.filter { !$0.file.isDirectory && !$0.file.isSymlink }.reduce(UInt64(0)) { $0 + $1.file.size }
        var done: UInt64 = 0, written: UInt64 = 0
        for entry in entries where !entry.file.isSymlink {
            try Task.checkCancellation()
            if entry.file.isDirectory { try workspace.makeDirectory(entry.path); continue }
            let before = done, freshBefore = written
            let checkingExisting: @Sendable (UInt64) -> Void = { checked in
                onProgress(DownloadProgress(depotID: manifest.depotID, file: entry.path, bytesDone: before,
                    bytesTotal: total, bytesWritten: freshBefore,
                    verification: .init(bytesChecked: checked, bytesTotal: entry.file.size)))
            }
            if try Self.isValid(entry.file, path: entry.path, workspace: workspace, onVerification: checkingExisting) {
                done += entry.file.size
                onProgress(DownloadProgress(depotID: manifest.depotID, file: entry.path, bytesDone: done, bytesTotal: total, bytesWritten: written))
                continue
            }
            let key = SHA256.hash(data: Data(entry.path.utf8)).map { String(format: "%02x", $0) }.joined()
            let base = ".gn-download/\(manifest.depotID)/\(manifest.gid)/\(key)"
            let writer = try ChunkCheckpointWriter(workspace: workspace, file: entry.file, base: base)
            let resumed = try await writer.restore()
            var completed = resumed.bytes
            onProgress(DownloadProgress(depotID: manifest.depotID, file: entry.path, bytesDone: done + completed, bytesTotal: total, bytesWritten: written))
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
                            try chunk.validate(data)
                            try await writer.commit(data, index: index)
                            return UInt64(data.count)
                        }
                    }
                    for _ in 0..<max(1, min(16, chunkConcurrency)) { next() }
                    while let count = try await group.next() {
                        try Task.checkCancellation()
                        completed += count; written += count
                        onProgress(DownloadProgress(depotID: manifest.depotID, file: entry.path, bytesDone: done + completed, bytesTotal: total, bytesWritten: written))
                        next()
                    }
                }
                try Task.checkCancellation()
                let assembled = done + completed, fresh = written
                try await writer.finish(to: entry.path) { checked in
                    onProgress(DownloadProgress(depotID: manifest.depotID, file: entry.path, bytesDone: assembled,
                        bytesTotal: total, bytesWritten: fresh,
                        verification: .init(bytesChecked: checked, bytesTotal: entry.file.size)))
                }
                onProgress(DownloadProgress(depotID: manifest.depotID, file: entry.path,
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
    }

    /// Returns corrupt/missing original manifest files. The caller maps emulation-transformed files
    /// to their retained originals before using this for a repair; this API never stages emulation.
    public func invalidFiles(in manifest: DepotManifest) throws -> [String] {
        let entries = try Self.validate(manifest)
        guard FileManager.default.fileExists(atPath: destination.path) else { return entries.filter { !$0.file.isDirectory }.map(\.path) }
        let workspace = try DownloadWorkspace(destination: destination, lock: false)
        var invalid: [String] = []
        for entry in entries where !entry.file.isDirectory {
            try Task.checkCancellation()
            if entry.file.isSymlink {
                if (try? workspace.symlinkTarget(entry.path)) != entry.link { invalid.append(entry.path) }
            } else if try !Self.isValid(entry.file, path: entry.path, workspace: workspace) { invalid.append(entry.path) }
        }
        return invalid
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
    fileprivate static func isValid(_ file: DepotManifest.File, path: String, workspace: DownloadWorkspace, onVerification: (UInt64) -> Void = { _ in }) throws -> Bool {
        let handle: FileHandle
        do { handle = try workspace.openFile(path, flags: O_RDONLY) }
        catch { return false }
        defer { try? handle.close() }
        guard try handle.seekToEnd() == file.size else { return false }
        var checked: UInt64 = 0
        var lastReport = ContinuousClock.now
        onVerification(0)
        func report(_ count: Int) {
            checked += UInt64(count)
            if checked == file.size || lastReport.duration(to: .now) >= .milliseconds(250) {
                onVerification(checked); lastReport = .now
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
                    let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                    hash.update(data: data)
                    return data.count
                }
                if count == 0 { break }; report(count)
            }
            return Data(hash.finalize()) == sha
        }
        for chunk in file.chunks {
            try Task.checkCancellation(); try handle.seek(toOffset: chunk.offset)
            let valid = try autoreleasepool {
                let data = try handle.read(upToCount: Int(chunk.uncompressedSize)) ?? Data()
                return (try? chunk.validate(data)) != nil
            }
            guard valid else { return false }
            report(Int(chunk.uncompressedSize))
        }
        return true
    }
}

private struct ChunkJournal: Codable {
    var version = 1
    let fingerprint: Data
    var completed: [Int: Data] = [:]
}
private actor ChunkCheckpointWriter {
    let workspace: DownloadWorkspace
    let file: DepotManifest.File
    let partial: String
    let journalPath: String
    let handle: FileHandle
    var journal: ChunkJournal
    private var uncheckpointedBytes: UInt64 = 0
    private var lastCheckpoint = ContinuousClock.now
    init(workspace: DownloadWorkspace, file: DepotManifest.File, base: String) throws {
        self.workspace = workspace; self.file = file; partial = base + ".partial"; journalPath = base + ".json"
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let fingerprint = Data(SHA256.hash(data: try encoder.encode(file)))
        let saved = (try? workspace.read(journalPath)).flatMap { try? JSONDecoder().decode(ChunkJournal.self, from: $0) }
        let canResume = saved?.version == 1 && saved?.fingerprint == fingerprint
        journal = canResume ? saved! : ChunkJournal(fingerprint: fingerprint)
        handle = try workspace.openFile(partial, flags: O_RDWR | O_CREAT, createParents: true)
        // Grow only as chunks arrive. HFS+ allocates/zero-fills the entire length
        // when truncating upward, which can block a multi-GB download before it starts.
        if try !canResume || handle.seekToEnd() > file.size {
            journal.completed = [:]; try handle.truncate(atOffset: 0)
        }
    }
    func restore() throws -> (indices: Set<Int>, bytes: UInt64) {
        var retained: [Int: Data] = [:], bytes: UInt64 = 0
        for (index, hash) in journal.completed {
            try Task.checkCancellation()
            guard file.chunks.indices.contains(index) else { continue }
            let chunk = file.chunks[index]
            try handle.seek(toOffset: chunk.offset)
            let data = try handle.read(upToCount: Int(chunk.uncompressedSize)) ?? Data()
            guard Data(SHA256.hash(data: data)) == hash, (try? chunk.validate(data)) != nil else { continue }
            retained[index] = hash; bytes += UInt64(data.count)
        }
        journal.completed = retained
        return (Set(retained.keys), bytes)
    }
    func commit(_ data: Data, index: Int) throws {
        try Task.checkCancellation()
        let chunk = file.chunks[index]
        try chunk.validate(data)
        try handle.seek(toOffset: chunk.offset); try handle.write(contentsOf: data)
        journal.completed[index] = Data(SHA256.hash(data: data))
        uncheckpointedBytes += UInt64(data.count)
        if uncheckpointedBytes >= 16 * 1024 * 1024 || lastCheckpoint.duration(to: .now) >= .seconds(1) {
            try checkpoint()
        }
    }
    func checkpoint() throws {
        guard uncheckpointedBytes > 0 else { return }
        try DownloadWorkspace.sync(handle)
        try workspace.writeAtomic(try JSONEncoder().encode(journal), path: journalPath)
        uncheckpointedBytes = 0; lastCheckpoint = .now
    }
    func finish(to target: String, onVerification: @Sendable (UInt64) -> Void) throws {
        try checkpoint()
        guard journal.completed.count == file.chunks.count,
              try ResumableDepotDownload.isValid(file, path: partial, workspace: workspace, onVerification: onVerification) else {
            // A failed whole-file digest must not trap retries into reusing the same bad chunks.
            journal.completed = [:]
            try workspace.writeAtomic(try JSONEncoder().encode(journal), path: journalPath)
            throw SteamError.download("assembled file failed verification: \(file.path)")
        }
        if file.isExecutable { guard fchmod(handle.fileDescriptor, 0o755) == 0 else { throw POSIXError(.EIO) } }
        try DownloadWorkspace.sync(handle)
        try workspace.replace(partial, withDestination: target)
        try workspace.remove(journalPath)
    }
}
