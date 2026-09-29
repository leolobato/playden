import Foundation
import CryptoKit
import Darwin

public struct GOGDownloadProgress: Equatable, Sendable {
    public var file: String
    /// Assembled file bytes, including files a previous run already finished.
    public var bytesDone: Int64
    public var bytesTotal: Int64
    /// Bytes fetched from the CDN by this run.
    public var bytesDownloaded: Int64
    /// File bytes written by this run.
    public var bytesWritten: Int64
}

/// Writes an install from its `GOGInstallManifest` into `destination` (PRD 10 FR-GOG-15 to FR-GOG-18).
/// Chunks and ranges are fetched in parallel a bounded window ahead of the writer, which writes
/// files in order and journals each one once its hash matches, so a cancelled or crashed run
/// resumes after the last finished file.
public struct GOGDownloader: Sendable {
    public let destination: URL
    public var concurrency = 8
    /// Gen 1 files are fetched as ranges of at most this many bytes.
    public var rangeSize: Int64 = 10 * 1024 * 1024
    public var onProgress: @Sendable (GOGDownloadProgress) -> Void = { _ in }

    public init(destination: URL) { self.destination = destination }

    public static let workDirectory = ".gog-download"

    enum Unit: Sendable { case chunk(GOGChunk, product: String), range(product: String, offset: Int64, length: Int64) }

    static func units(_ file: GOGFile, rangeSize: Int64) -> [Unit] {
        if let chunks = file.chunks { return chunks.map { .chunk($0, product: file.product) } }
        guard let offset = file.offset, file.size > 0 else { return [] }
        return stride(from: Int64(0), to: file.size, by: Int(rangeSize)).map {
            .range(product: file.product, offset: offset + $0, length: min(rangeSize, file.size - $0))
        }
    }

    /// Fetches and decodes one unit: gen 2 chunks are inflated and checked against both MD5s.
    static func fetch(_ unit: Unit, from fetcher: any GOGContentFetching) async throws -> (data: Data, downloaded: Int64) {
        switch unit {
        case .chunk(let chunk, let product):
            let raw = try await fetcher.chunk(chunk, product: product)
            guard GOGCodec.md5(raw) == chunk.compressedMd5 else { throw GOGError.hashMismatch("compressed chunk \(chunk.compressedMd5)") }
            let data = try GOGCodec.inflateZlib(raw)
            guard GOGCodec.md5(data) == chunk.md5, Int64(data.count) == chunk.size else { throw GOGError.hashMismatch("chunk \(chunk.md5)") }
            return (data, Int64(raw.count))
        case .range(let product, let offset, let length):
            let data = try await fetcher.range(product: product, offset: offset, length: length)
            return (data, Int64(data.count))
        }
    }

    /// The bytes of one small file, such as the info file read at resolve time.
    public static func contents(of file: GOGFile, fetcher: any GOGContentFetching) async throws -> Data {
        var data = Data()
        for unit in units(file, rangeSize: 10 * 1024 * 1024) { data += try await fetch(unit, from: fetcher).data }
        try GOGFileHash.check(data: data, file)
        return data
    }

