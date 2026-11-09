import Foundation
import Testing

@testable import CanopyCapture

@Suite struct GLBTests {
    let mesh = Mesh(
        positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1.5)],
        indices: [0, 1, 2, 0, 2, 3]
    )

    @Test func headerAndChunkSizes() throws {
        let data = try GLB.data(for: mesh)
        let bytes = [UInt8](data)
        #expect(bytes.readUInt32(at: 0) == GLB.magic)
        #expect(Array(bytes[0..<4]) == Array("glTF".utf8))
        #expect(bytes.readUInt32(at: 4) == 2)
        #expect(Int(bytes.readUInt32(at: 8)) == data.count)

        let jsonLength = Int(bytes.readUInt32(at: 12))
        #expect(Array(bytes[16..<20]) == Array("JSON".utf8))
        #expect(jsonLength % 4 == 0)
        let binHeader = 20 + jsonLength
        let binLength = Int(bytes.readUInt32(at: binHeader))
        #expect(Array(bytes[(binHeader + 4)..<(binHeader + 8)]) == [0x42, 0x49, 0x4E, 0x00])
        #expect(binLength % 4 == 0)
        #expect(binLength == 4 * 12 + 6 * 4)
        #expect(data.count == 12 + 8 + jsonLength + 8 + binLength)
    }

    @Test func roundTrips() throws {
        let file = try GLB.File(try GLB.data(for: mesh))
        #expect(file.version == 2)
        #expect(try file.mesh() == mesh)
        let accessors = file.document.accessors
        #expect(accessors.map(\.count) == [4, 6])
        #expect(accessors[0].min == [0, 0, -1.5])
        #expect(accessors[0].max == [1, 1, 0])
        #expect(file.document.buffers.first?.byteLength == file.bin.count)
        #expect(file.document.bufferViews.map(\.byteLength) == [48, 24])
        #expect(file.document.meshes.first?.primitives.first?.mode == 4)
    }

    @Test func holdsGeometryOnly() throws {
        let json = try String(decoding: GLB.File(GLB.data(for: mesh)).json, as: UTF8.self)
        for forbidden in ["images", "textures", "materials", "COLOR_0", "TEXCOORD_0", "NORMAL", "uri"] {
            #expect(!json.contains(forbidden), "\(forbidden)")
        }
    }

    @Test func isDeterministic() throws {
        #expect(try GLB.data(for: mesh) == GLB.data(for: mesh))
    }

    @Test func roundTripsALargeScan() throws {
        let scan = Synthetic.scannedTrunk(radius: 0.3, leanDegrees: 2)
        let data = try GLB.data(for: scan)
        let back = try GLB.File(data).mesh()
        #expect(back == scan)
        #expect(
            data.count == 12 + 8 + (try GLB.File(data)).json.count + 8 + scan.vertexCount * 12 + scan.indices.count * 4)
    }

    @Test func rejectsBadInput() throws {
        #expect(throws: GLB.Error.emptyMesh) { try GLB.data(for: .empty) }
        #expect(throws: GLB.Error.indexOutOfRange) {
            try GLB.data(for: Mesh(positions: [.zero, .zero, .zero], indices: [0, 1, 3]))
        }
        let data = try GLB.data(for: mesh)
        #expect(throws: GLB.Error.truncated) { try GLB.File(data.prefix(data.count - 4)) }
        var notGLB = data
        notGLB[0] = 0x00
        #expect(throws: GLB.Error.notGLB) { try GLB.File(notGLB) }
    }

    /// A scan from another device is read before anything indexes into it, so a file that points outside itself is
    /// refused rather than read.
    @Test func refusesAMeshThatPointsOutsideItself() throws {
        // A triangle corner past the last vertex.
        var bytes = [UInt8](try GLB.data(for: mesh))
        let binStart = 20 + Int(bytes.readUInt32(at: 12)) + 8
        bytes[binStart + 4 * 12 + 5 * 4] = 99
        #expect(throws: GLB.Error.indexOutOfRange) { try GLB.File(Data(bytes)).mesh() }

        // A document naming what is not there, or bytes outside its buffer.
        let file = try GLB.File(GLB.data(for: mesh))
        func refused(_ change: (inout GLB.Document) -> Void) throws -> GLB.Error? {
            var document = file.document
            change(&document)
            let json = try JSONEncoder().encode(document)
            do {
                _ = try GLB.File(Self.glb(json: json, bin: file.bin)).mesh()
                return nil
            } catch let error as GLB.Error {
                return error
            }
        }
        #expect(try refused { _ in } == nil)
        #expect(try refused { $0.meshes[0].primitives[0].attributes["POSITION"] = 7 } == .indexOutOfRange)
        #expect(try refused { $0.accessors[1].bufferView = 5 } == .indexOutOfRange)
        #expect(try refused { $0.accessors[0].count = -1 } == .truncated)
        #expect(try refused { $0.accessors[1].count = .max / 2 } == .truncated)
        #expect(try refused { $0.bufferViews[1].byteOffset = -8 } == .truncated)
        #expect(try refused { $0.bufferViews[0].byteOffset = 1 << 40 } == .truncated)
    }

    /// A GLB of the given chunks, as another writer might lay one out.
    static func glb(json: Data, bin: Data) -> Data {
        var json = json
        json.pad(to: 4, with: 0x20)
        var bin = bin
        bin.pad(to: 4, with: 0)
        var out = Data()
        out.appendLittleEndian(GLB.magic)
        out.appendLittleEndian(GLB.version)
        out.appendLittleEndian(UInt32(12 + 8 + json.count + 8 + bin.count))
        out.appendLittleEndian(UInt32(json.count))
        out.appendLittleEndian(GLB.jsonChunk)
        out.append(json)
        out.appendLittleEndian(UInt32(bin.count))
        out.appendLittleEndian(GLB.binChunk)
        out.append(bin)
        return out
    }
}
