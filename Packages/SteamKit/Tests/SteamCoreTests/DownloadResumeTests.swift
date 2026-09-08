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
    func testOriginalVerificationReportsAggregateBytesAndStillRejectsCorruption() async throws {
        let root = try root(), first = fixture(path: "first.bin"), second = fixture(path: "second.bin")
        let manifest = DepotManifest(depotID: 7, gid: 9, files: first.files + second.files, totalSize: 32)
        try await download(root).download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        var counts: [UInt64] = []
        let valid = try download(root).invalidFiles(in: manifest) { _, checked, total in
            counts.append(checked); XCTAssertEqual(total, 32)
        }
        XCTAssertTrue(valid.isEmpty)
        XCTAssertEqual(counts.first, 0); XCTAssertEqual(counts.last, 32)
        XCTAssertTrue(counts.contains(16)); XCTAssertEqual(counts, counts.sorted())
        try Data("bad".utf8).write(to: root.appendingPathComponent("second.bin"))
        let invalid = try download(root).invalidFiles(in: manifest) { _, checked, _ in counts.append(checked) }
        XCTAssertEqual(invalid, ["second.bin"])
        XCTAssertEqual(counts.last, 32, "100% examined must not imply every file was valid")
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
    func testLargeFileGrowsWithReceivedChunksAndShortPartialResumes() async throws {
        let root = try root()
        let data = Data(repeating: 7, count: 1024 * 1024), sha = SteamCrypto.sha1(data)
        let checksum = DepotManifest.Chunk.adler(data)
        let chunks = (0..<20_000).map { index in
            DepotManifest.Chunk(sha: sha, offset: UInt64(index) * UInt64(data.count), compressedSize: UInt32(data.count),
                uncompressedSize: UInt32(data.count), checksum: checksum)
        }
        let size = UInt64(chunks.count) * UInt64(data.count)
        let manifest = DepotManifest(depotID: 7, gid: 9, files: [.init(path: "Game/large.bdt", size: size, chunks: chunks)], totalSize: size)
        let feed = LargeFileFeed(root: root, data: data)
        do { try await download(root).download(manifest: manifest, fetchChunk: feed.fetch); XCTFail() }
        catch is CancellationError {}
        XCTAssertEqual(try partial(root).resourceValues(forKeys: [.fileSizeKey]).fileSize, data.count)
        let observations = await feed.partialSizes
        XCTAssertEqual(observations, [0, data.count], "Do not allocate the game's entire archive before fetching chunks")
        let resumed = LargeFileFeed(root: root, data: data)
        do { try await download(root).download(manifest: manifest, fetchChunk: resumed.fetch); XCTFail() }
        catch is CancellationError {}
        let offsets = await resumed.offsets
        XCTAssertEqual(offsets, [UInt64(data.count)], "A partial shorter than the final file must retain verified checkpoints")
    }
    func testOutOfOrderManifestFetchesFromStartWithoutChangingJournalIndices() async throws {
        let root = try root(), source = fixture(), file = source.files[0]
        let manifest = DepotManifest(depotID: source.depotID, gid: source.gid,
            files: [.init(path: file.path, size: file.size, chunks: file.chunks.reversed(), contentSHA1: file.contentSHA1)], totalSize: source.totalSize)
        let feed = Feed(pieces, failAt: 5)
        do { try await download(root).download(manifest: manifest, fetchChunk: feed.fetch) } catch {}
        let first = await feed.requested; XCTAssertEqual(first, [0, 5])
        let resumed = Feed(pieces)
        try await download(root).download(manifest: manifest, fetchChunk: resumed.fetch)
        let next = await resumed.requested; XCTAssertEqual(next, [5, 11])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(file.path)), pieces.reduce(Data(), +))
    }
    func testTransferProgressExcludesRetainedChunksAndCompleteFiles() async throws {
        let root = try root(), manifest = fixture(), first = Feed(pieces, failAt: 5)
        do { try await download(root).download(manifest: manifest, fetchChunk: first.fetch) } catch {}
        let samples = ProgressSamples()
        var resumed = download(root); resumed.onProgress = samples.append
        try await resumed.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(samples.values.first(where: { $0.verification == nil })?.bytesDone, 5)
        XCTAssertEqual(samples.values.first?.bytesWritten, 0)
        XCTAssertEqual(samples.values.last?.bytesDone, 16)
        XCTAssertEqual(samples.values.last?.bytesWritten, 11)
        let cached = ProgressSamples()
        resumed.onProgress = cached.append
        try await resumed.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(cached.values.last?.bytesDone, 16)
        XCTAssertEqual(cached.values.last?.bytesWritten, 0)
    }
    func testFileVerificationReportsReadProgressWithoutAddingWrittenBytes() async throws {
        let root = try root(), manifest = fixture(), samples = ProgressSamples()
        var value = download(root); value.onProgress = samples.append
        try await value.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        let checks = samples.values.filter { $0.verification != nil }
        XCTAssertEqual(checks.first?.verification?.bytesChecked, 0)
        XCTAssertEqual(checks.last?.verification?.bytesChecked, manifest.totalSize)
        XCTAssertTrue(checks.allSatisfy { $0.verification?.bytesTotal == manifest.totalSize && $0.file == "Game/data.bin" })
        XCTAssertTrue(checks.allSatisfy { $0.bytesDone == manifest.totalSize && $0.bytesWritten == manifest.totalSize })
        XCTAssertNil(samples.values.last?.verification, "Resume normal progress after checking the file")
        // A complete file reused on a later invocation also reports the disk read, without a transfer.
        let reused = ProgressSamples(); value.onProgress = reused.append
        try await value.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        XCTAssertEqual(reused.values.first?.verification?.bytesChecked, 0)
        XCTAssertEqual(reused.values.filter { $0.verification != nil }.last?.verification?.bytesChecked, manifest.totalSize)
        XCTAssertTrue(reused.values.allSatisfy { $0.bytesWritten == 0 })
        XCTAssertNil(reused.values.last?.verification)
    }
    func testResumeReportsSavedChunkChecksIncludingCorruptionBeforeFetching() async throws {
        let root = try root(), manifest = fixture(), initial = Feed(pieces, failAt: 11)
        do { try await download(root).download(manifest: manifest, fetchChunk: initial.fetch) } catch {}
        let handle = try FileHandle(forWritingTo: partial(root))
        try handle.write(contentsOf: Data("WRONG".utf8)); try handle.close()
        let samples = ProgressSamples()
        var resumed = download(root); resumed.onProgress = samples.append
        try await resumed.download(manifest: manifest, fetchChunk: Feed(pieces).fetch)
        let checks = Array(samples.values.prefix { $0.verification != nil })
        XCTAssertEqual(checks.first?.verification?.bytesChecked, 0)
        XCTAssertEqual(checks.last?.verification?.bytesChecked, 11)
        XCTAssertTrue(checks.allSatisfy { $0.verification?.bytesTotal == 11 && $0.file == "Game/data.bin" })
        XCTAssertTrue(checks.allSatisfy { $0.bytesWritten == 0 })
        XCTAssertEqual(checks.last?.bytesDone, 6, "Corrupt saved chunks must not count as retained bytes")
        XCTAssertEqual(samples.values.first(where: { $0.verification == nil })?.bytesDone, 6)
        XCTAssertEqual(samples.values.last?.bytesWritten, 10)
        XCTAssertNil(samples.values.last?.verification)
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

private actor LargeFileFeed {
    let root: URL
    let data: Data
    var offsets: [UInt64] = []
    var partialSizes: [Int] = []
    init(root: URL, data: Data) { self.root = root; self.data = data }
    nonisolated var fetch: @Sendable (DepotManifest.Chunk) async throws -> Data {
        { chunk in try await self.read(chunk) }
    }
    func read(_ chunk: DepotManifest.Chunk) throws -> Data {
        offsets.append(chunk.offset)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])!
        let partial = try XCTUnwrap(files.allObjects.compactMap { $0 as? URL }.first { $0.pathExtension == "partial" })
        partialSizes.append(try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
        guard chunk.offset == 0 else { throw CancellationError() }
        return data
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
