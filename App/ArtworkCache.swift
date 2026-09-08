import AppKit
import CryptoKit
import ImageIO

/// UI access is memory-only. File access and eager image decoding belong to the loader actor.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let memory = NSCache<NSURL, NSImage>()
    private let loader: ArtworkLoader

    init(loader: ArtworkLoader = ArtworkLoader()) {
        self.loader = loader
        memory.totalCostLimit = 160 * 1024 * 1024
    }

    func cachedImage(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        return memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cachedImage(for: url) { return image }
        guard let decoded = await loader.image(for: url), !Task.isCancelled else { return nil }
        // Another consumer may have installed this shared request's result while we suspended.
        if let image = cachedImage(for: url) { return image }
        let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
        memory.setObject(image, forKey: url as NSURL, cost: decoded.bytesPerRow * decoded.height)
        return image
    }
}

/// A bounded, coalescing queue. A cancelled view releases its subscription immediately; shared
/// work continues only while another view (or detail-art prefetch) still needs it.
actor ArtworkLoader {
    typealias Fetch = @Sendable (URL) async throws -> Data
    private struct Request {
        let id = UUID()
        var consumers: [UUID: CheckedContinuation<CGImage?, Never>] = [:]
        var task: Task<Void, Never>?
    }
    private struct Entry {
        let bytes: Int
        var accessed: Date
    }
    private let directory: URL
    private let diskLimit: Int
    private let concurrency: Int
    private let fetch: Fetch
    private var indexed = false
    private var entries: [String: Entry] = [:]
    private var diskBytes = 0
    private var requests: [URL: Request] = [:]
    private var queue: [URL] = []
    private var active = 0
    private var failures: [URL: Date] = [:]
    static let maximumFileBytes = 16 * 1024 * 1024

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameNative BigScreen/artwork"),
         diskLimit: Int = 512 * 1024 * 1024, concurrency: Int = 4,
         fetch: @escaping Fetch = ArtworkLoader.download) {
        self.directory = directory
        self.diskLimit = max(0, diskLimit)
        self.concurrency = max(1, concurrency)
        self.fetch = fetch
    }

    func image(for url: URL) async -> CGImage? {
        let consumer = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if let failedAt = failures[url], Date().timeIntervalSince(failedAt) < 30 {
                    continuation.resume(returning: nil); return
                }
                if requests[url] == nil { requests[url] = Request(); queue.append(url) }
                requests[url]?.consumers[consumer] = continuation
                startNext()
            }
        } onCancel: {
            Task { await self.cancel(url: url, consumer: consumer) }
        }
    }

    private func cancel(url: URL, consumer: UUID) {
        guard let continuation = requests[url]?.consumers.removeValue(forKey: consumer) else { return }
        continuation.resume(returning: nil)
        if requests[url]?.consumers.isEmpty == true {
            requests.removeValue(forKey: url)?.task?.cancel()
            queue.removeAll { $0 == url }
        }
    }

    private func startNext() {
        while active < concurrency, !queue.isEmpty {
            let url = queue.removeFirst()
            guard let id = requests[url]?.id else { continue }
            active += 1
            requests[url]?.task = Task {
                let result = await load(url)
                finish(url: url, id: id, image: result)
            }
        }
    }

    private func finish(url: URL, id: UUID, image: CGImage?) {
        active -= 1
        if requests[url]?.id == id, let request = requests.removeValue(forKey: url) {
            if image == nil {
                failures = failures.filter { Date().timeIntervalSince($0.value) < 30 }
                if failures.count >= 256, let oldest = failures.min(by: { $0.value < $1.value })?.key {
                    failures.removeValue(forKey: oldest)
                }
                failures[url] = Date()
            } else { failures.removeValue(forKey: url) }
            request.consumers.values.forEach { $0.resume(returning: image) }
        }
        startNext()
    }

    static func filename(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func load(_ url: URL) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        indexDiskIfNeeded()
        let name = Self.filename(for: url)
        let file = directory.appendingPathComponent(name)
        if let entry = entries[name] {
            if entry.bytes <= Self.maximumFileBytes,
               let data = try? Data(contentsOf: file), let image = Self.decode(data) {
                entries[name]?.accessed = Date()
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                return image
            }
            remove(name)
        }
        guard !Task.isCancelled, let data = try? await fetch(url), !Task.isCancelled,
              data.count <= Self.maximumFileBytes, let image = Self.decode(data), !Task.isCancelled else { return nil }
        if data.count <= diskLimit, entries[name] == nil {
            // Make room before publication; a failed cache write never prevents displaying valid art.
            prune(to: diskLimit - data.count)
            if diskBytes + data.count <= diskLimit {
                do {
                    try data.write(to: file, options: .atomic)
                    entries[name] = Entry(bytes: data.count, accessed: Date())
                    diskBytes += data.count
                } catch { /* Artwork remains available in the memory cache. */ }
            }
        }
        return image
    }

    private func indexDiskIfNeeded() {
        guard !indexed else { return }
        indexed = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? [] {
            let name = file.lastPathComponent
            guard name.count == 64, name.allSatisfy({ "0123456789abcdef".contains($0) }),
                  let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true, let bytes = values.fileSize else { continue }
            entries[name] = Entry(bytes: bytes, accessed: values.contentModificationDate ?? .distantPast)
            diskBytes += bytes
        }
        prune(to: diskLimit)
    }

    private func prune(to limit: Int) {
        guard diskBytes > limit else { return }
        for (name, _) in entries.sorted(by: { $0.value.accessed < $1.value.accessed }) {
            remove(name)
            if diskBytes <= limit { break }
        }
    }

    private func remove(_ name: String) {
        do {
            let file = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            if let removed = entries.removeValue(forKey: name) { diskBytes -= removed.bytes }
        } catch { /* Keep failed removals accounted for instead of growing past the disk budget. */ }
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard data.count <= maximumFileBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    private static func download(_ url: URL) async throws -> Data {
        guard ["https", "http"].contains(url.scheme) else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes <= maximumFileBytes else { throw URLError(.cannotDecodeContentData) }
        try Task.checkCancellation()
        return try Data(contentsOf: file)
    }
}
