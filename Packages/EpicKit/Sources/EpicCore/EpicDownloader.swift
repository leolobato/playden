import Foundation
import CryptoKit
import Darwin

public struct EpicDownloadProgress: Equatable, Sendable {
    public struct Verification: Equatable, Sendable { public var bytesChecked: UInt64; public var bytesTotal: UInt64 }
    public var file: String
    /// Assembled file bytes, including files a previous run already finished.
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    /// Compressed chunk bytes fetched by this run.
    public var bytesDownloaded: UInt64
    /// File bytes written by this run.
    public var bytesWritten: UInt64
    public var verification: Verification?
}

/// Fetches chunk files from the CDN bases the manifest API returned, rotating between them on failure.
public struct EpicChunkFetcher: Sendable {
    let http: EpicHTTP
    public let baseURLs: [URL]
    public var attemptsPerBase = 3

    public init(baseURLs: [URL], config: EpicClientConfig = .default, transport: any EpicTransport = URLSession.shared,
                pause: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        var http = EpicHTTP(config: config, transport: transport, pause: pause)
        http.attempts = 1
        self.http = http; self.baseURLs = baseURLs
    }

    init(baseURLs: [URL], http: EpicHTTP) {
        var http = http
        http.attempts = 1
        self.http = http; self.baseURLs = baseURLs
    }

    public func fetch(_ path: String) async throws -> Data {
        guard !baseURLs.isEmpty else { throw EpicError.malformed("no CDN base URL") }
        var lastError: Error = EpicError.network("no attempt")
        let total = baseURLs.count * max(1, attemptsPerBase)
        for attempt in 0..<total {
            try Task.checkCancellation()
            let base = baseURLs[attempt % baseURLs.count]
            do { return try await http.request("GET", base.appendingPathComponent(path), auth: .none) }
            catch EpicError.cancelled { throw EpicError.cancelled }
            catch {
                lastError = error
                if attempt + 1 < total, attempt + 1 >= baseURLs.count { try await http.pause(Double(min(1 << (attempt / baseURLs.count), 16))) }
            }
        }
        throw lastError
    }
}

/// Writes a build from its manifest into `destination`. Each unique chunk is fetched once and checked
/// against the manifest's SHA-1; files are written in order and journaled once complete, so a
/// cancelled or crashed run resumes after the last finished file.
public struct EpicDownloader: Sendable {
    public let destination: URL
    public var concurrency = 8
    /// Decoded chunks still needed later stay in memory up to this size, then move to disk.
    public var retainedChunkMemory = 256 * 1024 * 1024
    public var onProgress: @Sendable (EpicDownloadProgress) -> Void = { _ in }

    public init(destination: URL) { self.destination = destination }

    static let workDirectory = ".epic-download"

