import XCTest
import AppKit
import ImageIO
import Artwork
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

}
