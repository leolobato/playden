import Foundation
import zlib

/// An Epic build manifest: what files a build has and which chunk slices make each one.
/// Ported from legendary's `models/manifest.py` and `models/json_manifest.py`.
public struct EpicManifest: Sendable {
    public struct Meta: Sendable, Equatable {
        public var featureLevel: UInt32 = 0
        public var isFileData = false
        public var appID: UInt32 = 0
        public var appName = ""
        public var buildVersion = ""
        public var launchExe = ""
        public var launchCommand = ""
        public var prereqIDs: [String] = []
        public var prereqName = ""
        public var prereqPath = ""
        public var prereqArgs = ""
        public var storedBuildID = ""
        public var uninstallActionPath = ""
        public var uninstallActionArgs = ""

        /// Stored from data version 1; computed the way the launcher does for older manifests.
        public var buildID: String {
            if !storedBuildID.isEmpty { return storedBuildID }
            var input = Data()
            withUnsafeBytes(of: appID.littleEndian) { input.append(contentsOf: $0) }
            for part in [appName, buildVersion, launchExe, launchCommand] { input.append(Data(part.utf8)) }
            return EpicCodec.base64URL(EpicCodec.sha1(input))
        }
    }

    public struct Chunk: Sendable, Equatable {
        public var guid: EpicGUID
        public var rollingHash: UInt64
        public var sha1: Data
        public var groupNumber: UInt8
        /// Uncompressed size.
        public var windowSize: UInt32
        /// Download (compressed) size.
        public var fileSize: Int64
        public var secretGUID: EpicGUID?
        public var windowSizeCompressed: UInt32 = 0
        public var encryptionTag = Data()
    }

    public struct ChunkPart: Sendable, Equatable {
        public var guid: EpicGUID
        /// Offset into the chunk's uncompressed data.
        public var offset: UInt32
        public var size: UInt32
        /// Offset of this part within the file.
        public var fileOffset: UInt64
    }

    public struct File: Sendable, Equatable {
        public var filename: String
        public var symlinkTarget = ""
        public var sha1: Data
        public var flags: UInt8 = 0
        public var installTags: [String] = []
        public var chunkParts: [ChunkPart] = []
        public var fileSize: UInt64 { chunkParts.reduce(0) { $0 + UInt64($1.size) } }
        public var isReadOnly: Bool { flags & 0x1 != 0 }
        public var isExecutable: Bool { flags & 0x4 != 0 }
    }

    /// The header's serialisation version. Chunk paths follow `meta.featureLevel` instead.
    public var version: UInt32
    public var meta: Meta
    public var chunks: [Chunk]
    public var files: [File]
    public var customFields: [String: String]

    public var chunkDirectoryVersion: UInt32 { meta.featureLevel }
    public var chunksByGUID: [EpicGUID: Chunk] { Dictionary(chunks.map { ($0.guid, $0) }, uniquingKeysWith: { a, _ in a }) }
    public var downloadSize: Int64 { chunks.reduce(0) { $0 + $1.fileSize } }
    public var installSize: UInt64 { files.reduce(0) { $0 + $1.fileSize } }

    public func path(for chunk: Chunk) -> String { Self.chunkPath(chunk, featureLevel: chunkDirectoryVersion) }

    static func chunkDirectory(_ version: UInt32) -> String {
        switch version {
        case 22...: "ChunksV5"
        case 15...: "ChunksV4"
        case 6...: "ChunksV3"
        case 3...: "ChunksV2"
        default: "Chunks"
        }
    }

    static func chunkPath(_ chunk: Chunk, featureLevel: UInt32) -> String {
        let directory = chunkDirectory(featureLevel)
        let group = String(format: "%02d", chunk.groupNumber)
        if featureLevel >= 22 {
            let secret = chunk.secretGUID.flatMap { $0.isZero ? nil : EpicCodec.base64URL($0.littleEndianBytes) } ?? "plain"
            var hash = Data()
            withUnsafeBytes(of: chunk.rollingHash.littleEndian) { hash.append(contentsOf: $0) }
            return "\(directory)/\(secret)/\(group)/\(EpicCodec.base64URL(hash))_\(EpicCodec.base64URL(chunk.guid.littleEndianBytes)).chunk"
        }
        return "\(directory)/\(group)/\(String(format: "%016llX", chunk.rollingHash))_\(chunk.guid).chunk"
    }

