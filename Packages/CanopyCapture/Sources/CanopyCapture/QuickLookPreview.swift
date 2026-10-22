import Foundation
import ModelIO

/// Debug previews of evidence meshes. GLB is not a Quick Look format on iOS, so this writes a throwaway USDZ
/// of the same geometry (plus normals for shading) for `QLPreviewController`. It is never stored as evidence.
public enum QuickLookPreview {
    public enum Error: Swift.Error {
        case usdzExportUnavailable
    }

    public static func usdz(for mesh: Mesh, in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        guard MDLAsset.canExportFileExtension("usdc") || MDLAsset.canExportFileExtension("usdz") else {
            throw Error.usdzExportUnavailable
        }
        let allocator = MDLMeshBufferDataAllocator()
        var vertexData = Data(capacity: mesh.vertexCount * 12)
        for p in mesh.positions {
            vertexData.appendLittleEndian(p.x.bitPattern)
            vertexData.appendLittleEndian(p.y.bitPattern)
            vertexData.appendLittleEndian(p.z.bitPattern)
        }
        var indexData = Data(capacity: mesh.indices.count * 4)
        for index in mesh.indices {
            indexData.appendLittleEndian(index)
        }
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 12)
        let submesh = MDLSubmesh(
            indexBuffer: allocator.newBuffer(with: indexData, type: .index),
            indexCount: mesh.indices.count,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil
        )
        let model = MDLMesh(
            vertexBuffer: allocator.newBuffer(with: vertexData, type: .vertex),
            vertexCount: mesh.vertexCount,
            descriptor: descriptor,
            submeshes: [submesh]
        )
        model.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
        let asset = MDLAsset()
        asset.add(model)
        let name = "canopy-preview-\(UUID().uuidString)"
        let url = directory.appending(path: name + ".usdz")
        if MDLAsset.canExportFileExtension("usdz") {
            try asset.export(to: url)
        } else {
            // Some platforms export USD but not USDZ: export the binary layer and package it ourselves.
            let layer = directory.appending(path: name + ".usdc")
            defer { try? FileManager.default.removeItem(at: layer) }
            try asset.export(to: layer)
            try USDZ.archive(fileName: "scan.usdc", contents: Data(contentsOf: layer)).write(to: url)
        }
        return url
    }
}

/// Packages a single USD layer as USDZ: an uncompressed zip whose file data starts on a 64-byte boundary.
enum USDZ {
    static func archive(fileName: String, contents: Data) -> Data {
        let name = Data(fileName.utf8)
        let crc = CRC32.checksum(contents)
        // Pad the local header with an extra field so the data starts at a multiple of 64 bytes.
        let padding = (64 - (30 + name.count + 4) % 64) % 64
        var extra = Data()
        extra.appendLittleEndian16(0x1986)
        extra.appendLittleEndian16(UInt16(padding))
        extra.append(Data(repeating: 0, count: padding))

        var out = Data()
        out.appendLittleEndian(0x0403_4B50)  // local file header
        out.appendLittleEndian16(20)  // version needed to extract
        out.appendLittleEndian16(0)  // flags
        out.appendLittleEndian16(0)  // method: stored
        out.appendLittleEndian16(0)  // time
        out.appendLittleEndian16(0x21)  // date: 1980-01-01
        out.appendLittleEndian(crc)
        out.appendLittleEndian(UInt32(contents.count))
        out.appendLittleEndian(UInt32(contents.count))
        out.appendLittleEndian16(UInt16(name.count))
        out.appendLittleEndian16(UInt16(extra.count))
        out.append(name)
        out.append(extra)
        out.append(contents)

        let centralOffset = out.count
        out.appendLittleEndian(0x0201_4B50)  // central directory header
        out.appendLittleEndian16(20)  // version made by
        out.appendLittleEndian16(20)  // version needed to extract
        out.appendLittleEndian16(0)  // flags
        out.appendLittleEndian16(0)  // method
        out.appendLittleEndian16(0)  // time
        out.appendLittleEndian16(0x21)  // date
        out.appendLittleEndian(crc)
        out.appendLittleEndian(UInt32(contents.count))
        out.appendLittleEndian(UInt32(contents.count))
        out.appendLittleEndian16(UInt16(name.count))
        out.appendLittleEndian16(0)  // extra length
        out.appendLittleEndian16(0)  // comment length
        out.appendLittleEndian16(0)  // disk
        out.appendLittleEndian16(0)  // internal attributes
        out.appendLittleEndian(0)  // external attributes
        out.appendLittleEndian(0)  // local header offset
        out.append(name)
        let centralSize = out.count - centralOffset

        out.appendLittleEndian(0x0605_4B50)  // end of central directory
        out.appendLittleEndian16(0)
        out.appendLittleEndian16(0)
        out.appendLittleEndian16(1)
        out.appendLittleEndian16(1)
        out.appendLittleEndian(UInt32(centralSize))
        out.appendLittleEndian(UInt32(centralOffset))
        out.appendLittleEndian16(0)
        return out
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendLittleEndian16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
