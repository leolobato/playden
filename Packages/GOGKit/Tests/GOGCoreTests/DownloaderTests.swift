import XCTest
import CryptoKit
import zlib
@testable import GOGCore

func deflate(_ data: Data) -> Data {
    var length = uLongf(compressBound(uLong(data.count)))
    var out = Data(count: Int(length))
    _ = out.withUnsafeMutableBytes { o in data.withUnsafeBytes { i in
        compress(o.bindMemory(to: Bytef.self).baseAddress, &length, i.bindMemory(to: Bytef.self).baseAddress, uLong(data.count))
    } }
    out.count = Int(length)
    return out
}
func md5(_ data: Data) -> String { GOGCodec.md5(data) }

/// Serves synthetic chunks and a synthetic `main.bin`, counting requests.
final class StubCDN: GOGContentFetching, @unchecked Sendable {
    private let lock = NSLock()
    var chunks: [String: Data] = [:]
    var blobs: [String: Data] = [:]
    var failAfter: Int?
    private(set) var served = 0

    func add(_ content: Data) -> GOGChunk {
        let compressed = deflate(content)
        let chunk = GOGChunk(md5: md5(content), compressedMd5: md5(compressed), size: Int64(content.count), compressedSize: Int64(compressed.count))
        chunks[chunk.compressedMd5] = compressed
        return chunk
    }

    private func count() throws {
        try lock.withLock {
            if let failAfter, served >= failAfter { throw GOGError.network("stub offline") }
            served += 1
        }
    }

    func chunk(_ chunk: GOGChunk, product: String) async throws -> Data {
        try count()
        return try XCTUnwrap(chunks[chunk.compressedMd5])
    }

    func range(product: String, offset: Int64, length: Int64) async throws -> Data {
        try count()
        let blob = try XCTUnwrap(blobs[product])
        return blob.subdata(in: Int(offset)..<Int(offset + length))
    }
}