    /// JSON manifests store no group number; the launcher derives it from the GUID.
    static func groupNumber(for guid: EpicGUID) -> UInt8 {
        let bytes = guid.littleEndianBytes
        let crc = bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(bytes.count)) }
        return UInt8(crc % 100)
    }
}

// MARK: - Parsing

public extension EpicManifest {
    private static let magic: UInt32 = 0x44BEC00C

    /// Parses a binary or JSON manifest. Encrypted manifests need `secrets` from the manifest API.
    static func parse(_ data: Data, secrets: [String: String] = [:]) throws -> EpicManifest {
        if data.first == UInt8(ascii: "{") { return try parseJSON(data) }
        return try parseBinary(data, secrets: secrets)
    }

    static func parseBinary(_ data: Data, secrets: [String: String] = [:]) throws -> EpicManifest {
        var header = BinaryReader(data)
        guard try header.u32() == magic else { throw EpicError.malformed("manifest magic") }
        let headerSize = Int(try header.u32())
        let sizeUncompressed = Int(try header.u32())
        _ = try header.u32()
        let sha = try header.bytes(20)
        let storedAs = try header.u8()
        let version = try header.u32()
        var secretGUID = EpicGUID(a: 0, b: 0, c: 0, d: 0)
        var encryptionTag = Data()
        if version >= 22 { secretGUID = try header.guid(); encryptionTag = try header.bytes(16) }
        try header.seek(headerSize)
        var body = try header.bytes(header.remaining)
        if storedAs & 0x1 != 0 {
            body = try EpicCodec.inflateZlib(body, expectedSize: sizeUncompressed)
            guard EpicCodec.sha1(body) == sha else { throw EpicError.hashMismatch("manifest body") }
        }

        var r = BinaryReader(body)
        var meta = try readMeta(&r)
        let chunks = try readChunks(&r, featureLevel: meta.featureLevel)
        var files = try readFiles(&r)
        let custom = try readCustomFields(&r)
        if storedAs & 0x2 != 0 {
            guard meta.featureLevel >= 24 else { throw EpicError.malformed("encrypted manifest below feature level 24") }
            try decrypt(&r, secretGUID: secretGUID, tag: encryptionTag, secrets: secrets, meta: &meta, files: &files)
        }
        return EpicManifest(version: version, meta: meta, chunks: chunks, files: files, customFields: custom)
    }

    private static func section(_ r: inout BinaryReader) throws -> (start: Int, size: Int, version: UInt8) {
        let start = r.offset
        let size = Int(try r.u32())
        return (start, size, try r.u8())
    }

    private static func finish(_ r: inout BinaryReader, _ s: (start: Int, size: Int, version: UInt8)) throws {
        if r.offset != s.start + s.size { try r.seek(s.start + s.size) }
    }

    private static func readMeta(_ r: inout BinaryReader) throws -> Meta {
        let s = try section(&r)
        var m = Meta()
        m.featureLevel = try r.u32()
        m.isFileData = try r.u8() == 1
        m.appID = try r.u32()
        m.appName = try r.fstring()
        m.buildVersion = try r.fstring()
        m.launchExe = try r.fstring()
        m.launchCommand = try r.fstring()
        m.prereqIDs = try (0..<r.u32()).map { _ in try r.fstring() }
        m.prereqName = try r.fstring()
        m.prereqPath = try r.fstring()
        m.prereqArgs = try r.fstring()
        if s.version >= 1 { m.storedBuildID = try r.fstring() }
        if s.version >= 2 { m.uninstallActionPath = try r.fstring(); m.uninstallActionArgs = try r.fstring() }
        try finish(&r, s)
        return m
    }

