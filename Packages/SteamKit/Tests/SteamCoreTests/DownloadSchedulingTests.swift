import XCTest
@testable import SteamCore

final class DownloadSchedulingTests: XCTestCase {
    private func fixture(_ count: Int = 40) -> (DepotManifest, [Data: Data]) {
        var data: [Data: Data] = [:]
        let files = (0..<count).map { index -> DepotManifest.File in
            let bytes = Data("file-\(index)".utf8), sha = SteamCrypto.sha1(bytes)
            data[sha] = bytes
            let chunk = DepotManifest.Chunk(sha: sha, offset: 0, compressedSize: UInt32(bytes.count),
                uncompressedSize: UInt32(bytes.count), checksum: DepotManifest.Chunk.adler(bytes))
            return .init(path: "shared/nested/\(index)", size: UInt64(bytes.count), chunks: [chunk], contentSHA1: sha)
        }
        return (.init(depotID: 7, gid: 9, files: files, totalSize: files.reduce(0) { $0 + $1.size }), data)
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testOverlapsFilesWithGlobalEightChunkAndWriterBound() async throws {
        let root = try root(), (manifest, data) = fixture()
        let feed = SchedulingFeed(data: data, root: root), samples = SchedulingSamples()
        var download = ResumableDepotDownload(destination: root)
        download.chunkConcurrency = 64
        download.onProgress = { samples.append($0) }
        try await download.download(manifest: manifest, fetchChunk: { try await feed.fetch($0) })
        let peak = await feed.peak, writers = await feed.writers
        XCTAssertEqual(peak, 8, "Small files share the same eight chunk slots")
        XCTAssertLessThanOrEqual(writers, 8, "A slow first file cannot retain unlimited writers")
        XCTAssertTrue(try download.invalidFiles(in: manifest).isEmpty)
        let progress = samples.values
        XCTAssertEqual(progress.last?.bytesDone, manifest.totalSize)
        XCTAssertEqual(progress.last?.bytesWritten, manifest.totalSize)
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { $0.bytesDone <= $1.bytesDone })
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { $0.bytesWritten! <= $1.bytesWritten! })
    }
    func testLargeFileAndSmallFilesShareEightSlots() async throws {
        let root = try root(), (small, data) = fixture(12)
        let bytes = data[small.files[0].chunks[0].sha]!
        let chunks = (0..<24).map { index in
            DepotManifest.Chunk(sha: SteamCrypto.sha1(bytes), offset: UInt64(index * bytes.count),
                compressedSize: UInt32(bytes.count), uncompressedSize: UInt32(bytes.count), checksum: DepotManifest.Chunk.adler(bytes))
        }
        let large = DepotManifest.File(path: "large", size: UInt64(24 * bytes.count), chunks: chunks)
        let manifest = DepotManifest(depotID: 7, gid: 9, files: [large] + small.files, totalSize: large.size + small.totalSize)
        let feed = SchedulingFeed(data: data, root: root)
        var download = ResumableDepotDownload(destination: root); download.chunkConcurrency = 64
        try await download.download(manifest: manifest) { try await feed.fetch($0) }
        let peak = await feed.peak
        XCTAssertEqual(peak, 8, "A larger configured value cannot increase the global network budget")
        XCTAssertTrue(try download.invalidFiles(in: manifest).isEmpty)
    }
    func testFailureAndCancellationCheckpointEveryOpenFileBeforeResume() async throws {
        for cancel in [false, true] {
            let root = try root()
            var payloads: [Data: Data] = [:]
            func file(_ index: Int, chunks count: Int) -> DepotManifest.File {
                let chunks = (0..<count).map { offset -> DepotManifest.Chunk in
                    let data = Data([UInt8(index * 2 + offset)]), sha = SteamCrypto.sha1(data)
                    payloads[sha] = data
                    return .init(sha: sha, offset: UInt64(offset), compressedSize: 1,
                        uncompressedSize: 1, checksum: DepotManifest.Chunk.adler(data))
                }
                return .init(path: "shared/\(index)", size: UInt64(count), chunks: chunks)
            }
            let files = [file(0, chunks: 1)] + (1...4).map { file($0, chunks: 2) }
            let link = DepotManifest.File(path: "link", size: 0, linkTarget: "shared/4", chunks: [])
            let manifest = DepotManifest(depotID: 7, gid: 9, files: [link] + files, totalSize: 9)
            let data = payloads
            let feed = InterruptedSchedulingFeed(data: data), samples = SchedulingSamples()
            var download = ResumableDepotDownload(destination: root)
            download.onProgress = { samples.append($0) }
            let task = Task { try await download.download(manifest: manifest) { try await feed.fetch($0) } }
            for _ in 0..<1000 {
                if samples.values.last?.bytesWritten == 5 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertEqual(samples.values.last?.bytesWritten, 5)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("link").path))
            do {
                try await ResumableDepotDownload(destination: root).download(manifest: manifest) { data[$0.sha]! }
                XCTFail("Concurrent destination operation must fail its lease")
            } catch let error as SteamError { XCTAssertTrue(String(describing: error).contains("another download")) }
            if cancel { task.cancel() } else { await feed.fail() }
            do { try await task.value; XCTFail("Expected interruption") }
            catch is CancellationError { XCTAssertTrue(cancel) }
            catch let error as SchedulingFailure { XCTAssertEqual(error, .network) }
            let active = await feed.active
            XCTAssertEqual(active, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".gn-download/receipts/7-9.json").path))
            let resumed = SchedulingSamples(), diagnostics = SteamPerformanceDiagnostics()
            var retry = ResumableDepotDownload(destination: root, diagnostics: diagnostics)
            retry.onProgress = { resumed.append($0) }
            try await retry.download(manifest: manifest) { data[$0.sha]! }
            XCTAssertEqual(resumed.values.last?.bytesDone, 9)
            XCTAssertEqual(resumed.values.last?.bytesWritten, 4, "Restored bytes never count as fresh incoming bytes")
            XCTAssertEqual(diagnostics.snapshot()[.contentRead].bytes, 4, "Every retained range revalidates; receipt skips completed file")
            XCTAssertTrue(zip(resumed.values, resumed.values.dropFirst()).allSatisfy { $0.bytesDone <= $1.bytesDone })
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("link").path), "shared/4")
            XCTAssertTrue(try retry.invalidFiles(in: manifest).isEmpty)
        }
    }
    func testCancellationDrainsAllFilesAndReleasesDestinationLease() async throws {
        let root = try root(), (manifest, data) = fixture()
        let feed = SchedulingFeed(data: data, root: root, slow: true)
        let download = ResumableDepotDownload(destination: root)
        let task = Task { try await download.download(manifest: manifest, fetchChunk: { try await feed.fetch($0) }) }
        for _ in 0..<1000 {
            if await feed.peak == 8 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let peak = await feed.peak
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let active = await feed.active
        XCTAssertEqual(peak, 8)
        XCTAssertEqual(active, 0, "Cancellation returns after every worker drains")
        try await download.download(manifest: manifest) { data[$0.sha]! }
        XCTAssertTrue(try download.invalidFiles(in: manifest).isEmpty)
    }
}
private actor SchedulingFeed {
    let data: [Data: Data], root: URL, slow: Bool
    var active = 0, peak = 0, writers = 0
    init(data: [Data: Data], root: URL, slow: Bool = false) { self.data = data; self.root = root; self.slow = slow }
    func fetch(_ chunk: DepotManifest.Chunk) async throws -> Data {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        writers = max(writers, files.filter { $0.pathExtension == "partial" }.count)
        try await Task.sleep(for: slow ? .seconds(10) : .milliseconds(data[chunk.sha] == Data("file-0".utf8) ? 150 : 15))
        return data[chunk.sha]!
    }
}
private final class SchedulingSamples: @unchecked Sendable {
    let lock = NSLock()
    private var storage: [DownloadProgress] = []
    func append(_ value: DownloadProgress) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [DownloadProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}

private enum SchedulingFailure: Error { case network }
private actor InterruptedSchedulingFeed {
    let data: [Data: Data]
    var active = 0
    var shouldFail = false
    init(data: [Data: Data]) { self.data = data }
    func fail() { shouldFail = true }
    func fetch(_ chunk: DepotManifest.Chunk) async throws -> Data {
        active += 1
        defer { active -= 1 }
        if chunk.offset > 0 {
            while !shouldFail { try await Task.sleep(for: .milliseconds(1)) }
            throw SchedulingFailure.network
        }
        return data[chunk.sha]!
    }
}