final class DownloaderTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gog-dl-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func manifest(_ files: [GOGFile], generation: Int = 2) -> GOGInstallManifest {
        GOGInstallManifest(generation: generation, productID: "1", buildID: "b1", platform: "windows", versionName: nil,
                           installDirectory: "Game", language: "en-US", products: ["1"], dependencies: [], files: files)
    }

    func gen2Build(_ cdn: StubCDN) -> GOGInstallManifest {
        let a = Data(repeating: 1, count: 1000), b = Data(repeating: 2, count: 500), c = Data("config".utf8)
        let big = GOGFile(path: "Data/Big.pak", size: 1500, md5: md5(a + b), product: "1", chunks: [cdn.add(a), cdn.add(b)])
        let exe = GOGFile(path: "Game.exe", size: Int64(c.count), sha256: SHA256.hash(data: c).map { String(format: "%02x", $0) }.joined(),
                          executable: true, product: "1", chunks: [cdn.add(c)])
        let empty = GOGFile(path: "data/empty.txt", size: 0, md5: md5(Data()), product: "1", chunks: [])
        let noHash = GOGFile(path: "DATA/parts.bin", size: 1500, product: "1", chunks: [cdn.add(a), cdn.add(b)])
        return manifest([
            GOGFile(path: "Saves", kind: .directory, product: "1"), big, exe, empty, noHash,
            GOGFile(path: "Link.pak", kind: .link, target: "Data/Big.pak", product: "1"),
        ])
    }

    func testGen2DownloadWritesFilesModesLinksAndVerifies() async throws {
        let cdn = StubCDN(), build = gen2Build(cdn)
        let downloader = GOGDownloader(destination: root)
        try await downloader.download(build, fetcher: cdn)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Data/Big.pak")).count, 1500)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Data/empty.txt").path), "folders share the first spelling")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Data/parts.bin").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("Link.pak").path), "Data/Big.pak")
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Game.exe").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Saves").path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(GOGDownloader.workDirectory).path))
        XCTAssertEqual(try downloader.invalidFiles(in: build), [])
    }

    func testVerifyFindsDamageAndRepairFixesOnlyThose() async throws {
        let cdn = StubCDN(), build = gen2Build(cdn)
        let downloader = GOGDownloader(destination: root)
        try await downloader.download(build, fetcher: cdn)
        var damaged = try Data(contentsOf: root.appendingPathComponent("Data/parts.bin"))
        damaged[700] ^= 0xff
        try damaged.write(to: root.appendingPathComponent("Data/parts.bin"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Game.exe"))
        XCTAssertEqual(Set(try downloader.invalidFiles(in: build)), ["DATA/parts.bin", "Game.exe"], "a file without a whole-file hash is checked by chunks")
        let before = cdn.served
        try await downloader.download(build, only: ["DATA/parts.bin", "Game.exe"], fetcher: cdn)
        XCTAssertEqual(cdn.served - before, 3)
        XCTAssertEqual(try downloader.invalidFiles(in: build), [])
    }

    func testResumeSkipsFinishedFiles() async throws {
        let cdn = StubCDN(), build = gen2Build(cdn)
        var downloader = GOGDownloader(destination: root)
        downloader.concurrency = 1
        cdn.failAfter = 3
        do { try await downloader.download(build, fetcher: cdn); XCTFail("expected the stub to fail") } catch {}
        cdn.failAfter = nil
        let before = cdn.served
        try await downloader.download(build, fetcher: cdn)
        XCTAssertLessThan(cdn.served - before, 5, "Big.pak finished before the failure and is not fetched again")
        XCTAssertEqual(try downloader.invalidFiles(in: build), [])
    }

    func testBadHashesFail() async throws {
        let cdn = StubCDN()
        let content = Data(repeating: 9, count: 64)
        var chunk = cdn.add(content)
        chunk.md5 = String(repeating: "0", count: 32)
        do {
            try await GOGDownloader(destination: root).download(manifest([GOGFile(path: "a", size: 64, product: "1", chunks: [chunk])]), fetcher: cdn)
            XCTFail("expected a hash failure")
        } catch GOGError.hashMismatch {}
        var corrupt = cdn.add(Data(repeating: 8, count: 64))
        cdn.chunks[corrupt.compressedMd5]?[3] ^= 0xff
        do {
            try await GOGDownloader(destination: root).download(manifest([GOGFile(path: "b", size: 64, product: "1", chunks: [corrupt])]), fetcher: cdn)
            XCTFail("expected a hash failure")
        } catch GOGError.hashMismatch {}
        corrupt = cdn.add(Data(repeating: 7, count: 64))
        do {
            try await GOGDownloader(destination: root).download(manifest([GOGFile(path: "c", size: 64, md5: "bad", product: "1", chunks: [corrupt])]), fetcher: cdn)
            XCTFail("expected a hash failure")
        } catch GOGError.hashMismatch {}
    }

    func testGen1RangesLinksAndExecutables() async throws {
        let cdn = StubCDN()
        let first = Data((0..<25).map { UInt8($0) }), second = Data("#!/bin/sh\n".utf8)
        cdn.blobs["1"] = Data(repeating: 0xee, count: 7) + first + second
        let build = manifest([
            GOGFile(path: "Contents/Resources", kind: .directory, product: "1"),
            GOGFile(path: "Contents/Resources/data.bin", size: 25, md5: md5(first), product: "1", offset: 7),
            GOGFile(path: "Contents/MacOS/GOGLauncher", size: Int64(second.count), md5: md5(second), executable: true, product: "1", offset: 32),
            GOGFile(path: "Contents/Current", kind: .link, target: "Resources", product: "1"),
        ], generation: 1)
        var downloader = GOGDownloader(destination: root)
        downloader.rangeSize = 10
        try await downloader.download(build, fetcher: cdn)
        XCTAssertEqual(cdn.served, 4, "25 bytes in ranges of 10, plus one range")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Contents/Resources/data.bin")), first)
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Contents/MacOS/GOGLauncher").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
        XCTAssertEqual(try downloader.invalidFiles(in: build), [])
    }

    func testLinksMayNotLeaveTheInstall() async throws {
        let build = manifest([GOGFile(path: "evil", kind: .link, target: "../../etc/passwd", product: "1")])
        do { try await GOGDownloader(destination: root).download(build, fetcher: StubCDN()); XCTFail() }
        catch GOGError.malformed {}
    }

    func testContentsOfOneFile() async throws {
        let cdn = StubCDN(), text = Data(#"{"playTasks":[]}"#.utf8)
        let file = GOGFile(path: "goggame-1.info", size: Int64(text.count), md5: md5(text), product: "1", chunks: [cdn.add(text)])
        let data = try await GOGDownloader.contents(of: file, fetcher: cdn)
        XCTAssertEqual(data, text)
    }

    func testResolverBuildsAGen2ManifestWithDLCAndDependencies() async throws {
        let meta = try fixture("meta-v2.json"), depot = try fixture("depot-v2.json")
        let dependencies = try fixture("dependencies.json"), dosbox = try fixture("dependency-depot.json")
        var metaJSON = try JSONSerialization.jsonObject(with: meta) as! [String: Any]
        metaJSON["dependencies"] = ["DOSBox074_2CS", "DirectX"]
        let patchedMeta = try JSONSerialization.data(withJSONObject: metaJSON)
        let transport = StubTransport { request in
            let url = request.url!.absoluteString
            if url.contains("/builds") {
                return (200, json(#"{"items":[{"build_id":"9","product_id":"1441974651","os":"windows","branch":null,"generation":2,"urls":[{"endpoint_name":"fastly","url":"https://cdn.test/content-system/v2/meta/aa/bb/aabb","url_format":"","parameters":{},"priority":10}]}]}"#), [:])
            }
            if url.hasSuffix("/aa/bb/aabb") { return (200, deflate(patchedMeta), [:]) }
            if url.contains("/dependencies/repository") { return (200, json(#"{"repository_manifest":"https://cdn.test/deps"}"#), [:]) }
            if url == "https://cdn.test/deps" { return (200, deflate(dependencies), [:]) }
            if url.contains("/dependencies/meta/") { return (200, deflate(dosbox), [:]) }
            if url.contains("/content-system/v2/meta/") { return (200, deflate(depot), [:]) }
            XCTFail("unexpected \(url)"); return (404, Data(), [:])
        }
        let resolution = try await GOGResolver(api: GOGAPI(transport: transport, pause: { _ in })).resolve(
            productID: "1441974651", os: "windows", language: "english", owned: ["1441974651", "1619024184"], accessToken: "A")
        let manifest = resolution.manifest
        XCTAssertEqual(manifest.generation, 2)
        XCTAssertEqual(manifest.products, ["1441974651", "1619024184"])
        XCTAssertEqual(manifest.dependencies, ["DOSBox074_2CS", "DirectX"])
        XCTAssertEqual(manifest.installDirectory, "Prison Architect")
        XCTAssertTrue(manifest.files.contains { $0.path == "DOSBOX/DOSBox.exe" && $0.product == GOGFile.dependencyStore },
                      "DOSBox goes into the game folder; DirectX, an installer, does not")
        XCTAssertFalse(manifest.files.contains { $0.path.lowercased().contains("__redist") })
    }
}