    /// `only` limits the run to those paths (repair). Links are created after every file.
    public func download(_ manifest: GOGInstallManifest, only: Set<String>? = nil, fetcher: any GOGContentFetching) async throws {
        let layout = try GOGInstallLayout(manifest.files)
        let selected = layout.entries.filter { only?.contains($0.file.path) ?? true }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let work = destination.appendingPathComponent("\(Self.workDirectory)/\(safeName(manifest.buildID))", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let journal = try GOGResumeJournal(url: work.appendingPathComponent("resume"))

        for entry in selected where entry.file.kind == .directory {
            try GOGInstallLayout.refuseLinks(at: destination.appendingPathComponent(entry.path), within: destination)
            try FileManager.default.createDirectory(at: destination.appendingPathComponent(entry.path), withIntermediateDirectories: true)
        }
        let regular = selected.filter { $0.file.kind == .file }
        let total = regular.reduce(Int64(0)) { $0 + $1.file.size }
        var pending: [GOGInstallLayout.Entry] = [], done: Int64 = 0
        for entry in regular {
            let url = destination.appendingPathComponent(entry.path)
            if only == nil, journal.isComplete(entry.file), fileSize(url) == entry.file.size { done += entry.file.size } else { pending.append(entry) }
        }
        onProgress(.init(file: "", bytesDone: done, bytesTotal: total, bytesDownloaded: 0, bytesWritten: 0))

        let plan = pending.map { Self.units($0.file, rangeSize: rangeSize) }
        let flat = plan.enumerated().flatMap { index, units in units.map { (file: index, unit: $0) } }
        let concurrency = max(1, min(16, self.concurrency))
        let buffer = GOGUnitBuffer(window: concurrency * 2)
        let counters = GOGCounters()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { fetchers in
                    var iterator = flat.enumerated().makeIterator()
                    func next() async throws {
                        guard let (index, item) = iterator.next() else { return }
                        try await buffer.acquire()
                        fetchers.addTask {
                            let result = try await Self.fetch(item.unit, from: fetcher)
                            counters.addDownloaded(result.downloaded)
                            try await buffer.put(index, result.data)
                        }
                    }
                    for _ in 0..<concurrency { try await next() }
                    while try await fetchers.next() != nil { try await next() }
                }
            }
            group.addTask {
                var completed = done, unit = 0
                for (index, entry) in pending.enumerated() {
                    try Task.checkCancellation()
                    let count = plan[index].count
                    let first = unit
                    unit += count
                    let written = try await write(entry, units: first..<unit, buffer: buffer) { fresh, soFar in
                        counters.addWritten(fresh)
                        onProgress(.init(file: entry.file.path, bytesDone: completed + soFar, bytesTotal: total,
                                         bytesDownloaded: counters.downloaded, bytesWritten: counters.written))
                    }
                    try journal.markComplete(entry.file)
                    completed += written
                    onProgress(.init(file: entry.file.path, bytesDone: completed, bytesTotal: total,
                                     bytesDownloaded: counters.downloaded, bytesWritten: counters.written))
                }
            }
            do { while try await group.next() != nil {} }
            catch { group.cancelAll(); await buffer.fail(error); throw error }
        }

