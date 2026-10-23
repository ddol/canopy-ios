import Foundation

/// Protocol Buffers wire format, just enough for the Gerardus align messages: varints, fixed 32/64-bit values,
/// length-delimited fields and packed repeated scalars. Little-endian, as the format requires.
public enum ProtobufError: Error, Equatable {
    case truncated
    case malformedVarint
    case unsupportedWireType(Int)
}

/// Builds one message.
public struct ProtoWriter: Sendable {
    public private(set) var data = Data()

    public init() {}

    mutating func key(_ field: Int, _ wireType: Int) {
        rawVarint(UInt64(field << 3 | wireType))
    }

    mutating func rawVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    /// Writes a varint field; zero is the proto3 default and is left out.
    public mutating func uint(_ field: Int, _ value: UInt64) {
        guard value != 0 else { return }
        key(field, 0)
        rawVarint(value)
    }

    public mutating func enumValue(_ field: Int, _ value: Int) {
        uint(field, UInt64(value))
    }

    public mutating func bool(_ field: Int, _ value: Bool) {
        uint(field, value ? 1 : 0)
    }

    /// Writes a double field. `always` keeps zero, for proto3 `optional` fields where presence matters.
    public mutating func double(_ field: Int, _ value: Double, always: Bool = false) {
        guard always || value != 0 else { return }
        key(field, 1)
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func float(_ field: Int, _ value: Float) {
        guard value != 0 else { return }
        key(field, 5)
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func string(_ field: Int, _ value: String) {
        guard !value.isEmpty else { return }
        bytes(field, Data(value.utf8))
    }

    public mutating func bytes(_ field: Int, _ value: Data) {
        key(field, 2)
        rawVarint(UInt64(value.count))
        data.append(value)
    }

    /// Writes an embedded message, even when it is empty (presence matters for messages).
    public mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.data)
    }

    public mutating func packedVarints(_ field: Int, _ values: [UInt64]) {
        guard !values.isEmpty else { return }
        var inner = ProtoWriter()
        for v in values { inner.rawVarint(v) }
        bytes(field, inner.data)
    }

    public mutating func packedDoubles(_ field: Int, _ values: [Double]) {
        guard !values.isEmpty else { return }
        key(field, 2)
        rawVarint(UInt64(values.count * 8))
        values.withUnsafeBytes { raw in data.append(contentsOf: raw) }
    }

    public mutating func packedFloats(_ field: Int, _ values: [Float]) {
        guard !values.isEmpty else { return }
        key(field, 2)
        rawVarint(UInt64(values.count * 4))
        values.withUnsafeBytes { raw in
            // Apple platforms are little-endian, which is the wire order.
            data.append(contentsOf: raw)
        }
    }
}

/// One field read from a message.
public struct ProtoField {
    public enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(ArraySlice<UInt8>)
    }

    public let number: Int
    public let value: Value

    public var uint: UInt64 {
        if case .varint(let v) = value { v } else { 0 }
    }

    public var int: Int { Int(truncatingIfNeeded: uint) }

    public var bool: Bool { uint != 0 }

    public var double: Double {
        if case .fixed64(let v) = value { Double(bitPattern: v) } else { 0 }
    }

    public var float: Float {
        if case .fixed32(let v) = value { Float(bitPattern: v) } else { 0 }
    }

    public var bytes: ArraySlice<UInt8> {
        if case .bytes(let b) = value { b } else { [] }
    }

    public var string: String { String(decoding: bytes, as: UTF8.self) }

    /// The field as an embedded message.
    public var message: ProtoReader { ProtoReader(bytes) }

    /// A packed (or single unpacked) repeated varint field.
    public func varints() throws -> [UInt64] {
        switch value {
        case .varint(let v): return [v]
        case .bytes(let b):
            var reader = ProtoReader(b)
            var out: [UInt64] = []
            while !reader.isAtEnd { out.append(try reader.readVarint()) }
            return out
        default: return []
        }
    }

    /// A packed (or single unpacked) repeated float field.
    public func floats() -> [Float] {
        switch value {
        case .fixed32(let v): return [Float(bitPattern: v)]
        case .bytes(let b):
            let count = b.count / 4
            return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                b.withUnsafeBytes { raw in
                    _ = memcpy(buffer.baseAddress!, raw.baseAddress!, count * 4)
                }
                initialized = count
            }
        default: return []
        }
    }

    /// A packed (or single unpacked) repeated double field.
    public func doubles() -> [Double] {
        switch value {
        case .fixed64(let v): return [Double(bitPattern: v)]
        case .bytes(let b):
            let count = b.count / 8
            return [Double](unsafeUninitializedCapacity: count) { buffer, initialized in
                b.withUnsafeBytes { raw in
                    _ = memcpy(buffer.baseAddress!, raw.baseAddress!, count * 8)
                }
                initialized = count
            }
        default: return []
        }
    }
}

