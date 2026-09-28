import XCTest
@testable import EpicCore

/// A build made of synthetic chunks, served from memory like a CDN.
struct FixtureBuild {
    var manifest: EpicManifest
    var chunkFiles: [String: Data]
    var contents: [String: Data]

    /// Files are cut from a shared byte stream so chunks are shared across files and parts.
    static func make(files: [(String, Int)], chunkSize: Int = 64, executable: Set<String> = [], links: [String: String] = [:]) throws -> FixtureBuild {
        var stream = Data()
        for (index, file) in files.enumerated() { stream.append(Data((0..<file.1).map { UInt8(truncatingIfNeeded: $0 * 7 + index * 31) })) }
        var chunks: [EpicManifest.Chunk] = []
        var chunkFiles: [String: Data] = [:]
        var chunkData: [Data] = []
        for (index, start) in stride(from: 0, to: max(stream.count, 1), by: chunkSize).enumerated() {
            let data = stream.subdata(in: start..<min(start + chunkSize, stream.count))
            let guid = EpicGUID(a: UInt32(index + 1), b: 0xB, c: 0xC, d: 0xD)
            let info = EpicManifest.Chunk(guid: guid, rollingHash: UInt64(index), sha1: EpicCodec.sha1(data), groupNumber: UInt8(index % 100),
                                          windowSize: UInt32(data.count), fileSize: 0)
            let raw = try EpicChunk.encode(guid: guid, data: data, rollingHash: UInt64(index))
            var sized = info; sized.fileSize = Int64(raw.count)
            chunks.append(sized); chunkData.append(data)
            chunkFiles[EpicManifest.chunkPath(sized, featureLevel: 18)] = raw
        }
        var manifestFiles: [EpicManifest.File] = []
        var contents: [String: Data] = [:]
        var offset = 0
        for (name, size) in files {
            let data = stream.subdata(in: offset..<offset + size)
            var file = EpicManifest.File(filename: name, sha1: EpicCodec.sha1(data), flags: executable.contains(name) ? 0x4 : 0)
            var position = offset, fileOffset: UInt64 = 0
            while position < offset + size {
                let index = position / chunkSize, within = position % chunkSize
                let length = min(chunkSize - within, offset + size - position)
                file.chunkParts.append(.init(guid: chunks[index].guid, offset: UInt32(within), size: UInt32(length), fileOffset: fileOffset))
                position += length; fileOffset += UInt64(length)
            }
            manifestFiles.append(file); contents[name] = data; offset += size
        }
        for (name, target) in links { manifestFiles.append(.init(filename: name, symlinkTarget: target, sha1: Data(count: 20))) }
        var meta = EpicManifest.Meta(); meta.featureLevel = 18; meta.appName = "Fixture"; meta.buildVersion = "1"
        return FixtureBuild(manifest: EpicManifest(version: 18, meta: meta, chunks: chunks, files: manifestFiles, customFields: [:]),
                            chunkFiles: chunkFiles, contents: contents)
    }
}

