import XCTest
import CryptoKit
@testable import EpicCore

/// Writes binary manifests in the launcher's layout, so tests can cover variants no public build uses.
struct ManifestWriter {
    var featureLevel: UInt32 = 18
    var meta = EpicManifest.Meta()
    var chunks: [EpicManifest.Chunk] = []
    var files: [EpicManifest.File] = []
    var customFields: [(String, String)] = []
    var compress = true
    /// Feature level 24+: encrypts launch data and file names under this key.
    var encryption: (guid: EpicGUID, key: SymmetricKey)?

    private struct Out {
        var data = Data()
        mutating func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func string(_ s: String) {
            if s.isEmpty { put(Int32(0)); return }
            if s.allSatisfy(\.isASCII) { put(Int32(s.utf8.count + 1)); data.append(Data(s.utf8)); data.append(0); return }
            let units = Array(s.utf16)
            put(Int32(-(units.count + 1))); units.forEach { put($0) }; put(UInt16(0))
        }
        mutating func section(version: UInt8, _ body: (inout Out) -> Void) {
            var inner = Out(); inner.put(version); body(&inner)
            put(UInt32(inner.data.count + 4)); data.append(inner.data)
        }
    }

    func write() throws -> Data {
        let encrypted = encryption != nil
        var body = Out()
        body.section(version: 2) { o in
            o.put(featureLevel); o.put(UInt8(0)); o.put(meta.appID)
            o.string(meta.appName); o.string(meta.buildVersion)
            o.string(encrypted ? "" : meta.launchExe); o.string(encrypted ? "" : meta.launchCommand)
            o.put(UInt32(0)); o.string(""); o.string(""); o.string("")
            o.string(meta.storedBuildID); o.string(""); o.string("")
        }
        body.section(version: 0) { o in
            o.put(UInt32(chunks.count))
            chunks.forEach { o.data.append($0.guid.littleEndianBytes) }
            chunks.forEach { o.put($0.rollingHash) }
            chunks.forEach { o.data.append($0.sha1) }
            chunks.forEach { o.put($0.groupNumber) }
            chunks.forEach { o.put($0.windowSize) }
            chunks.forEach { o.put($0.fileSize) }
            if featureLevel >= 22 {
                chunks.forEach { o.data.append(($0.secretGUID ?? EpicGUID(a: 0, b: 0, c: 0, d: 0)).littleEndianBytes) }
                chunks.forEach { o.put($0.windowSizeCompressed) }
                chunks.forEach { o.data.append($0.encryptionTag.isEmpty ? Data(count: 16) : $0.encryptionTag) }
            }
        }
        body.section(version: 0) { o in
            o.put(UInt32(files.count))
            files.forEach { o.string(encrypted ? "" : $0.filename) }
            files.forEach { o.string(encrypted ? "" : $0.symlinkTarget) }
            files.forEach { o.data.append($0.sha1) }
            files.forEach { o.put($0.flags) }
            files.forEach { f in o.put(UInt32(f.installTags.count)); f.installTags.forEach { o.string($0) } }
            files.forEach { f in
                o.put(UInt32(f.chunkParts.count))
                for p in f.chunkParts { o.put(UInt32(28)); o.data.append(p.guid.littleEndianBytes); o.put(p.offset); o.put(p.size) }
            }
        }
        body.section(version: 0) { o in
            o.put(UInt32(customFields.count))
            customFields.forEach { o.string($0.0) }
            customFields.forEach { o.string($0.1) }
        }
        var tag = Data(count: 16)
        if let encryption {
            var plain = Out()
            plain.string(meta.launchExe); plain.string(meta.launchCommand)
            plain.put(UInt32(0)); plain.string(""); plain.string(""); plain.string(""); plain.string(""); plain.string("")
            files.forEach { plain.string($0.filename); plain.string($0.symlinkTarget) }
            let iv = Data((0..<12).map { UInt8($0) })
            let box = try AES.GCM.seal(plain.data, using: encryption.key, nonce: AES.GCM.Nonce(data: iv))
            tag = box.tag
            var block = Out()
            block.put(UInt32(4 + 4 + 1 + 4 + 4 + 4 + iv.count)); block.put(UInt32(0)); block.put(UInt8(0))
            block.put(UInt32(plain.data.count)); block.put(UInt32(plain.data.count)); block.put(UInt32(iv.count)); block.data.append(iv)
            block.put(UInt32(box.ciphertext.count)); block.data.append(box.ciphertext)
            body.section(version: 0) { o in o.put(UInt32(block.data.count)); o.data.append(block.data) }
        }
        let stored = try compress ? EpicCodec.deflateZlib(body.data) : body.data
        var out = Out()
        let version = max(featureLevel, 18)
        out.put(UInt32(0x44BEC00C)); out.put(UInt32(version >= 22 ? 73 : 41))
        out.put(UInt32(body.data.count)); out.put(UInt32(stored.count))
        out.data.append(EpicCodec.sha1(body.data))
        out.put(UInt8((compress ? 1 : 0) | (encrypted ? 2 : 0))); out.put(version)
        if version >= 22 { out.data.append((encryption?.guid ?? EpicGUID(a: 0, b: 0, c: 0, d: 0)).littleEndianBytes); out.data.append(tag) }
        out.data.append(stored)
        return out.data
    }
}