/// Reads the fields of one message in order.
public struct ProtoReader: Sequence, IteratorProtocol {
    private let bytes: ArraySlice<UInt8>
    private var index: Int
    public private(set) var error: ProtobufError?

    public init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.index = bytes.startIndex
    }

    public init(_ data: Data) {
        self.init(ArraySlice([UInt8](data)))
    }

    public var isAtEnd: Bool { index >= bytes.endIndex }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.endIndex else { throw ProtobufError.truncated }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { throw ProtobufError.malformedVarint }
        }
    }

    mutating func readFixed<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard index + size <= bytes.endIndex else { throw ProtobufError.truncated }
        var value: T = 0
        for k in 0..<size {
            value |= T(bytes[index + k]) << (8 * k)
        }
        index += size
        return value
    }

    /// The next field, or nil at the end. Check `error` after iterating if the input may be malformed.
    public mutating func next() -> ProtoField? {
        guard !isAtEnd, error == nil else { return nil }
        do {
            let key = try readVarint()
            let number = Int(key >> 3)
            switch Int(key & 7) {
            case 0:
                return ProtoField(number: number, value: .varint(try readVarint()))
            case 1:
                return ProtoField(number: number, value: .fixed64(try readFixed(UInt64.self)))
            case 2:
                let length = Int(try readVarint())
                guard length >= 0, index + length <= bytes.endIndex else { throw ProtobufError.truncated }
                let slice = bytes[index..<(index + length)]
                index += length
                return ProtoField(number: number, value: .bytes(slice))
            case 5:
                return ProtoField(number: number, value: .fixed32(try readFixed(UInt32.self)))
            case let other:
                throw ProtobufError.unsupportedWireType(other)
            }
        } catch let failure as ProtobufError {
            error = failure
            return nil
        } catch {
            return nil
        }
    }

    /// Reads every field, throwing if the message is malformed.
    public static func fields(_ bytes: ArraySlice<UInt8>) throws -> [ProtoField] {
        var reader = ProtoReader(bytes)
        var out: [ProtoField] = []
        while let field = reader.next() { out.append(field) }
        if let error = reader.error { throw error }
        return out
    }
}

/// A message the client can decode.
public protocol ProtoDecodable: Sendable {
    init(fields: [ProtoField]) throws
}

extension ProtoDecodable {
    public init(serialized data: Data) throws {
        try self.init(fields: ProtoReader.fields(ArraySlice([UInt8](data))))
    }

    init(_ field: ProtoField) throws {
        try self.init(fields: ProtoReader.fields(field.bytes))
    }
}

/// A message the client can encode.
public protocol ProtoEncodable: Sendable {
    func encode(to writer: inout ProtoWriter)
}

extension ProtoEncodable {
    public var serialized: Data {
        var writer = ProtoWriter()
        encode(to: &writer)
        return writer.data
    }
}

extension ProtoWriter {
    public mutating func message(_ field: Int, _ value: some ProtoEncodable) {
        message(field) { value.encode(to: &$0) }
    }
}