    /// `only` limits the run to those files (repair). Symlinks are created after every file.
    public func download(_ manifest: EpicManifest, secrets: [String: String] = [:], only: Set<String>? = nil,
                         fetch: @escaping @Sendable (String) async throws -> Data) async throws {
        let layout = try EpicInstallLayout(manifest: manifest)
        let selected = layout.entries.filter { only?.contains($0.file.filename) ?? true }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let work = destination.appendingPathComponent("\(Self.workDirectory)/\(safeName(manifest.meta.buildID))", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let journal = try ResumeJournal(url: work.appendingPathComponent("resume"))

        let regular = selected.filter { $0.file.symlinkTarget.isEmpty }
        let total = regular.reduce(UInt64(0)) { $0 + $1.file.fileSize }
        var pending: [EpicInstallLayout.Entry] = []
        var done: UInt64 = 0
        for entry in regular {
            let url = destination.appendingPathComponent(entry.path)
            if only == nil, journal.isComplete(entry.file), fileSize(url) == entry.file.fileSize { done += entry.file.fileSize } else { pending.append(entry) }
        }
        onProgress(.init(file: "", bytesDone: done, bytesTotal: total, bytesDownloaded: 0, bytesWritten: 0))

        let chunks = manifest.chunksByGUID
        var uses: [EpicGUID: Int] = [:]
        var order: [EpicGUID] = []
        for entry in pending {
            for part in entry.file.chunkParts {
                guard chunks[part.guid] != nil else { throw EpicError.malformed("file \(entry.file.filename) references unknown chunk \(part.guid)") }
                if uses[part.guid] == nil { order.append(part.guid) }
                uses[part.guid, default: 0] += 1
            }
        }
        let cache = ChunkCache(uses: uses, window: max(2, concurrency * 2), retainedLimit: retainedChunkMemory,
                               spillDirectory: work.appendingPathComponent("chunks", isDirectory: true))
        let counters = Counters()
        let paths = order.map { (guid: $0, info: chunks[$0]!) }
        let featureLevel = manifest.chunkDirectoryVersion
        let concurrency = max(1, min(16, self.concurrency))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { fetchers in
                    var iterator = paths.makeIterator()
                    func next() async throws {
                        guard let item = iterator.next() else { return }
                        try await cache.acquireSlot()
                        fetchers.addTask {
                            let raw = try await fetch(EpicManifest.chunkPath(item.info, featureLevel: featureLevel))
                            counters.addDownloaded(UInt64(raw.count))
                            let chunk = try EpicChunk.decode(raw, secrets: secrets, expectedSHA1: item.info.sha1)
                            try await cache.put(item.guid, chunk.data)
                        }
                    }
                    for _ in 0..<concurrency { try await next() }
                    while try await fetchers.next() != nil { try await next() }
                }
            }
            group.addTask {
                var completed = done
                for entry in pending {
                    try Task.checkCancellation()
                    let written = try await write(entry, cache: cache) { fresh, soFar in
                        counters.addWritten(fresh)
                        onProgress(.init(file: entry.file.filename, bytesDone: completed + soFar, bytesTotal: total,
                                         bytesDownloaded: counters.downloaded, bytesWritten: counters.written))
                    }
                    try journal.markComplete(entry.file)
                    completed += written
                    onProgress(.init(file: entry.file.filename, bytesDone: completed, bytesTotal: total,
                                     bytesDownloaded: counters.downloaded, bytesWritten: counters.written))
                }
            }
            do { while try await group.next() != nil {} }
            catch { group.cancelAll(); await cache.fail(error); throw error }
        }

        for entry in selected where !entry.file.symlinkTarget.isEmpty {
            try Task.checkCancellation()
            try layout.createSymlink(entry, in: destination)
        }
        try? FileManager.default.removeItem(at: work)
        if (try? FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent(Self.workDirectory).path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: destination.appendingPathComponent(Self.workDirectory))
        }
    }

    /// `progress` receives the bytes just written and the file's total so far.
    private func write(_ entry: EpicInstallLayout.Entry, cache: ChunkCache, progress: (UInt64, UInt64) -> Void) async throws -> UInt64 {
        let url = destination.appendingPathComponent(entry.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EpicInstallLayout.refuseLinks(at: url, within: destination)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, entry.file.isExecutable ? 0o755 : 0o644)
        guard fd >= 0 else { throw EpicError.malformed("open \(entry.path): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var hasher = Insecure.SHA1()
        var written: UInt64 = 0
        for part in entry.file.chunkParts {
            let data = try await cache.take(part.guid)
            let start = Int(part.offset), end = start + Int(part.size)
            guard end <= data.count else { throw EpicError.malformed("chunk part out of range in \(entry.path)") }
            let slice = data.subdata(in: start..<end)
            try handle.write(contentsOf: slice)
            hasher.update(data: slice)
            written += UInt64(slice.count)
            progress(UInt64(slice.count), written)
        }
        try handle.synchronize()
        try handle.close()
        guard Data(hasher.finalize()) == entry.file.sha1 || entry.file.sha1.allSatisfy({ $0 == 0 }) else {
            throw EpicError.hashMismatch(entry.file.filename)
        }
        if entry.file.isExecutable { chmod(url.path, 0o755) }
        return written
    }

    /// Files that are missing or whose SHA-1 differs from the manifest.
    public func invalidFiles(in manifest: EpicManifest,
                             onVerification: (String, UInt64, UInt64) -> Void = { _, _, _ in }) throws -> [String] {
        let layout = try EpicInstallLayout(manifest: manifest)
        let total = layout.entries.filter { $0.file.symlinkTarget.isEmpty }.reduce(UInt64(0)) { $0 + $1.file.fileSize }
        var checked: UInt64 = 0
        var invalid: [String] = []
        onVerification("", 0, total)
        for entry in layout.entries {
            try Task.checkCancellation()
            let url = destination.appendingPathComponent(entry.path)
            if !entry.file.symlinkTarget.isEmpty {
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != entry.file.symlinkTarget { invalid.append(entry.file.filename) }
                continue
            }
            let base = checked
            if fileSize(url) != entry.file.fileSize || (try? sha1(of: url) { onVerification(entry.file.filename, base + $0, total) }) != entry.file.sha1 {
                invalid.append(entry.file.filename)
            }
            checked += entry.file.fileSize
            onVerification(entry.file.filename, checked, total)
        }
        return invalid
    }

    private func sha1(of url: URL, progress: (UInt64) -> Void) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        var read: UInt64 = 0
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: block); read += UInt64(block.count); progress(read)
        }
        return Data(hasher.finalize())
    }

    private func fileSize(_ url: URL) -> UInt64? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return UInt64(info.st_size)
    }

    private func safeName(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}