func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try Data(contentsOf: url)
}

final class ManifestTests: XCTestCase {
    private struct Expected: Decodable {
        struct FileInfo: Decodable { let filename: String; let sha1: String; let size: UInt64; let parts: Int; let flags: UInt8 }
        struct ChunkInfo: Decodable { let path: String; let guid: String; let sha1: String; let size: Int }
        let version: UInt32, featureLevel: UInt32, appName: String, buildVersion: String, launchExe: String, buildID: String
        let fileCount: Int, chunkCount: Int, installSize: UInt64, downloadSize: Int64
        let firstFiles: [FileInfo], chunkPaths: [String], fixtureChunk: ChunkInfo
    }

    private func expected() throws -> Expected { try JSONDecoder().decode(Expected.self, from: fixture("overlay-expected.json")) }

    func testParsesPublicOverlayManifestLikeLegendary() throws {
        let manifest = try EpicManifest.parse(fixture("overlay.manifest"))
        let e = try expected()
        XCTAssertEqual(manifest.version, e.version)
        XCTAssertEqual(manifest.meta.featureLevel, e.featureLevel)
        XCTAssertEqual(manifest.meta.appName, e.appName)
        XCTAssertEqual(manifest.meta.buildVersion, e.buildVersion)
        XCTAssertEqual(manifest.meta.launchExe, e.launchExe)
        XCTAssertEqual(manifest.meta.buildID, e.buildID)
        XCTAssertEqual(manifest.files.count, e.fileCount)
        XCTAssertEqual(manifest.chunks.count, e.chunkCount)
        XCTAssertEqual(manifest.installSize, e.installSize)
        XCTAssertEqual(manifest.downloadSize, e.downloadSize)
        for (file, want) in zip(manifest.files, e.firstFiles) {
            XCTAssertEqual(file.filename, want.filename)
            XCTAssertEqual(file.sha1.hexString, want.sha1)
            XCTAssertEqual(file.fileSize, want.size)
            XCTAssertEqual(file.chunkParts.count, want.parts)
            XCTAssertEqual(file.flags, want.flags)
        }
        XCTAssertEqual(manifest.chunks.prefix(3).map(manifest.path(for:)), e.chunkPaths)
        let chunks = manifest.chunksByGUID
        for file in manifest.files { for part in file.chunkParts { XCTAssertNotNil(chunks[part.guid]) } }
    }

    func testDecodesAndVerifiesPublicOverlayChunk() throws {
        let e = try expected().fixtureChunk
        let manifest = try EpicManifest.parse(fixture("overlay.manifest"))
        let info = try XCTUnwrap(manifest.chunks.first { $0.guid.description == e.guid })
        XCTAssertEqual(manifest.path(for: info), e.path)
        let chunk = try EpicChunk.decode(fixture("overlay.chunk"), expectedSHA1: info.sha1)
        XCTAssertEqual(chunk.data.count, e.size)
        XCTAssertEqual(chunk.guid, info.guid)
        XCTAssertEqual(chunk.rollingHash, info.rollingHash)
    }

    func testRejectsChunkWhoseContentDoesNotMatchManifest() throws {
        let guid = EpicGUID(a: 1, b: 2, c: 3, d: 4)
        let raw = try EpicChunk.encode(guid: guid, data: Data("payload".utf8))
        XCTAssertEqual(try EpicChunk.decode(raw).data, Data("payload".utf8))
        XCTAssertThrowsError(try EpicChunk.decode(raw, expectedSHA1: EpicCodec.sha1(Data("other".utf8)))) {
            XCTAssertEqual($0 as? EpicError, .hashMismatch("chunk \(guid)"))
        }
    }

    func testRoundTripsCompressedAndUncompressedBinaryManifests() throws {
        let guid = EpicGUID(a: 0xAABBCCDD, b: 1, c: 2, d: 3)
        var writer = ManifestWriter()
        writer.meta.appName = "Sugar"; writer.meta.buildVersion = "1.0-Windows"
        writer.meta.launchExe = "Binaries\\Win64\\Game.exe"; writer.meta.launchCommand = "-nolauncher"
        writer.chunks = [.init(guid: guid, rollingHash: 0x1122334455667788, sha1: Data(count: 20), groupNumber: 7, windowSize: 10, fileSize: 9)]
        writer.files = [.init(filename: "Binaries/Win64/Game.exe", sha1: Data(repeating: 1, count: 20), flags: 0x4,
                              chunkParts: [.init(guid: guid, offset: 0, size: 6, fileOffset: 0)]),
                        .init(filename: "Données/ünïcode.txt", sha1: Data(repeating: 2, count: 20),
                              chunkParts: [.init(guid: guid, offset: 6, size: 4, fileOffset: 0)])]
        writer.customFields = [("BaseUrl", "x")]
        for compress in [true, false] {
            writer.compress = compress
            let manifest = try EpicManifest.parse(writer.write())
            XCTAssertEqual(manifest.meta.launchExe, "Binaries\\Win64\\Game.exe")
            XCTAssertEqual(manifest.meta.launchCommand, "-nolauncher")
            XCTAssertEqual(manifest.files.map(\.filename), ["Binaries/Win64/Game.exe", "Données/ünïcode.txt"])
            XCTAssertTrue(manifest.files[0].isExecutable)
            XCTAssertEqual(manifest.files[1].chunkParts.first?.offset, 6)
            XCTAssertEqual(manifest.customFields, ["BaseUrl": "x"])
            XCTAssertEqual(manifest.path(for: manifest.chunks[0]), "ChunksV4/07/1122334455667788_AABBCCDD000000010000000200000003.chunk")
        }
    }