    private static func readChunks(_ r: inout BinaryReader, featureLevel: UInt32) throws -> [Chunk] {
        let s = try section(&r)
        let count = Int(try r.u32())
        let guids = try (0..<count).map { _ in try r.guid() }
        let hashes = try (0..<count).map { _ in try r.u64() }
        let shas = try (0..<count).map { _ in try r.bytes(20) }
        let groups = try (0..<count).map { _ in try r.u8() }
        let windows = try (0..<count).map { _ in try r.u32() }
        let sizes = try (0..<count).map { _ in try r.i64() }
        var chunks = (0..<count).map {
            Chunk(guid: guids[$0], rollingHash: hashes[$0], sha1: shas[$0], groupNumber: groups[$0],
                  windowSize: windows[$0], fileSize: sizes[$0])
        }
        if featureLevel >= 22 {
            for i in 0..<count { chunks[i].secretGUID = try r.guid() }
            for i in 0..<count { chunks[i].windowSizeCompressed = try r.u32() }
            for i in 0..<count { chunks[i].encryptionTag = try r.bytes(16) }
        }
        try finish(&r, s)
        return chunks
    }

    private static func readFiles(_ r: inout BinaryReader) throws -> [File] {
        let s = try section(&r)
        let count = Int(try r.u32())
        var files = try (0..<count).map { _ in File(filename: try r.fstring(), sha1: Data()) }
        for i in 0..<count { files[i].symlinkTarget = try r.fstring() }
        for i in 0..<count { files[i].sha1 = try r.bytes(20) }
        for i in 0..<count { files[i].flags = try r.u8() }
        for i in 0..<count { files[i].installTags = try (0..<r.u32()).map { _ in try r.fstring() } }
        for i in 0..<count {
            var fileOffset: UInt64 = 0
            for _ in 0..<(try r.u32()) {
                let start = r.offset
                let partSize = Int(try r.u32())
                let part = ChunkPart(guid: try r.guid(), offset: try r.u32(), size: try r.u32(), fileOffset: fileOffset)
                if partSize > r.offset - start { try r.seek(start + partSize) }
                files[i].chunkParts.append(part)
                fileOffset += UInt64(part.size)
            }
        }
        // Version 1 adds MD5 and MIME type, version 2 SHA-256; neither is needed, and `finish` skips them.
        try finish(&r, s)
        return files
    }

    private static func readCustomFields(_ r: inout BinaryReader) throws -> [String: String] {
        guard r.remaining > 0 else { return [:] }
        let s = try section(&r)
        let count = Int(try r.u32())
        let keys = try (0..<count).map { _ in try r.fstring() }
        let values = try (0..<count).map { _ in try r.fstring() }
        try finish(&r, s)
        return Dictionary(zip(keys, values), uniquingKeysWith: { _, b in b })
    }

    /// Feature level 24+: launch data and file names live in an AES-GCM section.
    private static func decrypt(_ r: inout BinaryReader, secretGUID: EpicGUID, tag: Data, secrets: [String: String],
                                meta: inout Meta, files: inout [File]) throws {
        let s = try section(&r)
        let cipherSize = Int(try r.u32())
        var block = BinaryReader(try r.bytes(cipherSize))
        let headerStart = block.offset
        let headerSize = Int(try block.u32())
        _ = try block.u32()
        let storedAs = try block.u8()
        let uncompressed = Int(try block.u32())
        _ = try block.u32()
        let iv = try block.bytes(Int(try block.u32()))
        try block.seek(headerStart + headerSize)
        let ciphertext = try block.bytes(Int(try block.u32()))
        try finish(&r, s)

        guard let hex = secrets[secretGUID.description], let key = EpicCodec.hexData(hex) else {
            throw EpicError.missingKey(secretGUID.description)
        }
        var plain = try EpicCodec.aesGCMOpen(ciphertext, key: key, nonce: iv, tag: tag)
        if storedAs & 0x1 != 0 { plain = try EpicCodec.inflateZlib(plain, expectedSize: uncompressed) }
        var p = BinaryReader(plain)
        meta.launchExe = try p.fstring()
        meta.launchCommand = try p.fstring()
        meta.prereqIDs = try (0..<p.u32()).map { _ in try p.fstring() }
        meta.prereqName = try p.fstring()
        meta.prereqPath = try p.fstring()
        meta.prereqArgs = try p.fstring()
        meta.uninstallActionPath = try p.fstring()
        meta.uninstallActionArgs = try p.fstring()
        for i in files.indices {
            files[i].filename = try p.fstring()
            files[i].symlinkTarget = try p.fstring()
        }
    }

    // MARK: JSON manifests (old titles)

