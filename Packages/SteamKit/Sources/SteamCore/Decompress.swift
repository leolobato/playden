import Foundation
import Compression
import CLzma
import CZstd

/// Decompression for the formats Steam uses on the wire: gzip (CM Multi
/// messages), zip/deflate (manifests, old "PK" chunks), the "VZ" container
/// (LZMA1) and the "VSZ" container (zstd) for depot chunks.
public enum Decompress {

    // MARK: raw DEFLATE (Apple's COMPRESSION_ZLIB is raw deflate, no zlib header)

    public static func inflateRaw(_ data: Data, expectedSize: Int) throws -> Data {
        var out = Data(count: max(expectedSize, 64))
        let written = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                compression_decode_buffer(
                    outPtr.bindMemory(to: UInt8.self).baseAddress!, outPtr.count,
                    inPtr.bindMemory(to: UInt8.self).baseAddress!, inPtr.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw SteamError.download("deflate: decode failed") }
        return out.prefix(written)
    }

    // MARK: gzip (CM Multi)

    public static func gunzip(_ data: Data) throws -> Data {
        let d = [UInt8](data)
        guard d.count > 18, d[0] == 0x1F, d[1] == 0x8B, d[2] == 8 else {
            throw SteamError.protocolError("gunzip: bad header")
        }
        let flags = d[3]
        var offset = 10
        if flags & 0x04 != 0 {  // FEXTRA
            let xlen = Int(d[offset]) | Int(d[offset + 1]) << 8
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 { while offset < d.count && d[offset] != 0 { offset += 1 }; offset += 1 }  // FNAME
        if flags & 0x10 != 0 { while offset < d.count && d[offset] != 0 { offset += 1 }; offset += 1 }  // FCOMMENT
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC
        guard offset < d.count - 8 else { throw SteamError.protocolError("gunzip: truncated") }
        let isize = Int(d[d.count - 4]) | Int(d[d.count - 3]) << 8 | Int(d[d.count - 2]) << 16 | Int(d[d.count - 1]) << 24
        let deflated = data.subdata(in: data.startIndex + offset..<data.endIndex - 8)
        return try inflateRaw(deflated, expectedSize: isize)
    }

    // MARK: zip archives (depot manifests are a single-entry zip)

    /// Extracts the first entry of a zip archive using the central directory.
    public static func unzipFirstEntry(_ data: Data) throws -> Data {
        let d = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        // find End Of Central Directory (PK\x05\x06), scanning back over the comment
        var eocd = -1
        var i = d.count - 22
        while i >= 0 && i >= d.count - 22 - 0xFFFF {
            if d[i] == 0x50, d[i + 1] == 0x4B, d[i + 2] == 0x05, d[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw SteamError.protocolError("zip: no EOCD") }
        let cdOffset = u32(eocd + 16)
        guard cdOffset + 46 <= d.count, u32(cdOffset) == 0x02014B50 else {
            throw SteamError.protocolError("zip: bad central directory")
        }
        let method = u16(cdOffset + 10)
        let csize = u32(cdOffset + 20)
        let usize = u32(cdOffset + 24)
        let localOffset = u32(cdOffset + 42)
        guard u32(localOffset) == 0x04034B50 else { throw SteamError.protocolError("zip: bad local header") }
        let nameLen = u16(localOffset + 26)
        let extraLen = u16(localOffset + 28)
        let dataStart = localOffset + 30 + nameLen + extraLen
        guard dataStart + csize <= d.count else { throw SteamError.protocolError("zip: truncated") }
        let payload = data.subdata(in: data.startIndex + dataStart..<data.startIndex + dataStart + csize)
        switch method {
        case 0: return payload
        case 8: return try inflateRaw(payload, expectedSize: usize)
        default: throw SteamError.protocolError("zip: unsupported method \(method)")
        }
    }

    // MARK: VZ (LZMA1) depot chunks

    /// "VZ" container: 'V' 'Z' version('a') + crc32(4) | lzma props(5) + payload |
    /// crc32(4) + decompressed size(4) + 'z' 'v'.
    public static func vzip(_ data: Data) throws -> Data {
        let d = [UInt8](data)
        guard d.count > 7 + 5 + 10, d[0] == 0x56, d[1] == 0x5A, d[2] == 0x61 else {
            throw SteamError.download("vzip: bad header magic")
        }
        guard d[d.count - 2] == 0x7A, d[d.count - 1] == 0x76 else {
            throw SteamError.download("vzip: bad footer magic")
        }
        let size = Int(d[d.count - 6]) | Int(d[d.count - 5]) << 8 | Int(d[d.count - 4]) << 16 | Int(d[d.count - 3]) << 24
        let props = Array(d[7..<12])
        let payload = Array(d[12..<(d.count - 10)])

        // LZMA_FILTER_LZMA1 — the macro is unimportable (LZMA_VLI_C structure)
        let lzmaFilterLZMA1: UInt64 = 0x4000_0000_0000_0001
        var filter = lzma_filter(id: lzmaFilterLZMA1, options: nil)
        var ret = props.withUnsafeBufferPointer { p in
            lzma_properties_decode(&filter, nil, p.baseAddress, 5)
        }
        guard ret == LZMA_OK else { throw SteamError.download("vzip: lzma props decode \(ret)") }
        defer { free(filter.options) }

        // Steam's LZMA1 streams carry no end-of-stream marker (the size comes
        // from the VZ footer), which the one-shot lzma_raw_buffer_decode rejects
        // at end of input — and on error it leaves out_pos untouched. Stream with
        // lzma_code instead and treat a full output buffer as success.
        var filters = [filter, lzma_filter(id: LZMA_VLI_UNKNOWN, options: nil)]
        var strm = lzma_stream()
        ret = filters.withUnsafeMutableBufferPointer { f in
            lzma_raw_decoder(&strm, f.baseAddress)
        }
        guard ret == LZMA_OK else { throw SteamError.download("vzip: raw decoder init \(ret)") }
        defer { lzma_end(&strm) }

        var out = [UInt8](repeating: 0, count: size)
        let (finalRet, decoded) = payload.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf -> (lzma_ret, Int) in
                strm.next_in = inBuf.baseAddress
                strm.avail_in = numericCast(payload.count)
                strm.next_out = outBuf.baseAddress
                strm.avail_out = numericCast(size)
                var r = LZMA_OK
                while r == LZMA_OK && strm.avail_out > 0 && strm.avail_in > 0 {
                    r = lzma_code(&strm, LZMA_FINISH)
                }
                return (r, size - Int(strm.avail_out))
            }
        }
        guard decoded == size,
              finalRet == LZMA_OK || finalRet == LZMA_STREAM_END || finalRet == LZMA_BUF_ERROR else {
            throw SteamError.download("vzip: lzma decode \(finalRet) (out \(decoded)/\(size))")
        }
        return Data(out)
    }

