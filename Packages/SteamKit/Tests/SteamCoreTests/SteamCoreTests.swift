import XCTest
import CommonCrypto
import Security
@testable import SteamCore

final class DecompressTests: XCTestCase {

    private func run(_ tool: String, args: [String], stdin: Data) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        try p.run()
        inPipe.fileHandleForWriting.write(stdin)
        try inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return out
    }

    func testGunzip() throws {
        let original = Data((0..<10_000).map { _ in UInt8.random(in: 0...255) }) + Data(repeating: 7, count: 50_000)
        let gzipped = try run("/usr/bin/gzip", args: ["-c"], stdin: original)
        XCTAssertEqual(try Decompress.gunzip(gzipped), original)
    }

    func testUnzipFirstEntry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data(repeating: 0x41, count: 30_000) + Data((0..<5000).map { _ in UInt8.random(in: 0...255) })
        try original.write(to: dir.appendingPathComponent("payload.bin"))
        let zipURL = dir.appendingPathComponent("t.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-q", zipURL.path, "payload.bin"]
        try p.run()
        p.waitUntilExit()
        let zipped = try Data(contentsOf: zipURL)
        XCTAssertEqual(try Decompress.unzipFirstEntry(zipped), original)
    }

    /// Decodes a real (decrypted) Steam chunk when one is provided, e.g. a file
    /// dumped by CDNClient on failure: GNSTEAM_CHUNK_DUMP=/path swift test
    func testRealChunkDumpIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["GNSTEAM_CHUNK_DUMP"] else {
            throw XCTSkip("set GNSTEAM_CHUNK_DUMP to a decrypted chunk file")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let out = try Decompress.depotChunk(data)
        print("decoded \(out.count) bytes from \(path)")
        XCTAssertGreaterThan(out.count, 0)
    }

    func testVZip() throws {
        // Build a VZ container from `xz --format=lzma` output:
        // .lzma "alone" = props(5) + uncompressed size(8) + raw LZMA stream.
        let original = Data(repeating: 0x5A, count: 20_000) + Data((0..<2000).map { _ in UInt8.random(in: 0...255) })
        let alone = try run("/opt/homebrew/bin/xz", args: ["--format=lzma", "-c"], stdin: original)
        XCTAssertGreaterThan(alone.count, 13)
        var vz = Data("VZa".utf8)
        vz.append(Data([0, 0, 0, 0]))                       // crc/timestamp field (unchecked)
        vz.append(alone.prefix(5))                          // lzma props
        vz.append(alone.dropFirst(13))                      // raw stream
        var footer = Data()
        footer.appendLE(UInt32(0))                          // crc (unchecked)
        footer.appendLE(UInt32(original.count))
        footer.append(Data("zv".utf8))
        vz.append(footer)
        XCTAssertEqual(try Decompress.vzip(vz), original)
    }

    func testVZstd() throws {
        // Build a VSZ container around a plain zstd frame, as newer depots ship.
        let original = Data(repeating: 0x5A, count: 20_000) + Data((0..<2000).map { _ in UInt8.random(in: 0...255) })
        let frame = try run("/opt/homebrew/bin/zstd", args: ["-q", "-c"], stdin: original)
        XCTAssertGreaterThan(frame.count, 4)
        var vsz = Data("VSZa".utf8)
        vsz.appendLE(UInt32(0))                             // crc (unchecked)
        vsz.append(frame)
        vsz.appendLE(UInt32(0))                             // crc (unchecked)
        vsz.appendLE(UInt32(original.count))
        vsz.appendLE(UInt32(0))                             // high half of the 64-bit size
        vsz.append(Data("zsv".utf8))
        XCTAssertEqual(try Decompress.vzstd(vsz), original)
        XCTAssertEqual(try Decompress.depotChunk(vsz), original)
    }
}

final class VDFTests: XCTestCase {
    func testParse() throws {
        let text = """
        "appinfo"
        {
            "appid"  "379720"
            "common" { "name" "DOOM" "type" "Game" }
            // comment
            "depots"
            {
                "379721" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "123" "size" "456" } } }
                "branches" { "public" { "buildid" "999" } }
            }
        }
        """
        let vdf = try VDF.parse(text)
        XCTAssertEqual(vdf["appinfo"]?["common"]?["name"]?.stringValue, "DOOM")
        XCTAssertEqual(vdf["appinfo"]?["depots"]?["379721"]?["manifests"]?["public"]?["gid"]?.uint64Value, 123)
        let app = CMClient.parseAppInfo(appID: 379720, root: vdf["appinfo"]!)
        XCTAssertEqual(app.name, "DOOM")
        XCTAssertEqual(app.depots.count, 1)
        XCTAssertEqual(app.depots[0].manifestGID, 123)
        XCTAssertTrue(app.depots[0].isWindows)
        XCTAssertEqual(app.branches["public"], 999)
    }
}

final class CryptoTests: XCTestCase {
    func testSymmetricRoundTrip() throws {
        // Encrypt with the same scheme (ECB'd IV + CBC body) and decrypt back.
        var key = Data(count: 32)
        _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let plaintext = Data("some/depot/file name.txt".utf8)
        let encrypted = try encrypt(plaintext, key: key)
        XCTAssertEqual(try SteamCrypto.symmetricDecrypt(encrypted, key: key), plaintext)
    }

    private func encrypt(_ data: Data, key: Data) throws -> Data {
        // Test-only inverse of SteamCrypto.symmetricDecrypt.
        var iv = Data(count: 16)
        _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        func cc(_ op: CCOperation, _ options: CCOptions, _ input: Data, iv: Data?) throws -> Data {
            var out = Data(count: input.count + 16)
            var n = 0
            let status = out.withUnsafeMutableBytes { o in
                input.withUnsafeBytes { i in
                    key.withUnsafeBytes { k in
                        if let iv {
                            return iv.withUnsafeBytes { v in
                                CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), options, k.baseAddress, 32, v.baseAddress,
                                        i.baseAddress, input.count, o.baseAddress, o.count, &n)
                            }
                        }
                        return CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), options, k.baseAddress, 32, nil,
                                       i.baseAddress, input.count, o.baseAddress, o.count, &n)
                    }
                }
            }
            XCTAssertEqual(status, Int32(kCCSuccess))
            return out.prefix(n)
        }
        let encryptedIV = try cc(CCOperation(kCCEncrypt), CCOptions(kCCOptionECBMode), iv, iv: nil)
        let body = try cc(CCOperation(kCCEncrypt), CCOptions(kCCOptionPKCS7Padding), data, iv: iv)
        return encryptedIV + body
    }
}
