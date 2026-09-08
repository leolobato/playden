import XCTest
import AppKit
import ImageIO
import Domain
@testable import BigScreen

private actor ArtworkTransport {
    let data: Data
    var calls: [URL] = []
    var active = 0
    var peak = 0
    var paused = true
    let delay: Duration
    var waiting: [CheckedContinuation<Void, Never>] = []
    init(data: Data, delay: Duration = .zero) { self.data = data; self.delay = delay }
    func fetch(_ url: URL) async throws -> Data {
        calls.append(url); active += 1; peak = max(peak, active)
        defer { active -= 1 }
        if paused { await withCheckedContinuation { waiting.append($0) } }
        if delay > .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        return data
    }
    func release() {
        paused = false
        let continuations = waiting; waiting.removeAll()
        continuations.forEach { $0.resume() }
    }
    func stats() -> (calls: [URL], active: Int, peak: Int) { (calls, active, peak) }
}

final class ArtworkCacheTests: XCTestCase {
    private func url(_ name: String) -> URL { URL(string: "https://artwork.invalid/\(name).png")! }
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func png(width: Int = 4, height: Int = 4) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private static func waitForCalls(_ count: Int, transport: ArtworkTransport) async throws {
        let deadline = Date().addingTimeInterval(3)
        while await transport.stats().calls.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let calls = await transport.stats().calls.count
        XCTAssertGreaterThanOrEqual(calls, count)
    }

    @MainActor func testMissingCoverFallsBackAndCachedHeaderWorksOffline() async throws {
        let directory = try directory(), data = try png(width: 46, height: 21)
        let cover = url("missing-cover"), header = url("header")
        let loader = ArtworkLoader(directory: directory, fetch: { address in
            if address == cover { throw URLError(.fileDoesNotExist) }
            return data
        })
        let cache = ArtworkCache(loader: loader)
        let result = await cache.image(for: cover, fallbackURL: header)
        XCTAssertNotNil(result)
        XCTAssertTrue(result === cache.cachedImage(for: header))
        XCTAssertTrue(result === cache.cachedImage(for: cover, fallbackURL: header))
        XCTAssertNil(cache.cachedImage(for: cover), "Do not store landscape art under the portrait's URL")
        let offline = ArtworkCache(loader: ArtworkLoader(directory: directory, fetch: { _ in throw URLError(.notConnectedToInternet) }))
        let restored = await offline.image(for: cover, fallbackURL: header)
        XCTAssertNotNil(restored)
        XCTAssertGreaterThan(try XCTUnwrap(restored).size.width, try XCTUnwrap(restored).size.height)
    }

    @MainActor func testPortraitWinsAndCancellationDoesNotFetchFallback() async throws {
        let directory = try directory(), data = try png(width: 2, height: 3)
        let cover = url("cover"), header = url("header")
        let transport = ArtworkTransport(data: data)
        await transport.release()
        let cache = ArtworkCache(loader: ArtworkLoader(directory: directory, fetch: { try await transport.fetch($0) }))
        let result = await cache.image(for: cover, fallbackURL: header)
        XCTAssertNotNil(result)
        let calls = await transport.stats().calls; XCTAssertEqual(calls, [cover])
        let paused = ArtworkTransport(data: data)
        let cancelledCache = ArtworkCache(loader: ArtworkLoader(directory: try self.directory(), fetch: { try await paused.fetch($0) }))
        let task = Task { await cancelledCache.image(for: cover, fallbackURL: header) }
        try await Self.waitForCalls(1, transport: paused)
        task.cancel()
        let cancelled = await task.value; XCTAssertNil(cancelled)
        await paused.release()
        let cancelledCalls = await paused.stats().calls; XCTAssertEqual(cancelledCalls, [cover])
        XCTAssertNotNil(Game(id: .init(source: "steam", value: "18700"), title: "Test").coverFallbackURL)
        XCTAssertNil(Game(id: .init(source: "other", value: "18700"), title: "Test").coverFallbackURL)
    }

    @MainActor func testConcurrentConsumersShareOneLoadAndCancelIndependently() async throws {
        let transport = ArtworkTransport(data: try png())
        let loader = ArtworkLoader(directory: try directory(), fetch: { try await transport.fetch($0) })
        let cache = ArtworkCache(loader: loader)
        let address = url("shared")
        let first = Task { await cache.image(for: address) }
        let second = Task { await cache.image(for: address) }
        try await Self.waitForCalls(1, transport: transport)
        first.cancel()
        let cancelled = await first.value
        XCTAssertNil(cancelled)
        await transport.release()
        let result = await second.value
        XCTAssertNotNil(result)
        XCTAssertTrue(result === cache.cachedImage(for: address))
        let warm = await cache.image(for: address)
        XCTAssertTrue(warm === result)
        let stats = await transport.stats()
        XCTAssertEqual(stats.calls, [address])
    }

