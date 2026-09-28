import Foundation
import CryptoKit
import zlib

public enum EpicError: Error, Equatable, Sendable, LocalizedError {
    case malformed(String)
    case hashMismatch(String)
    case missingKey(String)
    case http(status: Int, code: String?, message: String?)
    case correctiveAction(URL?)
    case authorizationPending
    case deviceCodeExpired
    case invalidCredentials(String?)
    case network(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .malformed(let d): "Epic data is malformed: \(d)"
        case .hashMismatch(let d): "Epic data failed its integrity check: \(d)"
        case .missingKey(let d): "Epic did not provide the key for encrypted content (\(d))."
        case .http(let s, let c, let m): "Epic returned HTTP \(s)\(c.map { " \($0)" } ?? "")\(m.map { ": \($0)" } ?? "")"
        case .correctiveAction: "Epic needs you to accept updated terms."
        case .authorizationPending: "Waiting for sign-in approval."
        case .deviceCodeExpired: "The sign-in code expired."
        case .invalidCredentials(let c): "Epic rejected the saved sign-in\(c.map { " (\($0))" } ?? "")."
        case .network(let d): "Epic can’t be reached: \(d)"
        case .cancelled: "Cancelled."
        }
    }
}

/// Little-endian reader over Epic's binary formats.
struct BinaryReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data, offset: Int = 0) { self.data = Data(data); self.offset = offset }

    var remaining: Int { data.count - offset }

    mutating func seek(_ position: Int) throws {
        guard position >= 0, position <= data.count else { throw EpicError.malformed("seek to \(position) of \(data.count)") }
        offset = position
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw EpicError.malformed("read \(count) at \(offset) of \(data.count)") }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard size <= remaining else { throw EpicError.malformed("read \(T.self) at \(offset) of \(data.count)") }
        var value: T = 0
        for i in 0..<size { value |= T(truncatingIfNeeded: data[offset + i]) << (8 * i) }
        offset += size
        return value
    }

    mutating func u8() throws -> UInt8 { try integer(UInt8.self) }
    mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
    mutating func i32() throws -> Int32 { try integer(Int32.self) }
    mutating func u64() throws -> UInt64 { try integer(UInt64.self) }
    mutating func i64() throws -> Int64 { try integer(Int64.self) }
    mutating func guid() throws -> EpicGUID { EpicGUID(a: try u32(), b: try u32(), c: try u32(), d: try u32()) }

    /// Unreal FString: positive length = ASCII with NUL, negative = UTF-16LE code units with NUL.
    mutating func fstring() throws -> String {
        let length = Int(try i32())
        if length == 0 { return "" }
        if length > 0 {
            let raw = try bytes(length)
            return String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        guard length != Int(Int32.min) else { throw EpicError.malformed("FString length") }
        let raw = try bytes(-length * 2)
        var units: [UInt16] = []
        units.reserveCapacity(-length)
        for i in stride(from: 0, to: raw.count, by: 2) {
            let unit = UInt16(raw[raw.startIndex + i]) | UInt16(raw[raw.startIndex + i + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }
}

public struct EpicGUID: Hashable, Sendable, CustomStringConvertible {
    public var a, b, c, d: UInt32
    public init(a: UInt32, b: UInt32, c: UInt32, d: UInt32) { self.a = a; self.b = b; self.c = c; self.d = d }
    /// 32 uppercase hex digits, as Epic prints GUIDs and keys its `secrets` map.
    public var description: String { String(format: "%08X%08X%08X%08X", a, b, c, d) }
    public var isZero: Bool { a == 0 && b == 0 && c == 0 && d == 0 }
    /// The four words, each little-endian (the on-disk layout).
    public var littleEndianBytes: Data {
        var out = Data(capacity: 16)
        for word in [a, b, c, d] { withUnsafeBytes(of: word.littleEndian) { out.append(contentsOf: $0) } }
        return out
    }
    /// JSON manifests write GUIDs as 32 hex digits, each word big-endian.
    public init?(hex: String) {
        guard hex.count == 32 else { return nil }
        var words: [UInt32] = []
        var index = hex.startIndex
        for _ in 0..<4 {
            let next = hex.index(index, offsetBy: 8)
            guard let word = UInt32(hex[index..<next], radix: 16) else { return nil }
            words.append(word); index = next
        }
        self.init(a: words[0], b: words[1], c: words[2], d: words[3])
    }
}

enum EpicCodec {
    /// Inflates a zlib stream (2-byte header, deflate, Adler-32 trailer).
    static func inflateZlib(_ input: Data, expectedSize: Int) throws -> Data {
        var output = Data(count: max(expectedSize, 1))
        var destinationLength = uLongf(output.count)
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                uncompress(out.bindMemory(to: Bytef.self).baseAddress, &destinationLength,
                           inp.bindMemory(to: Bytef.self).baseAddress, uLong(input.count))
            }
        }
        guard status == Z_OK else { throw EpicError.malformed("zlib status \(status)") }
        output.count = Int(destinationLength)
        return output
    }

    static func deflateZlib(_ input: Data) throws -> Data {
        var output = Data(count: Int(compressBound(uLong(input.count))))
        var destinationLength = uLongf(output.count)
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                compress(out.bindMemory(to: Bytef.self).baseAddress, &destinationLength,
                         inp.bindMemory(to: Bytef.self).baseAddress, uLong(input.count))
            }
        }
        guard status == Z_OK else { throw EpicError.malformed("zlib status \(status)") }
        output.count = Int(destinationLength)
        return output
    }

    static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }

    static func aesGCMOpen(_ ciphertext: Data, key: Data, nonce: Data, tag: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch { throw EpicError.hashMismatch("AES-GCM: \(error)") }
    }

    static func hexData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte); index = next
        }
        return out
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
