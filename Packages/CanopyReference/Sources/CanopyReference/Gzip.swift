import Compression
import Foundation

/// gzip (RFC 1952), the compression gRPC servers offer: a short header, raw DEFLATE (which the Compression framework's
/// `COMPRESSION_ZLIB` reads and writes), then the CRC-32 and length of what was compressed.
public enum Gzip {
    public enum Failure: Error, Equatable {
        case notGzip
        case truncated
        case corrupt
    }

    /// The largest message decompressed: a server's messages are at most 4 MiB, and points compress to about half.
    static let limit = 64 << 20

    public static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw Failure.notGzip }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard offset + 2 <= bytes.count else { throw Failure.truncated }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT: zero-terminated
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC
        guard offset <= bytes.count - 8 else { throw Failure.truncated }
        let trailer = bytes.count - 8
        let crc =
            UInt32(bytes[trailer]) | UInt32(bytes[trailer + 1]) << 8 | UInt32(bytes[trailer + 2]) << 16
            | UInt32(bytes[trailer + 3]) << 24
        let size =
            Int(bytes[trailer + 4]) | Int(bytes[trailer + 5]) << 8 | Int(bytes[trailer + 6]) << 16
            | Int(bytes[trailer + 7]) << 24
        guard size <= limit else { throw Failure.corrupt }
        guard size > 0 else { return Data() }
        var out = [UInt8](repeating: 0, count: size)
        let written = bytes[offset..<trailer].withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(
                    destination.baseAddress!, size, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size, crc32(out) == crc else { throw Failure.corrupt }
        return Data(out)
    }

    public static func compress(_ data: Data) -> Data {
        let input = [UInt8](data)
        var deflated = [UInt8](repeating: 0, count: input.count + input.count / 16 + 64)
        let written =
            input.isEmpty
            ? 0
            : input.withUnsafeBufferPointer { source in
                deflated.withUnsafeMutableBufferPointer { destination in
                    compression_encode_buffer(
                        destination.baseAddress!, destination.count, source.baseAddress!, source.count, nil,
                        COMPRESSION_ZLIB)
                }
            }
        var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
        // An empty raw DEFLATE stream is one empty final block.
        out.append(contentsOf: written > 0 ? deflated[0..<written] : [0x03, 0x00])
        for value in [crc32(input), UInt32(truncatingIfNeeded: input.count)] {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