/// Maps manifest paths to safe on-disk paths. Windows games expect case-insensitive paths, so
/// directories that differ only in case share the spelling first seen, even on case-sensitive volumes.
struct EpicInstallLayout {
    struct Entry { var file: EpicManifest.File; var path: String }
    let entries: [Entry]

    init(manifest: EpicManifest) throws {
        var spelling: [String: String] = [:]
        var seen = Set<String>()
        var entries: [Entry] = []
        for file in manifest.files.sorted(by: { $0.filename.lowercased() < $1.filename.lowercased() }) {
            let components = file.filename.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty, !file.filename.hasPrefix("/"),
                  !components.contains(where: { $0 == ".." || $0 == "." }) else { throw EpicError.malformed("unsafe path \(file.filename)") }
            var resolved: [String] = []
            for component in components.dropLast() {
                let key = (resolved + [component]).joined(separator: "/").lowercased()
                resolved.append(spelling[key].map { String($0.split(separator: "/").last!) } ?? component)
                if spelling[key] == nil { spelling[key] = resolved.joined(separator: "/") }
            }
            resolved.append(components.last!)
            let path = resolved.joined(separator: "/")
            guard seen.insert(path.lowercased()).inserted else { throw EpicError.malformed("duplicate path \(file.filename)") }
            entries.append(Entry(file: file, path: path))
        }
        self.entries = entries
    }

    /// Links may only point inside the install.
    func createSymlink(_ entry: Entry, in destination: URL) throws {
        let url = destination.appendingPathComponent(entry.path)
        let target = entry.file.symlinkTarget
        let resolved = url.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
        guard !target.hasPrefix("/"), resolved.hasPrefix(destination.standardizedFileURL.path + "/") else {
            throw EpicError.malformed("symlink \(entry.path) points outside the game")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
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
            if lstat(parent.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw EpicError.malformed("path \(url.path) crosses a link") }
            parent = parent.deletingLastPathComponent()
        }
    }
}

