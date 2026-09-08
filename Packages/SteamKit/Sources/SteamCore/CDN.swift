import Foundation
import SteamProto

public struct ContentServer: Sendable {
    public let host: String
    public let vhost: String
    public let load: Int
}

/// Parsed depot manifest.
public struct DepotManifest: Codable, Equatable, Sendable {
    public struct Chunk: Codable, Equatable, Sendable {
        public let sha: Data          // chunk id (also its CDN path)
        public let offset: UInt64
        public let compressedSize: UInt32
        public let uncompressedSize: UInt32
        public let checksum: UInt32?
        public init(sha: Data, offset: UInt64, compressedSize: UInt32, uncompressedSize: UInt32, checksum: UInt32? = nil) {
            self.sha = sha; self.offset = offset; self.compressedSize = compressedSize
            self.uncompressedSize = uncompressedSize; self.checksum = checksum
        }
        public func validate(_ data: Data) throws {
            guard data.count == Int(uncompressedSize) else { throw SteamError.download("chunk length mismatch") }
            if let checksum {
                guard Self.adler(data) == checksum else { throw SteamError.download("chunk checksum mismatch") }
            } else {
                guard SteamCrypto.sha1(data) == sha else { throw SteamError.download("chunk SHA-1 mismatch") }
            }
        }
        // Steam's manifest checksum is Adler-32 with a zero initial seed.
        static func adler(_ data: Data) -> UInt32 {
            var a: UInt32 = 0, b: UInt32 = 0
            for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
            return (b << 16) | a
        }
    }
    public struct File: Codable, Equatable, Sendable {
        public let path: String       // forward-slash relative path
        public let size: UInt64
        public let flags: UInt32
        public let linkTarget: String
        public let chunks: [Chunk]
        public let contentSHA1: Data?
        public init(path: String, size: UInt64, flags: UInt32 = 0, linkTarget: String = "", chunks: [Chunk], contentSHA1: Data? = nil) {
            self.path = path; self.size = size; self.flags = flags; self.linkTarget = linkTarget
            self.chunks = chunks; self.contentSHA1 = contentSHA1
        }

        public var isDirectory: Bool { flags & 64 != 0 }
        public var isSymlink: Bool { !linkTarget.isEmpty }
        public var isExecutable: Bool { flags & 32 != 0 }
    }
    public let depotID: UInt32
    public let gid: UInt64
    public let files: [File]
    public let totalSize: UInt64
    public init(depotID: UInt32, gid: UInt64, files: [File], totalSize: UInt64) {
        self.depotID = depotID; self.gid = gid; self.files = files; self.totalSize = totalSize
    }
}

public enum CDNClient {

    public static func contentServers(cellID: UInt32) async throws -> [ContentServer] {
        let json = try await SteamWebAPI.callJSON(
            interface: "IContentServerDirectoryService", method: "GetServersForSteamPipe",
            params: ["cell_id": String(cellID)])
        guard let response = json["response"] as? [String: Any],
              let servers = response["servers"] as? [[String: Any]] else {
            throw SteamError.protocolError("GetServersForSteamPipe: no servers")
        }
        let usable = servers.compactMap { s -> ContentServer? in
            let type = (s["type"] as? String) ?? ""
            guard type == "SteamCache" || type == "CDN" else { return nil }
            guard ((s["https_support"] as? String) ?? "") != "unavailable" else { return nil }
            guard let host = s["host"] as? String else { return nil }
            return ContentServer(host: host, vhost: (s["vhost"] as? String) ?? host,
                                 load: (s["load"] as? Int) ?? 100)
        }
        guard !usable.isEmpty else { throw SteamError.protocolError("no usable content servers") }
        return usable.sorted { $0.load < $1.load }
    }

    // MARK: manifest

    public static func fetchManifest(server: ContentServer, depotID: UInt32, gid: UInt64,
                                     requestCode: UInt64, depotKey: Data) async throws -> DepotManifest {
        let url = "https://\(server.vhost)/depot/\(depotID)/manifest/\(gid)/5/\(requestCode)"
        let raw = try await get(url)
        let unzipped = try Decompress.unzipFirstEntry(raw)
        let manifest = try parseManifest(unzipped, depotKey: depotKey)
        guard manifest.depotID == depotID, manifest.gid == gid else { throw SteamError.download("CDN returned a different depot manifest") }
        return manifest
    }

    static let payloadMagic: UInt32 = 0x71F6_17D0
    static let metadataMagic: UInt32 = 0x1F48_12BE
    static let signatureMagic: UInt32 = 0x1B81_B817
    static let endMagic: UInt32 = 0x32C4_15AB

