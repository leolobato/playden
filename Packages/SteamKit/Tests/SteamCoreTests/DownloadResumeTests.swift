import XCTest
import CryptoKit
@testable import SteamCore

final class DownloadResumeTests: XCTestCase {
    private let pieces = [Data("first".utf8), Data("second".utf8), Data("third".utf8)]
    private func fixture(path: String = "Game/data.bin", gid: UInt64 = 9, badHash: Bool = false) -> DepotManifest {
        var offset: UInt64 = 0
        let chunks = pieces.map { data -> DepotManifest.Chunk in
            defer { offset += UInt64(data.count) }
            return .init(sha: SteamCrypto.sha1(data), offset: offset, compressedSize: UInt32(data.count),
                         uncompressedSize: UInt32(data.count), checksum: DepotManifest.Chunk.adler(data))
        }
        let data = pieces.reduce(Data(), +)
        return .init(depotID: 7, gid: gid, files: [.init(path: path, size: UInt64(data.count), chunks: chunks,
                     contentSHA1: badHash ? Data(repeating: 0, count: 20) : SteamCrypto.sha1(data))], totalSize: UInt64(data.count))
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("download-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func download(_ root: URL) -> ResumableDepotDownload {
        var value = ResumableDepotDownload(destination: root); value.chunkConcurrency = 1; return value
    }
    private func partial(_ root: URL) throws -> URL {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        return try XCTUnwrap(files.allObjects.compactMap { $0 as? URL }.first { $0.pathExtension == "partial" })
    }
    func testReopenReusesOnlyDurableVerifiedChunks() async throws {
        let root = try root(), manifest = fixture(), feed = Feed(pieces, failAt: 5)
        do { try await download(root).download(manifest: manifest, fetchChunk: feed.fetch); XCTFail("Expected interruption") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Game/data.bin").path))
        let resumed = Feed(pieces)
        try await download(root).download(manifest: manifest, fetchChunk: resumed.fetch)
        let requested = await resumed.requested
        XCTAssertEqual(requested, [5, 11])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Game/data.bin")), pieces.reduce(Data(), +))
        XCTAssertEqual(try download(root).invalidFiles(in: manifest), [])
    }
    func testTransferProgressExcludesRetainedChunksAndCompleteFiles() async throws {
        let root = try root(), manifest = fixture(), first = Feed(pieces, failAt: 5)
        do { try await download(root).download(manifest: manifest, fetchChunk: first.fetch) } catch {}
        let samples = ProgressSamples()
        var resumed = download(root); resumed.onProgress = samples.append
        try await resumed.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(samples.values.first?.bytesDone, 5)
        XCTAssertEqual(samples.values.first?.bytesWritten, 0)
        XCTAssertEqual(samples.values.last?.bytesDone, 16)
        XCTAssertEqual(samples.values.last?.bytesWritten, 11)
        let cached = ProgressSamples()
        resumed.onProgress = cached.append
        try await resumed.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(cached.values.last?.bytesDone, 16)
        XCTAssertEqual(cached.values.last?.bytesWritten, 0)
    }
    func testCorruptRetainedChunkIsFetchedAgain() async throws {
        let root = try root(), manifest = fixture(), feed = Feed(pieces, failAt: 11)
        do { try await download(root).download(manifest: manifest, fetchChunk: feed.fetch) } catch {}
        let handle = try FileHandle(forWritingTo: partial(root))
        try handle.write(contentsOf: Data("WRONG".utf8)); try handle.close()
        let resumed = Feed(pieces)
        try await download(root).download(manifest: manifest, fetchChunk: resumed.fetch)
        let requested = await resumed.requested
        XCTAssertEqual(requested, [0, 11])
    }
    func testFailedReplacementPreservesOldFileAndRepairsSameSizeCorruption() async throws {
        let root = try root(), manifest = fixture(), target = root.appendingPathComponent("Game/data.bin")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = Data(repeating: 88, count: 16); try old.write(to: target)
        let failed = Feed(pieces, failAt: 5)
        do { try await download(root).download(manifest: manifest, fetchChunk: failed.fetch) } catch {}
        XCTAssertEqual(try Data(contentsOf: target), old)
        XCTAssertEqual(try download(root).invalidFiles(in: manifest), ["Game/data.bin"])
        try await download(root).download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(try Data(contentsOf: target), pieces.reduce(Data(), +))
    }
    func testPinnedManifestChangeDoesNotMixCheckpoints() async throws {
        let root = try root(), interrupted = Feed(pieces, failAt: 5)
        do { try await download(root).download(manifest: fixture(), fetchChunk: interrupted.fetch) } catch {}
        let resumed = Feed(pieces)
        try await download(root).download(manifest: fixture(gid: 10), fetchChunk: resumed.fetch)
        let requested = await resumed.requested
        XCTAssertEqual(requested, [0, 5, 11])
    }
    func testWholeFileHashFailureDoesNotTrapRetry() async throws {
        let root = try root(), manifest = fixture(badHash: true)
        do { try await download(root).download(manifest: manifest, fetchChunk: Feed(pieces).fetch); XCTFail() } catch {}
        let retry = Feed(pieces)
        do { try await download(root).download(manifest: manifest, fetchChunk: retry.fetch); XCTFail() } catch {}
        let requested = await retry.requested
        XCTAssertEqual(requested, [0, 5, 11])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Game/data.bin").path))
    }
    func testInvalidManifestPathsRejectedBeforeAnyFetch() async throws {
        let root = try root(), feed = Feed(pieces)
        for path in ["../escape", "Game/../../escape", "Game\\..\\escape", "/absolute", "C:\\escape", ".gn-download/lock"] {
            do { try await download(root).download(manifest: fixture(path: path), fetchChunk: feed.fetch); XCTFail(path) } catch {}
        }
        let requested = await feed.requested
        XCTAssertTrue(requested.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testExistingSymlinkParentCannotRedirectWrites() async throws {
        let root = try root(), outside = try self.root(), feed = Feed(pieces)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Game"), withDestinationURL: outside)
        do { try await download(root).download(manifest: fixture(), fetchChunk: feed.fetch); XCTFail() } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testExclusiveDestinationLeaseAndEmptyServerList() async throws {
        let root = try root(), lease = try DownloadWorkspace(destination: root)
        defer { withExtendedLifetime(lease) {} }
        do {
            XCTAssertThrowsError(try DownloadWorkspace(destination: root))
            do { _ = try await DownloadEngine.fetchChunkWithRetry(servers: [], depotID: 7,
                   chunk: fixture().files[0].chunks[0], key: Data()); XCTFail() } catch {}
        }
    }
    func testChecksumAndEmptyFile() async throws {
        let chunk = fixture().files[0].chunks[0]
        XCTAssertNoThrow(try chunk.validate(pieces[0]))
        XCTAssertThrowsError(try chunk.validate(Data("wrong".utf8)))
        XCTAssertEqual(DepotManifest.Chunk.adler(Data("abc".utf8)), 0x024a0126)
        let root = try root(), empty = DepotManifest(depotID: 7, gid: 9,
            files: [.init(path: "empty", size: 0, chunks: [], contentSHA1: SteamCrypto.sha1(Data()))], totalSize: 0)
        var value = download(root); value.chunkConcurrency = 0
        try await value.download(manifest: empty) { _ in XCTFail(); return Data() }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("empty")), Data())
    }
}

private actor Feed {
    let pieces: [Data]
    let failAt: UInt64?
    var requested: [UInt64] = []
    init(_ pieces: [Data], failAt: UInt64? = nil) { self.pieces = pieces; self.failAt = failAt }
    nonisolated var fetch: @Sendable (DepotManifest.Chunk) async throws -> Data {
        { chunk in try await self.read(chunk) }
    }
    func read(_ chunk: DepotManifest.Chunk) throws -> Data {
        requested.append(chunk.offset)
        if chunk.offset == failAt { throw CancellationError() }
        return pieces.first { SteamCrypto.sha1($0) == chunk.sha }!
    }
}

private final class ProgressSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [DownloadProgress] = []
    func append(_ value: DownloadProgress) { lock.lock(); defer { lock.unlock() }; samples.append(value) }
    var values: [DownloadProgress] { lock.lock(); defer { lock.unlock() }; return samples }
}