    // MARK: VSZ (zstd) depot chunks

    /// "VSZ" container: 'V' 'S' 'Z' version('a') + crc32(4) | zstd frame |
    /// crc32(4) + decompressed size(8) + 'z' 's' 'v'.
    public static func vzstd(_ data: Data) throws -> Data {
        let d = [UInt8](data)
        let headerLen = 8, footerLen = 15
        guard d.count > headerLen + footerLen,
              d[0] == 0x56, d[1] == 0x53, d[2] == 0x5A, d[3] == 0x61 else {
            throw SteamError.download("vzstd: bad header magic")
        }
        guard d[d.count - 3] == 0x7A, d[d.count - 2] == 0x73, d[d.count - 1] == 0x76 else {
            throw SteamError.download("vzstd: bad footer magic")
        }
        // The size is 64-bit here (VZ's is 32); the high half is always zero in
        // practice — a chunk never exceeds 1 MiB uncompressed.
        var size: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) {
            size = size << 8 | UInt64(d[d.count - footerLen + 4 + i])
        }
        guard size <= 64 << 20 else { throw SteamError.download("vzstd: implausible size \(size)") }
        if size == 0 { return Data() }

        let payload = Array(d[headerLen..<(d.count - footerLen)])
        var out = [UInt8](repeating: 0, count: Int(size))
        let decoded = payload.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                ZSTD_decompress(outBuf.baseAddress, outBuf.count, inBuf.baseAddress, inBuf.count)
            }
        }
        guard ZSTD_isError(decoded) == 0 else {
            let name = ZSTD_getErrorName(decoded).map { String(cString: $0) } ?? "?"
            throw SteamError.download("vzstd: zstd decode failed (\(name))")
        }
        guard decoded == Int(size) else {
            throw SteamError.download("vzstd: decoded \(decoded)/\(size) bytes")
        }
        return Data(out)
    }

    /// Dispatch on a decrypted depot chunk's magic.
    public static func depotChunk(_ data: Data) throws -> Data {
        let d = [UInt8](data.prefix(4))
        // 'VSZ' before 'VZ': both start with 'V', only the second byte differs.
        if d.count >= 3, d[0] == 0x56, d[1] == 0x53, d[2] == 0x5A { return try vzstd(data) }  // 'VSZ'
        if d.count >= 2, d[0] == 0x56, d[1] == 0x5A { return try vzip(data) }        // 'VZ'
        if d.count >= 2, d[0] == 0x50, d[1] == 0x4B { return try unzipFirstEntry(data) }  // 'PK'
        throw SteamError.download("chunk: unknown magic \(Data(d).hexString)")
    }
}