/// `sha1hex:path` per finished file, appended and synced after the file itself is synced.
final class ResumeJournal: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var complete: Set<String>

    init(url: URL) throws {
        self.url = url
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        complete = Set(text.split(separator: "\n").map(String.init))
    }

    private func key(_ file: EpicManifest.File) -> String { "\(file.sha1.hexString):\(file.filename)" }

    func isComplete(_ file: EpicManifest.File) -> Bool { lock.withLock { complete.contains(key(file)) } }

    func markComplete(_ file: EpicManifest.File) throws {
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

final class Counters: @unchecked Sendable {
    private let lock = NSLock()
    private var d: UInt64 = 0, w: UInt64 = 0
    func addDownloaded(_ n: UInt64) { lock.withLock { d += n } }
    func addWritten(_ n: UInt64) { lock.withLock { w += n } }
    var downloaded: UInt64 { lock.withLock { d } }
    var written: UInt64 { lock.withLock { w } }
}

/// Holds decoded chunks between fetch and their last use. Fetches take a slot from a small window
/// that frees when the writer first uses the chunk; chunks needed again stay in memory up to a
/// limit, then move to disk.
actor ChunkCache {
    private var uses: [EpicGUID: Int]
    private var memory: [EpicGUID: Data] = [:]
    private var spilled = Set<EpicGUID>()
    private var retained = Set<EpicGUID>()
    private var retainedBytes = 0
    private var waiters: [EpicGUID: [CheckedContinuation<Data, Error>]] = [:]
    private var slotWaiters: [CheckedContinuation<Void, Error>] = []
    private var freeSlots: Int
    private let retainedLimit: Int
    private let spillDirectory: URL
    private var failure: Error?

    init(uses: [EpicGUID: Int], window: Int, retainedLimit: Int, spillDirectory: URL) {
        self.uses = uses; freeSlots = window; self.retainedLimit = retainedLimit; self.spillDirectory = spillDirectory
    }

    func acquireSlot() async throws {
        if let failure { throw failure }
        try Task.checkCancellation()
        if freeSlots > 0 { freeSlots -= 1; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { slotWaiters.append($0) }
        } onCancel: { Task { await self.fail(CancellationError()) } }
    }

    private func releaseSlot() {
        if !slotWaiters.isEmpty { slotWaiters.removeFirst().resume() } else { freeSlots += 1 }
    }

    func put(_ guid: EpicGUID, _ data: Data) throws {
        if let failure { throw failure }
        if let waiting = waiters.removeValue(forKey: guid), let first = waiting.first {
            memory[guid] = data
            first.resume(returning: consume(guid, data))
            for other in waiting.dropFirst() { other.resume(throwing: EpicError.malformed("concurrent use of chunk \(guid)")) }
        } else {
            memory[guid] = data
        }
    }

    func take(_ guid: EpicGUID) async throws -> Data {
        if let failure { throw failure }
        if let data = memory[guid] { return consume(guid, data) }
        if spilled.contains(guid) {
            let data = try Data(contentsOf: spillDirectory.appendingPathComponent(guid.description))
            return consume(guid, data)
        }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[guid, default: []].append($0) }
        } onCancel: { Task { await self.fail(CancellationError()) } }
    }

    /// One use of the chunk; frees its fetch slot on first use and drops it after the last.
    private func consume(_ guid: EpicGUID, _ data: Data) -> Data {
        let remaining = (uses[guid] ?? 1) - 1
        uses[guid] = remaining
        let firstUse = !retained.contains(guid) && !spilled.contains(guid)
        if remaining <= 0 {
            if memory.removeValue(forKey: guid) != nil, retained.remove(guid) != nil { retainedBytes -= data.count }
            if spilled.remove(guid) != nil { try? FileManager.default.removeItem(at: spillDirectory.appendingPathComponent(guid.description)) }
            memory[guid] = nil
        } else if firstUse {
            if retainedBytes + data.count <= retainedLimit {
                retained.insert(guid); retainedBytes += data.count
            } else if (try? spill(guid, data)) != nil {
                memory[guid] = nil
            } else {
                retained.insert(guid); retainedBytes += data.count
            }
        }
        if firstUse { releaseSlot() }
        return data
    }

    private func spill(_ guid: EpicGUID, _ data: Data) throws {
        try FileManager.default.createDirectory(at: spillDirectory, withIntermediateDirectories: true)
        try data.write(to: spillDirectory.appendingPathComponent(guid.description))
        spilled.insert(guid)
    }

    func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        for (_, list) in waiters { list.forEach { $0.resume(throwing: error) } }
        waiters = [:]
        slotWaiters.forEach { $0.resume(throwing: error) }
        slotWaiters = []
    }
}