    /// Serialized manifest: [magic u32][len u32][blob] repeated (payload,
    /// metadata, signature), terminated by the EOF magic.
    static func parseManifest(_ data: Data, depotKey: Data) throws -> DepotManifest {
        var offset = 0
        var payload: ContentManifestPayload?
        var metadata: ContentManifestMetadata?
        while offset + 4 <= data.count {
            let magic = data.readLE(UInt32.self, at: offset)
            offset += 4
            if magic == endMagic { break }
            guard offset + 4 <= data.count else { throw SteamError.protocolError("manifest: truncated") }
            let length = Int(data.readLE(UInt32.self, at: offset))
            offset += 4
            guard offset + length <= data.count else { throw SteamError.protocolError("manifest: truncated blob") }
            let blob = data.subdata(in: data.startIndex + offset..<data.startIndex + offset + length)
            offset += length
            switch magic {
            case payloadMagic: payload = try ContentManifestPayload(serializedBytes: blob)
            case metadataMagic: metadata = try ContentManifestMetadata(serializedBytes: blob)
            case signatureMagic: break  // not verified in the PoC
            default: throw SteamError.protocolError(String(format: "manifest: unknown magic %08x", magic))
            }
        }
        guard let payload, let metadata else { throw SteamError.protocolError("manifest: missing sections") }

        var files: [DepotManifest.File] = []
        var total: UInt64 = 0
        for mapping in payload.mappings {
            var path = mapping.filename
            if metadata.filenamesEncrypted {
                // .ignoreUnknownCharacters: encrypted names embed newlines
                // (SteamKit's .NET base64 decoder skips whitespace anywhere).
                guard let ciphertext = Data(base64Encoded: path, options: .ignoreUnknownCharacters) else {
                    throw SteamError.crypto("manifest: bad encrypted filename")
                }
                var decrypted = try SteamCrypto.symmetricDecrypt(ciphertext, key: depotKey)
                while decrypted.last == 0 { decrypted.removeLast() }
                guard let s = String(data: decrypted, encoding: .utf8) else {
                    throw SteamError.crypto("manifest: filename not UTF-8 after decrypt")
                }
                path = s
            }
            path = path.replacingOccurrences(of: "\\", with: "/")
            let chunks = mapping.chunks.map {
                DepotManifest.Chunk(sha: $0.sha, offset: $0.offset,
                                    compressedSize: $0.cbCompressed, uncompressedSize: $0.cbOriginal,
                                    checksum: $0.hasCrc ? $0.crc : nil)
            }.sorted { $0.offset < $1.offset }
            let file = DepotManifest.File(path: path, size: mapping.size, flags: mapping.flags,
                                          linkTarget: mapping.linktarget, chunks: chunks,
                                          contentSHA1: mapping.hasShaContent ? mapping.shaContent : nil)
            if !file.isDirectory {
                let sum = total.addingReportingOverflow(mapping.size)
                guard !sum.overflow else { throw SteamError.download("manifest size overflows") }
                total = sum.partialValue
            }
            files.append(file)
        }
        files.sort { $0.path < $1.path }
        return DepotManifest(depotID: metadata.depotID, gid: metadata.gidManifest,
                             files: files, totalSize: total)
    }

    // MARK: chunks

    /// Downloads and processes (decrypt + decompress) one chunk.
    public static func fetchChunk(server: ContentServer, depotID: UInt32,
                                  chunk: DepotManifest.Chunk, depotKey: Data,
                                  onTransfer: @Sendable (Int) -> Void = { _ in }) async throws -> Data {
        let url = "https://\(server.vhost)/depot/\(depotID)/chunk/\(chunk.sha.hexString)"
        let raw = try await get(url)
        onTransfer(raw.count)
        let decrypted = try SteamCrypto.symmetricDecrypt(raw, key: depotKey)
        let data: Data
        do {
            data = try Decompress.depotChunk(decrypted)
        } catch {
            // Keep the evidence: the decrypted container is not secret and is
            // exactly what a decoder bug needs for offline analysis.
            let dump = FileManager.default.temporaryDirectory
                .appendingPathComponent("gnsteam-chunk-\(chunk.sha.hexString.prefix(12)).bin")
            try? decrypted.write(to: dump)
            throw SteamError.download("\(error) — decrypted chunk dumped to \(dump.path)")
        }
        try chunk.validate(data)
        return data
    }

    static func get(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw SteamError.download("bad URL \(urlString)") }
        var req = URLRequest(url: url)
        req.setValue("Valve/Steam HTTP Client 1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SteamError.protocolError("no HTTP response") }
        guard http.statusCode == 200 else { throw SteamError.http(status: http.statusCode, url: urlString) }
        return data
    }
}