    func testLargeBurstIsBoundedAndQueuedCancellationDoesNotDownload() async throws {
        let transport = ArtworkTransport(data: try png())
        let loader = ArtworkLoader(directory: try directory(), concurrency: 4, fetch: { try await transport.fetch($0) })
        let addresses = (0..<40).map { url("tile-\($0)") }
        let tasks = addresses.map { address in Task { await loader.image(for: address) } }
        try await Self.waitForCalls(4, transport: transport)
        let initial = await transport.stats()
        XCTAssertEqual(initial.calls.count, 4)
        let cancelledIndices = addresses.indices.filter { !initial.calls.contains(addresses[$0]) }
        for index in cancelledIndices { tasks[index].cancel() }
        for index in cancelledIndices { let result = await tasks[index].value; XCTAssertNil(result) }
        await transport.release()
        for index in addresses.indices where !cancelledIndices.contains(index) {
            let result = await tasks[index].value; XCTAssertNotNil(result)
        }
        let stats = await transport.stats()
        XCTAssertEqual(stats.calls.count, 4)
        XCTAssertLessThanOrEqual(stats.peak, 4)
        // A cancelled queued request may be requested again immediately; it isn't a cached failure.
        let result = await loader.image(for: addresses[cancelledIndices[0]])
        XCTAssertNotNil(result)
    }

    func testDiskLRUSurvivesRestartAndRepairsCorruptFiles() async throws {
        let directory = try directory(), data = try png()
        let transport = ArtworkTransport(data: data)
        await transport.release()
        let loader = ArtworkLoader(directory: directory, diskLimit: data.count * 2, fetch: { try await transport.fetch($0) })
        let a = url("a"), b = url("b"), c = url("c")
        _ = await loader.image(for: a); _ = await loader.image(for: b)
        _ = await loader.image(for: a) // A is most recently used, so C must evict B.
        _ = await loader.image(for: c)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(ArtworkLoader.filename(for: b)).path))
        let offline = ArtworkLoader(directory: directory, diskLimit: data.count * 2, fetch: { _ in throw URLError(.notConnectedToInternet) })
        let cachedA = await offline.image(for: a), cachedC = await offline.image(for: c)
        XCTAssertNotNil(cachedA); XCTAssertNotNil(cachedC)
        let absent = await offline.image(for: b); XCTAssertNil(absent)
        let stats = await transport.stats(); XCTAssertEqual(stats.calls.count, 3)

        let file = directory.appendingPathComponent(ArtworkLoader.filename(for: a))
        try Data("interrupted or corrupt artwork".utf8).write(to: file)
        let repaired = ArtworkLoader(directory: directory, diskLimit: data.count * 2, fetch: { try await transport.fetch($0) })
        let image = await repaired.image(for: a)
        XCTAssertNotNil(image)
        XCTAssertEqual(try Data(contentsOf: file), data)
        let bytes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, data.count * 2)
    }

    func testSixHundredLoadsCompleteWithinConcurrencyAndDiskBudgets() async throws {
        let directory = try directory(), data = try png()
        let transport = ArtworkTransport(data: data, delay: .milliseconds(2))
        await transport.release()
        let loader = ArtworkLoader(directory: directory, diskLimit: data.count * 100, concurrency: 4,
                                   fetch: { try await transport.fetch($0) })
        let addresses = (0..<600).map { url("library-\($0)") }
        let loaded = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for address in addresses { group.addTask { await loader.image(for: address) != nil } }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(loaded, 600)
        let stats = await transport.stats()
        XCTAssertEqual(Set(stats.calls), Set(addresses))
        XCTAssertLessThanOrEqual(stats.peak, 4)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(files.count, 100)
        XCTAssertLessThanOrEqual(bytes, data.count * 100)
    }

    func testStartupPrunesLegacyCacheAndPreservesUnrelatedFiles() async throws {
        let directory = try directory(), data = try png()
        let addresses = (0..<6).map { url("legacy-\($0)") }
        for (index, address) in addresses.enumerated() {
            let file = directory.appendingPathComponent(ArtworkLoader.filename(for: address))
            try data.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: file.path)
        }
        let unrelated = directory.appendingPathComponent("notes.txt")
        try Data("leave unrelated files alone".utf8).write(to: unrelated)
        let loader = ArtworkLoader(directory: directory, diskLimit: data.count * 2, fetch: { _ in throw URLError(.notConnectedToInternet) })
        let image = await loader.image(for: addresses[5]); XCTAssertNotNil(image)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(files), ["notes.txt", ArtworkLoader.filename(for: addresses[4]), ArtworkLoader.filename(for: addresses[5])])
    }

    func testOversizedAndInvalidResponsesAreNotCachedAndHugeImagesAreDownsampled() async throws {
        let directory = try directory()
        let tooBig = ArtworkLoader(directory: directory, fetch: { _ in Data(count: ArtworkLoader.maximumFileBytes + 1) })
        let oversized = await tooBig.image(for: url("oversized")); XCTAssertNil(oversized)
        let invalid = ArtworkLoader(directory: directory, fetch: { _ in Data("not an image".utf8) })
        let bad = await invalid.image(for: url("bad")); XCTAssertNil(bad)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let data = try png(width: 5000, height: 20)
        let valid = ArtworkLoader(directory: directory, fetch: { _ in data })
        let decoded = await valid.image(for: url("large"))
        let image = try XCTUnwrap(decoded)
        XCTAssertEqual(image.width, 4096)
        XCTAssertGreaterThan(image.height, 0)
        XCTAssertNotEqual(image.alphaInfo, .none)
    }
}