        for entry in selected where entry.file.kind == .link {
            try Task.checkCancellation()
            try layout.createSymlink(entry, in: destination)
        }
        try? FileManager.default.removeItem(at: work)
        if (try? FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent(Self.workDirectory).path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: destination.appendingPathComponent(Self.workDirectory))
        }
    }

    /// `progress` receives the bytes just written and the file's total so far.
    private func write(_ entry: GOGInstallLayout.Entry, units: Range<Int>, buffer: GOGUnitBuffer,
                       progress: (Int64, Int64) -> Void) async throws -> Int64 {
        let url = destination.appendingPathComponent(entry.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try GOGInstallLayout.refuseLinks(at: url, within: destination)
        let mode: mode_t = entry.file.executable ? 0o755 : 0o644
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw GOGError.malformed("open \(entry.path): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var hasher = GOGFileHash(entry.file)
        var written: Int64 = 0
        for index in units {
            let data = try await buffer.take(index)
            try handle.write(contentsOf: data)
            hasher.update(data)
            written += Int64(data.count)
            progress(Int64(data.count), written)
        }
        try handle.synchronize()
        try handle.close()
        guard written == entry.file.size else { throw GOGError.hashMismatch("\(entry.file.path) has \(written) of \(entry.file.size) bytes") }
        guard hasher.matches else { throw GOGError.hashMismatch(entry.file.path) }
        chmod(url.path, mode)
        return written
    }

    /// Paths that are missing or whose content differs from the manifest. A gen 2 file without a
    /// whole-file hash is checked chunk by chunk.
    public func invalidFiles(in manifest: GOGInstallManifest,
                             onVerification: (String, Int64, Int64) -> Void = { _, _, _ in }) throws -> [String] {
        let layout = try GOGInstallLayout(manifest.files)
        let total = layout.entries.filter { $0.file.kind == .file }.reduce(Int64(0)) { $0 + $1.file.size }
        var checked: Int64 = 0, invalid: [String] = []
        onVerification("", 0, total)
        for entry in layout.entries {
            try Task.checkCancellation()
            let url = destination.appendingPathComponent(entry.path)
            switch entry.file.kind {
            case .directory: continue
            case .link:
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != entry.file.target { invalid.append(entry.file.path) }
            case .file:
                let base = checked
                let valid = fileSize(url) == entry.file.size
                    && ((try? GOGFileHash.check(url: url, entry.file) { onVerification(entry.file.path, base + $0, total) }) ?? false)
                if !valid { invalid.append(entry.file.path) }
                checked += entry.file.size
                onVerification(entry.file.path, checked, total)
            }
        }
        return invalid
    }

    private func fileSize(_ url: URL) -> Int64? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(info.st_size)
    }

    private func safeName(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}

/// The whole-file check: MD5 when the manifest has one, else SHA-256, else each chunk's MD5.
struct GOGFileHash {
    let file: GOGFile
    private var md5 = Insecure.MD5()
    private var sha256 = SHA256()
    private var chunkHasher = Insecure.MD5()
    private var chunkIndex = 0, chunkFill: Int64 = 0
    private var chunksMatch = true

    init(_ file: GOGFile) { self.file = file }

    mutating func update(_ data: Data) {
        if file.md5 != nil { md5.update(data: data); return }
        if file.sha256 != nil { sha256.update(data: data); return }
        guard let chunks = file.chunks else { return }
        var rest = data[...]
        while !rest.isEmpty, chunkIndex < chunks.count {
            let take = Int(min(Int64(rest.count), chunks[chunkIndex].size - chunkFill))
            chunkHasher.update(data: rest.prefix(take))
            rest = rest.dropFirst(take); chunkFill += Int64(take)
            if chunkFill == chunks[chunkIndex].size {
                if Self.hex(chunkHasher.finalize()) != chunks[chunkIndex].md5 { chunksMatch = false }
                chunkHasher = Insecure.MD5(); chunkIndex += 1; chunkFill = 0
            }
        }
        if !rest.isEmpty { chunksMatch = false }
    }

    var matches: Bool {
        if let expected = file.md5 { return Self.hex(md5.finalize()) == expected.lowercased() }
        if let expected = file.sha256 { return Self.hex(sha256.finalize()) == expected.lowercased() }
        return chunksMatch && chunkIndex == (file.chunks?.count ?? 0)
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }

    static func check(data: Data, _ file: GOGFile) throws {
        var hasher = GOGFileHash(file); hasher.update(data)
        guard Int64(data.count) == file.size, hasher.matches else { throw GOGError.hashMismatch(file.path) }
    }

    static func check(url: URL, _ file: GOGFile, progress: (Int64) -> Void) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = GOGFileHash(file), read: Int64 = 0
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            try Task.checkCancellation()
            hasher.update(block); read += Int64(block.count); progress(read)
        }
        return hasher.matches
    }
}

/// Maps manifest paths to safe on-disk paths. Windows games expect case-insensitive paths, so
/// folders that differ only in case share the spelling first seen, even on case-sensitive volumes.
struct GOGInstallLayout {
    struct Entry { var file: GOGFile; var path: String }
    let entries: [Entry]

    init(_ files: [GOGFile]) throws {
        var spelling: [String: String] = [:], seen = Set<String>(), entries: [Entry] = []
        for file in files {
            let components = try GOGPaths.normalize(file.path).split(separator: "/").map(String.init)
            var resolved: [String] = []
            for component in components.dropLast() {
                let key = (resolved + [component]).joined(separator: "/").lowercased()
                resolved.append(spelling[key].map { String($0.split(separator: "/").last!) } ?? component)
                if spelling[key] == nil { spelling[key] = resolved.joined(separator: "/") }
            }
            let lastKey = (resolved + [components.last!]).joined(separator: "/").lowercased()
            resolved.append(spelling[lastKey].map { String($0.split(separator: "/").last!) } ?? components.last!)
            if file.kind == .directory, spelling[lastKey] == nil { spelling[lastKey] = resolved.joined(separator: "/") }
            let path = resolved.joined(separator: "/")
            guard seen.insert(path.lowercased()).inserted else { throw GOGError.malformed("duplicate path \(file.path)") }
            entries.append(Entry(file: file, path: path))
        }
        self.entries = entries
    }

