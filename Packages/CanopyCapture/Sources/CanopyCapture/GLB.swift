import Foundation

/// Writes and reads binary glTF 2.0 (GLB) files holding a single mesh with positions and indices only.
///
/// The output is deterministic (sorted JSON keys, fixed layout), so the same mesh always has the same SHA-256.
public enum GLB {
    public static let magic: UInt32 = 0x4654_6C67  // "glTF"
    public static let version: UInt32 = 2
    static let jsonChunk: UInt32 = 0x4E4F_534A  // "JSON"
    static let binChunk: UInt32 = 0x004E_4942  // "BIN\0"
    static let arrayBuffer = 34962
    static let elementArrayBuffer = 34963
    static let float = 5126
    static let unsignedInt = 5125
    static let triangles = 4

    public enum Error: Swift.Error, Equatable {
        case emptyMesh
        case indexOutOfRange
        case notGLB
        case unsupported(String)
        case truncated
    }

    /// Encodes a mesh as GLB.
    public static func data(for mesh: Mesh) throws -> Data {
        guard !mesh.isEmpty, mesh.indices.count % 3 == 0 else { throw Error.emptyMesh }
        guard mesh.indices.allSatisfy({ Int($0) < mesh.positions.count }) else { throw Error.indexOutOfRange }
        let bounds = mesh.bounds!

        var bin = Data()
        bin.reserveCapacity(mesh.positions.count * 12 + mesh.indices.count * 4)
        for p in mesh.positions {
            bin.appendLittleEndian(p.x.bitPattern)
            bin.appendLittleEndian(p.y.bitPattern)
            bin.appendLittleEndian(p.z.bitPattern)
        }
        let positionBytes = bin.count
        for index in mesh.indices {
            bin.appendLittleEndian(index)
        }
        let indexBytes = bin.count - positionBytes
        bin.pad(to: 4, with: 0)

        let document = Document(
            asset: .init(version: "2.0", generator: "Canopy"),
            scene: 0,
            scenes: [.init(nodes: [0])],
            nodes: [.init(mesh: 0)],
            meshes: [.init(primitives: [.init(attributes: ["POSITION": 0], indices: 1, mode: triangles)])],
            buffers: [.init(byteLength: bin.count)],
            bufferViews: [
                .init(buffer: 0, byteOffset: 0, byteLength: positionBytes, target: arrayBuffer),
                .init(buffer: 0, byteOffset: positionBytes, byteLength: indexBytes, target: elementArrayBuffer),
            ],
            accessors: [
                .init(
                    bufferView: 0, componentType: float, count: mesh.positions.count, type: "VEC3",
                    min: [bounds.min.x, bounds.min.y, bounds.min.z].map(Double.init),
                    max: [bounds.max.x, bounds.max.y, bounds.max.z].map(Double.init)),
                .init(bufferView: 1, componentType: unsignedInt, count: mesh.indices.count, type: "SCALAR"),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var json = try encoder.encode(document)
        json.pad(to: 4, with: 0x20)

        var out = Data()
        out.appendLittleEndian(magic)
        out.appendLittleEndian(version)
        out.appendLittleEndian(UInt32(12 + 8 + json.count + 8 + bin.count))
        out.appendLittleEndian(UInt32(json.count))
        out.appendLittleEndian(jsonChunk)
        out.append(json)
        out.appendLittleEndian(UInt32(bin.count))
        out.appendLittleEndian(binChunk)
        out.append(bin)
        return out
    }

    /// A parsed GLB file.
    public struct File: Sendable {
        public let version: UInt32
        public let length: UInt32
        public let json: Data
        public let bin: Data
        public let document: Document

        public init(_ data: Data) throws {
            let bytes = [UInt8](data)
            guard bytes.count >= 20 else { throw Error.truncated }
            guard bytes.readUInt32(at: 0) == magic else { throw Error.notGLB }
            version = bytes.readUInt32(at: 4)
            length = bytes.readUInt32(at: 8)
            guard version == GLB.version else { throw Error.unsupported("version \(version)") }
            guard Int(length) == bytes.count else { throw Error.truncated }
            let jsonLength = Int(bytes.readUInt32(at: 12))
            guard bytes.readUInt32(at: 16) == jsonChunk, 20 + jsonLength + 8 <= bytes.count else {
                throw Error.truncated
            }
            json = Data(bytes[20..<(20 + jsonLength)])
            let binHeader = 20 + jsonLength
            let binLength = Int(bytes.readUInt32(at: binHeader))
            guard bytes.readUInt32(at: binHeader + 4) == binChunk, binHeader + 8 + binLength <= bytes.count else {
                throw Error.truncated
            }
            bin = Data(bytes[(binHeader + 8)..<(binHeader + 8 + binLength)])
            document = try JSONDecoder().decode(Document.self, from: json)
        }

        /// Reads the mesh back out of the buffer.
        public func mesh() throws -> Mesh {
            guard let primitive = document.meshes.first?.primitives.first,
                let positionIndex = primitive.attributes["POSITION"], let indicesIndex = primitive.indices
            else { throw Error.unsupported("no indexed POSITION primitive") }
            let bytes = [UInt8](bin)
            let positionAccessor = document.accessors[positionIndex]
            let indexAccessor = document.accessors[indicesIndex]
            guard positionAccessor.componentType == float, positionAccessor.type == "VEC3",
                indexAccessor.componentType == unsignedInt, indexAccessor.type == "SCALAR"
            else { throw Error.unsupported("component types") }
            let positionView = document.bufferViews[positionAccessor.bufferView]
            let indexView = document.bufferViews[indexAccessor.bufferView]
            guard positionView.byteOffset + positionAccessor.count * 12 <= bytes.count,
                indexView.byteOffset + indexAccessor.count * 4 <= bytes.count
            else { throw Error.truncated }
            let positions = (0..<positionAccessor.count).map { i in
                let base = positionView.byteOffset + i * 12
                return SIMD3(
                    Float(bitPattern: bytes.readUInt32(at: base)),
                    Float(bitPattern: bytes.readUInt32(at: base + 4)),
                    Float(bitPattern: bytes.readUInt32(at: base + 8)))
            }
            let indices = (0..<indexAccessor.count).map { bytes.readUInt32(at: indexView.byteOffset + $0 * 4) }
            return Mesh(positions: positions, indices: indices)
        }
    }

    /// The glTF JSON document, limited to what Canopy writes.
    public struct Document: Codable, Equatable, Sendable {
        public struct Asset: Codable, Equatable, Sendable {
            public var version: String
            public var generator: String?
        }

        public struct Scene: Codable, Equatable, Sendable {
            public var nodes: [Int]
        }

        public struct Node: Codable, Equatable, Sendable {
            public var mesh: Int?
        }

        public struct MeshEntry: Codable, Equatable, Sendable {
            public var primitives: [Primitive]
        }

        public struct Primitive: Codable, Equatable, Sendable {
            public var attributes: [String: Int]
            public var indices: Int?
            public var mode: Int?
        }

        public struct Buffer: Codable, Equatable, Sendable {
            public var byteLength: Int
        }

        public struct BufferView: Codable, Equatable, Sendable {
            public var buffer: Int
            public var byteOffset: Int
            public var byteLength: Int
            public var target: Int?
        }

        public struct Accessor: Codable, Equatable, Sendable {
            public var bufferView: Int
            public var componentType: Int
            public var count: Int
            public var type: String
            public var min: [Double]?
            public var max: [Double]?
        }

        public var asset: Asset
        public var scene: Int?
        public var scenes: [Scene]
        public var nodes: [Node]
        public var meshes: [MeshEntry]
        public var buffers: [Buffer]
        public var bufferViews: [BufferView]
        public var accessors: [Accessor]
    }
}

extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func pad(to alignment: Int, with byte: UInt8) {
        while count % alignment != 0 {
            append(byte)
        }
    }
}

extension [UInt8] {
    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
