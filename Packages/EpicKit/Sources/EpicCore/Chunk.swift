import Foundation

/// A downloaded chunk file. Ported from legendary's `models/chunk.py`.
public struct EpicChunk: Sendable {
    private static let magic: UInt32 = 0xB1FE3AA2

    public var guid: EpicGUID
    public var rollingHash: UInt64
    public var sha1: Data?
    /// The chunk's uncompressed bytes.
    public var data: Data

    /// Decodes a chunk and, when `expectedSHA1` is given, checks the decoded bytes against it.
    public static func decode(_ raw: Data, secrets: [String: String] = [:], expectedSHA1: Data? = nil) throws -> EpicChunk {
        var r = BinaryReader(raw)
        guard try r.u32() == magic else { throw EpicError.malformed("chunk magic") }
        let headerVersion = try r.u32()
        let headerSize = Int(try r.u32())
        let compressedSize = Int(try r.u32())
        let guid = try r.guid()
        let rollingHash = try r.u64()
        let storedAs = try r.u8()
        var sha: Data?
        var uncompressedSize = 1024 * 1024
        var secretGUID: EpicGUID?
        var tag = Data()
        if headerVersion >= 2 { sha = try r.bytes(20); _ = try r.u8() }
        if headerVersion >= 3 { uncompressedSize = Int(try r.u32()) }
        if headerVersion >= 4 { secretGUID = try r.guid(); tag = try r.bytes(16) }
        guard r.offset == headerSize else { throw EpicError.malformed("chunk header size") }
        var body = try r.bytes(min(compressedSize, r.remaining))
        if storedAs & 0x2 != 0 {
            guard let secretGUID, let hex = secrets[secretGUID.description], let key = EpicCodec.hexData(hex), let sha else {
                throw EpicError.missingKey(secretGUID?.description ?? "chunk")
            }
            body = try EpicCodec.aesGCMOpen(body, key: key, nonce: sha.prefix(12), tag: tag)
        }
        if storedAs & 0x1 != 0 { body = try EpicCodec.inflateZlib(body, expectedSize: uncompressedSize) }
        if let expected = expectedSHA1 ?? sha, !expected.isEmpty, EpicCodec.sha1(body) != expected {
            throw EpicError.hashMismatch("chunk \(guid)")
        }
        return EpicChunk(guid: guid, rollingHash: rollingHash, sha1: sha, data: body)
    }

    /// Builds an unencrypted header-v3 chunk. Tests and fixtures use it.
    public static func encode(guid: EpicGUID, data: Data, rollingHash: UInt64 = 0, compress: Bool = true) throws -> Data {
        let body = compress ? try EpicCodec.deflateZlib(data) : data
        var out = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        put(magic); put(UInt32(3)); put(UInt32(66)); put(UInt32(body.count))
        out.append(guid.littleEndianBytes)
        put(rollingHash)
        put(UInt8(compress ? 1 : 0))
        out.append(EpicCodec.sha1(data)); put(UInt8(2))
        put(UInt32(data.count))
        out.append(body)
        return out
    }
}