    /// Links may only point inside the install.
    func createSymlink(_ entry: Entry, in destination: URL) throws {
        let url = destination.appendingPathComponent(entry.path)
        guard let target = entry.file.target, !target.isEmpty else { throw GOGError.malformed("link \(entry.path) has no target") }
        let resolved = url.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
        guard !target.hasPrefix("/"), resolved.hasPrefix(destination.standardizedFileURL.path + "/") else {
            throw GOGError.malformed("link \(entry.path) points outside the game")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.refuseLinks(at: url.deletingLastPathComponent().appendingPathComponent("x"), within: destination)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil || FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    /// Files are never written through a link: a stale link at the file is removed, and a link in
    /// any folder between the file and the install root is refused.
    static func refuseLinks(at url: URL, within root: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { try FileManager.default.removeItem(at: url) }
        let rootPath = root.standardizedFileURL.path
        var parent = url.deletingLastPathComponent().standardizedFileURL
        while parent.path.count > rootPath.count, parent.path.hasPrefix(rootPath) {
            if lstat(parent.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw GOGError.malformed("path \(url.path) crosses a link") }
            parent = parent.deletingLastPathComponent()
        }
    }
}

/// `hash:path` per finished file, appended and synced after the file itself is synced.
final class GOGResumeJournal: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var complete: Set<String>

    init(url: URL) throws {
        self.url = url
        complete = Set(((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
    }

    private func key(_ file: GOGFile) -> String {
        "\(file.md5 ?? file.sha256 ?? file.chunks?.map(\.md5).joined(separator: ",") ?? String(file.size)):\(file.path)"
    }

    func isComplete(_ file: GOGFile) -> Bool { lock.withLock { complete.contains(key(file)) } }

    func markComplete(_ file: GOGFile) throws {
        try lock.withLock {
            let line = key(file)
            guard complete.insert(line).inserted else { return }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            try handle.synchronize()
        }
    }
}

final class GOGCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var d: Int64 = 0, w: Int64 = 0
    func addDownloaded(_ n: Int64) { lock.withLock { d += n } }
    func addWritten(_ n: Int64) { lock.withLock { w += n } }
    var downloaded: Int64 { lock.withLock { d } }
    var written: Int64 { lock.withLock { w } }
}

/// Holds fetched units until the writer takes them, in order. A fetch takes a slot from a window
/// that frees when the writer takes its unit, so memory stays bounded.
actor GOGUnitBuffer {
    private var ready: [Int: Data] = [:]
    private var waiters: [Int: CheckedContinuation<Data, Error>] = [:]
    private var slotWaiters: [CheckedContinuation<Void, Error>] = []
    private var freeSlots: Int
    private var failure: Error?

    init(window: Int) { freeSlots = window }

    func acquire() async throws {
        if let failure { throw failure }
        try Task.checkCancellation()
        if freeSlots > 0 { freeSlots -= 1; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { slotWaiters.append($0) }
        } onCancel: { Task { await self.fail(CancellationError()) } }
    }

    func put(_ index: Int, _ data: Data) throws {
        if let failure { throw failure }
        if let waiter = waiters.removeValue(forKey: index) { release(); waiter.resume(returning: data) } else { ready[index] = data }
    }

    func take(_ index: Int) async throws -> Data {
        if let failure { throw failure }
        if let data = ready.removeValue(forKey: index) { release(); return data }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[index] = $0 }
        } onCancel: { Task { await self.fail(CancellationError()) } }
    }

    private func release() {
        if !slotWaiters.isEmpty { slotWaiters.removeFirst().resume() } else { freeSlots += 1 }
    }

    func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        waiters.values.forEach { $0.resume(throwing: error) }
        waiters = [:]
        slotWaiters.forEach { $0.resume(throwing: error) }
        slotWaiters = []
    }
}
