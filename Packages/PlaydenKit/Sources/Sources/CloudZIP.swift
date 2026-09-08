import Foundation
import Compression

/// Steam's compressed Cloud payload is one ZIP entry. Parse offsets before decompression, bound
/// output by the verified remote size, and ignore the entry name (never extract it to disk).
enum CloudZIP {
    static func extract(_ data: Data, expectedBytes: Int) throws -> Data {
        guard expectedBytes >= 0, expectedBytes <= SteamCloudResponse.maximumFileBytes, data.count >= 22 else { throw invalid() }
        let bytes = [UInt8](data)
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= bytes.count - 2 else { throw invalid() }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int { try u16(offset) | u16(offset + 2) << 16 }
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65535), by: -1) {
            if try u32(offset) == 0x06054b50, try offset + 22 + u16(offset + 20) == bytes.count { end = offset; break }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0,
              try u16(end + 8) == 1, try u16(end + 10) == 1 else { throw invalid() }
        let central = try u32(end + 16), centralSize = try u32(end + 12)
        guard centralSize >= 46, central + centralSize == end, try u32(central) == 0x02014b50,
              try u32(central + 24) == expectedBytes, try u16(central + 34) == 0,
              try 46 + u16(central + 28) + u16(central + 30) + u16(central + 32) == centralSize else { throw invalid() }
        let flags = try u16(central + 8), method = try u16(central + 10)
        guard flags & 1 == 0, [0, 8].contains(method) else { throw invalid() }
        let size = try u32(central + 20), local = try u32(central + 42)
        guard local + 30 <= central, try u32(local) == 0x04034b50,
              try u16(local + 6) == flags, try u16(local + 8) == method else { throw invalid() }
        let start = try local + 30 + u16(local + 26) + u16(local + 28)
        guard start <= central, size <= central - start else { throw invalid() }
        let payload = data.subdata(in: start..<start + size)
        if method == 0 {
            guard payload.count == expectedBytes else { throw invalid() }; return payload
        }
        // One extra output byte detects a larger stream, even if its prefix has the expected hash.
        var output = Data(count: expectedBytes + 1)
        let written = try payload.withUnsafeBytes { input in
            try output.withUnsafeMutableBytes { destination in
                let inputBytes = input.bindMemory(to: UInt8.self)
                let outputBytes = destination.bindMemory(to: UInt8.self)
                guard let inputBase = inputBytes.baseAddress, let outputBase = outputBytes.baseAddress else { throw invalid() }
                var stream = compression_stream(dst_ptr: outputBase, dst_size: outputBytes.count,
                    src_ptr: inputBase, src_size: inputBytes.count, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else { throw invalid() }
                defer { compression_stream_destroy(&stream) }
                stream.src_ptr = inputBase; stream.src_size = inputBytes.count
                stream.dst_ptr = outputBase; stream.dst_size = outputBytes.count
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_END, stream.src_size == 0,
                      outputBytes.count - stream.dst_size == expectedBytes else { throw invalid() }
                return expectedBytes
            }
        }
        return output.prefix(written)
    }
    private static func invalid() -> Error { cloudFailure("The compressed Cloud save is invalid. Local saves have been kept.") }
}