    func testDetectsCorruptedCompressedBody() throws {
        var data = try ManifestWriter(meta: .init(appName: "A")).write()
        data[20] ^= 0xFF // inside the header SHA-1
        XCTAssertThrowsError(try EpicManifest.parse(data)) { XCTAssertEqual($0 as? EpicError, .hashMismatch("manifest body")) }
    }

    func testDecryptsFeatureLevel24ManifestWithSecretFromManifestAPI() throws {
        let key = SymmetricKey(size: .bits256)
        let secretGUID = EpicGUID(a: 0xDEADBEEF, b: 0, c: 0, d: 1)
        let chunkSecret = EpicGUID(a: 9, b: 8, c: 7, d: 6)
        let guid = EpicGUID(a: 5, b: 6, c: 7, d: 8)
        var writer = ManifestWriter(featureLevel: 24)
        writer.meta.appName = "Secret"; writer.meta.launchExe = "Game.exe"
        writer.chunks = [.init(guid: guid, rollingHash: 42, sha1: Data(count: 20), groupNumber: 3, windowSize: 4, fileSize: 4, secretGUID: chunkSecret)]
        writer.files = [.init(filename: "Game.exe", sha1: Data(count: 20), chunkParts: [.init(guid: guid, offset: 0, size: 4, fileOffset: 0)])]
        writer.encryption = (secretGUID, key)
        let data = try writer.write()
        let hex = key.withUnsafeBytes { Data($0) }.hexString

        XCTAssertThrowsError(try EpicManifest.parse(data)) { XCTAssertEqual($0 as? EpicError, .missingKey(secretGUID.description)) }
        let manifest = try EpicManifest.parse(data, secrets: [secretGUID.description: hex])
        XCTAssertEqual(manifest.meta.launchExe, "Game.exe")
        XCTAssertEqual(manifest.files.map(\.filename), ["Game.exe"])
        XCTAssertEqual(manifest.chunks[0].secretGUID, chunkSecret)
        let secretPart = EpicCodec.base64URL(chunkSecret.littleEndianBytes)
        XCTAssertEqual(manifest.path(for: manifest.chunks[0]), "ChunksV5/\(secretPart)/03/KgAAAAAAAAA_BQAAAAYAAAAHAAAACAAAAA.chunk")
        var plain = manifest.chunks[0]; plain.secretGUID = EpicGUID(a: 0, b: 0, c: 0, d: 0)
        XCTAssertTrue(manifest.path(for: plain).hasPrefix("ChunksV5/plain/03/"))
    }

    func testParsesJSONManifestBlobs() throws {
        let guid = "0000000A0000000B0000000C0000000D"
        let json = """
        {"ManifestFileVersion":"013000000000","bIsFileData":false,"AppID":"000000000000","AppNameString":"Old",
         "BuildVersionString":"1","LaunchExeString":"Old.exe","LaunchCommand":"","PrereqIds":[],
         "FileManifestList":[{"Filename":"Old.exe","FileHash":"\(String(repeating: "001", count: 20))","bIsUnixExecutable":true,
           "FileChunkParts":[{"Guid":"\(guid)","Offset":"000000000000","Size":"016000000000"}]}],
         "ChunkHashList":{"\(guid)":"255000000000000000"},"ChunkShaList":{"\(guid)":"\(String(repeating: "ab", count: 20))"},
         "DataGroupList":{"\(guid)":"042000000000"},"ChunkFilesizeList":{"\(guid)":"100000000000"},"CustomFields":{"k":"v"}}
        """
        let manifest = try EpicManifest.parse(Data(json.utf8))
        XCTAssertEqual(manifest.version, 13)
        XCTAssertEqual(manifest.files.first?.fileSize, 16)
        XCTAssertEqual(manifest.files.first?.sha1, Data(repeating: 1, count: 20))
        XCTAssertTrue(manifest.files.first?.isExecutable ?? false)
        XCTAssertEqual(manifest.chunks.first?.fileSize, 100)
        XCTAssertEqual(manifest.chunks.first?.rollingHash, 255)
        XCTAssertEqual(manifest.path(for: manifest.chunks[0]), "ChunksV3/42/00000000000000FF_\(guid).chunk")
        XCTAssertEqual(manifest.customFields, ["k": "v"])
    }
}