final class DownloaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("epic-dl-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func serve(_ build: FixtureBuild, fetched: LockedList<String>? = nil,
                       fail: (@Sendable (String) -> Error?)? = nil) -> @Sendable (String) async throws -> Data {
        let files = build.chunkFiles
        return { path in
            fetched?.append(path)
            if let error = fail?(path) { throw error }
            guard let data = files[path] else { throw EpicError.http(status: 404, code: nil, message: path) }
            return data
        }
    }

    func testWritesEveryFileFromSharedChunksAndFetchesEachChunkOnce() throws {
        let build = try FixtureBuild.make(files: [("Binaries/Win64/Game.exe", 200), ("Content/a.pak", 90), ("empty.txt", 0), ("Content/b.pak", 333)],
                                          executable: ["Binaries/Win64/Game.exe"], links: ["Content/latest.pak": "b.pak"])
        let fetched = LockedList<String>()
        let progress = LockedList<EpicDownloadProgress>()
        var downloader = EpicDownloader(destination: root)
        downloader.concurrency = 3
        downloader.retainedChunkMemory = 64 // forces shared chunks to disk
        downloader.onProgress = { progress.append($0) }
        try runBlocking { [downloader] in try await downloader.download(build.manifest, fetch: self.serve(build, fetched: fetched)) }

        for (name, data) in build.contents { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), data, name) }
        XCTAssertEqual(Set(fetched.values).count, build.manifest.chunks.count)
        XCTAssertEqual(fetched.values.count, build.manifest.chunks.count)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("Content/latest.pak").path), "b.pak")
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Binaries/Win64/Game.exe").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode.map { $0 & 0o100 }, 0o100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".epic-download").path))
        let last = try XCTUnwrap(progress.values.last)
        XCTAssertEqual(last.bytesDone, 623); XCTAssertEqual(last.bytesTotal, 623); XCTAssertEqual(last.bytesWritten, 623)
        XCTAssertEqual(last.bytesDownloaded, UInt64(build.chunkFiles.values.reduce(0) { $0 + $1.count }))
        XCTAssertTrue(try downloader.invalidFiles(in: build.manifest).isEmpty)
    }

    func testResumesAfterFailureWithoutRewritingFinishedFiles() throws {
        let build = try FixtureBuild.make(files: [("a.bin", 128), ("b.bin", 128), ("c.bin", 128)])
        let failing = build.manifest.path(for: build.manifest.chunks[4]) // first chunk of c.bin
        var downloader = EpicDownloader(destination: root)
        downloader.concurrency = 1
        XCTAssertThrowsError(try runBlocking { [downloader] in
            try await downloader.download(build.manifest, fetch: self.serve(build, fail: { $0 == failing ? EpicError.network("down") : nil }))
        })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("a.bin")), build.contents["a.bin"])

        let fetched = LockedList<String>()
        let progress = LockedList<EpicDownloadProgress>()
        downloader.onProgress = { progress.append($0) }
        try runBlocking { [downloader] in try await downloader.download(build.manifest, fetch: self.serve(build, fetched: fetched)) }
        // a.bin was journaled before the failing fetch could start, so its chunks are not fetched again.
        let paths = build.manifest.chunks.map(build.manifest.path(for:))
        XCTAssertFalse(fetched.values.contains(paths[0]) || fetched.values.contains(paths[1]))
        XCTAssertTrue(fetched.values.contains(paths[4]) && fetched.values.contains(paths[5]))
        XCTAssertGreaterThanOrEqual(progress.values.first?.bytesDone ?? 0, 128)
        for (name, data) in build.contents { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), data) }
    }

    func testCancellationStopsTheDownload() throws {
        let build = try FixtureBuild.make(files: [("a.bin", 640)])
        let downloader = EpicDownloader(destination: root)
        let started = expectation(description: "fetch started")
        started.assertForOverFulfill = false
        let task = Task {
            try await downloader.download(build.manifest) { _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return Data()
            }
        }
        wait(for: [started], timeout: 5)
        task.cancel()
        let done = expectation(description: "finished")
        Task { let result = await task.result; if case .success = result { XCTFail("must not succeed") }; done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testRejectsChunkThatFailsItsHash() throws {
        var build = try FixtureBuild.make(files: [("a.bin", 100)])
        let path = build.manifest.path(for: build.manifest.chunks[0])
        build.chunkFiles[path] = try EpicChunk.encode(guid: build.manifest.chunks[0].guid, data: Data(repeating: 9, count: 64))
        XCTAssertThrowsError(try runBlocking { [build] in try await EpicDownloader(destination: self.root).download(build.manifest, fetch: self.serve(build)) }) {
            guard case .hashMismatch = $0 as? EpicError else { return XCTFail("\($0)") }
        }
    }

    func testVerifyFindsMissingAndChangedFilesAndRepairRewritesOnlyThose() throws {
        let build = try FixtureBuild.make(files: [("a.bin", 100), ("b.bin", 100), ("c.bin", 100)])
        let downloader = EpicDownloader(destination: root)
        try runBlocking { [downloader] in try await downloader.download(build.manifest, fetch: self.serve(build)) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.bin"))
        try Data(repeating: 0, count: 100).write(to: root.appendingPathComponent("c.bin"))
        let invalid = try downloader.invalidFiles(in: build.manifest)
        XCTAssertEqual(invalid, ["a.bin", "c.bin"])

        let before = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.bin").path)[.modificationDate] as? Date
        let fetched = LockedList<String>()
        try runBlocking { [downloader] in try await downloader.download(build.manifest, only: Set(invalid), fetch: self.serve(build, fetched: fetched)) }
        XCTAssertTrue(try downloader.invalidFiles(in: build.manifest).isEmpty)
        let after = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.bin").path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
        XCTAssertFalse(fetched.values.contains(build.manifest.path(for: build.manifest.chunks[2]))) // only b.bin's middle chunk
    }

    func testDirectoriesDifferingOnlyInCaseShareOneSpellingAndUnsafePathsAreRefused() throws {
        let build = try FixtureBuild.make(files: [("Game/Content/a.pak", 10), ("game/content/b.pak", 10), ("GAME/Binaries/x.exe", 10)])
        let layout = try EpicInstallLayout(manifest: build.manifest)
        XCTAssertEqual(layout.entries.map(\.path), ["GAME/Binaries/x.exe", "GAME/Content/a.pak", "GAME/Content/b.pak"])

        let unsafe = try FixtureBuild.make(files: [("../escape.txt", 10)])
        XCTAssertThrowsError(try EpicInstallLayout(manifest: unsafe.manifest))
        let link = try FixtureBuild.make(files: [("a.bin", 10)], links: ["out": "../../etc/passwd"])
        XCTAssertThrowsError(try runBlocking { try await EpicDownloader(destination: self.root).download(link.manifest, fetch: self.serve(link)) })
    }

    func testChunkFetcherRotatesCDNsAndRetries() async throws {
        let attempts = LockedList<String>()
        let transport = StubTransport { request in
            attempts.append(request.url!.host!)
            return request.url!.host == "b.example" && attempts.values.count > 2 ? (200, Data("chunk".utf8)) : (503, Data())
        }
        let fetcher = EpicChunkFetcher(baseURLs: [URL(string: "https://a.example/Builds/x")!, URL(string: "https://b.example/Builds/x")!],
                                       transport: transport, pause: { _ in })
        let data = try await fetcher.fetch("ChunksV4/01/AB_CD.chunk")
        XCTAssertEqual(data, Data("chunk".utf8))
        XCTAssertEqual(attempts.values, ["a.example", "b.example", "a.example", "b.example"])
        XCTAssertEqual(transport.requests.last?.url?.absoluteString, "https://b.example/Builds/x/ChunksV4/01/AB_CD.chunk")
    }
}

final class LockedList<T>: @unchecked Sendable {
    private let lock = NSLock(); private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var values: [T] { lock.withLock { items } }
}

/// Runs async work from a synchronous test so `XCTAssertThrowsError` can wrap it.
func runBlocking(_ work: @escaping @Sendable () async throws -> Void) throws {
    let semaphore = DispatchSemaphore(value: 0)
    let box = LockedList<Error>()
    Task { do { try await work() } catch { box.append(error) }; semaphore.signal() }
    semaphore.wait()
    if let error = box.values.first { throw error }
}