    /// JSON "blobs" write each byte as three decimal digits, least significant first.
    internal static func blobBytes(_ blob: String) throws -> [UInt8] {
        let digits = Array(blob.utf8)
        guard digits.count % 3 == 0 else { throw EpicError.malformed("JSON blob length") }
        return try stride(from: 0, to: digits.count, by: 3).map { i in
            guard let value = UInt16(String(decoding: digits[i..<i + 3], as: UTF8.self)), value <= 255 else {
                throw EpicError.malformed("JSON blob digits")
            }
            return UInt8(value)
        }
    }

    internal static func blobNumber(_ blob: String) throws -> UInt64 {
        try blobBytes(blob).prefix(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    static func parseJSON(_ data: Data) throws -> EpicManifest {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EpicError.malformed("JSON manifest root")
        }
        func string(_ key: String) -> String { json[key] as? String ?? "" }
        func number(_ key: String, _ fallback: String) throws -> UInt64 { try blobNumber(json[key] as? String ?? fallback) }
        let version = UInt32(try number("ManifestFileVersion", "013000000000"))
        var meta = Meta()
        meta.featureLevel = version
        meta.isFileData = json["bIsFileData"] as? Bool ?? false
        meta.appID = UInt32(truncatingIfNeeded: try number("AppID", "000000000000"))
        meta.appName = string("AppNameString")
        meta.buildVersion = string("BuildVersionString")
        meta.launchExe = string("LaunchExeString")
        meta.launchCommand = string("LaunchCommand")
        meta.prereqIDs = json["PrereqIds"] as? [String] ?? []
        meta.prereqName = string("PrereqName")
        meta.prereqPath = string("PrereqPath")
        meta.prereqArgs = string("PrereqArgs")

        let sizes = json["ChunkFilesizeList"] as? [String: String] ?? [:]
        let hashes = json["ChunkHashList"] as? [String: String] ?? [:]
        let shas = json["ChunkShaList"] as? [String: String] ?? [:]
        let groups = json["DataGroupList"] as? [String: String] ?? [:]
        let chunks: [Chunk] = try sizes.keys.sorted().map { key in
            guard let guid = EpicGUID(hex: key) else { throw EpicError.malformed("JSON chunk GUID") }
            let group = try groups[key].map { UInt8(truncatingIfNeeded: try blobNumber($0)) } ?? groupNumber(for: guid)
            return Chunk(guid: guid, rollingHash: try blobNumber(hashes[key] ?? "000"),
                         sha1: shas[key].flatMap(EpicCodec.hexData) ?? Data(), groupNumber: group,
                         windowSize: 1024 * 1024, fileSize: Int64(try blobNumber(sizes[key] ?? "000")))
        }

        let fileList = json["FileManifestList"] as? [[String: Any]] ?? []
        let files: [File] = try fileList.map { entry in
            var file = File(filename: entry["Filename"] as? String ?? "",
                            sha1: Data(try blobBytes(entry["FileHash"] as? String ?? "")))
            if (entry["bIsReadOnly"] as? Bool) == true { file.flags |= 0x1 }
            if (entry["bIsCompressed"] as? Bool) == true { file.flags |= 0x2 }
            if (entry["bIsUnixExecutable"] as? Bool) == true { file.flags |= 0x4 }
            file.installTags = entry["InstallTags"] as? [String] ?? []
            var fileOffset: UInt64 = 0
            for part in entry["FileChunkParts"] as? [[String: String]] ?? [] {
                guard let guid = part["Guid"].flatMap(EpicGUID.init(hex:)) else { throw EpicError.malformed("JSON part GUID") }
                let chunkPart = ChunkPart(guid: guid, offset: UInt32(truncatingIfNeeded: try blobNumber(part["Offset"] ?? "000")),
                                          size: UInt32(truncatingIfNeeded: try blobNumber(part["Size"] ?? "000")),
                                          fileOffset: fileOffset)
                file.chunkParts.append(chunkPart)
                fileOffset += UInt64(chunkPart.size)
            }
            return file
        }
        return EpicManifest(version: version, meta: meta, chunks: chunks, files: files,
                            customFields: json["CustomFields"] as? [String: String] ?? [:])
    }
}
