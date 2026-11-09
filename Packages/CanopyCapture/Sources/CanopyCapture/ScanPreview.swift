import CanopyModel
import CoreGraphics
import Foundation
import ImageIO
import Metal
import SceneKit
import UniformTypeIdentifiers
import simd

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// A still picture of an evidence mesh, for the lists of scans: the colourless geometry in plain grey, from a fixed
/// three-quarter view, rendered offscreen with SceneKit. It is drawn from the mesh alone, so like the mesh it holds no
/// photo. It is never stored as evidence or uploaded.
public enum ScanPreview {
    /// The picture's width and height in pixels: sharp at about 88 points on a 3× screen, where the lists show it.
    public static let pixels = 256
    /// The picture's look. Bump it when the render changes, so pictures made before are made again.
    public static let version = 1

    public enum Error: Swift.Error, Equatable {
        case emptyMesh
        case noGPU
        case renderFailed
    }

    /// Where the camera looks from: the south-east (ARKit's +x is east and +z south), 30° above the horizon. Every
    /// scan is seen from the same side, so pictures of one tree compare.
    static let viewDirection: SIMD3<Float> = {
        let azimuth: Float = .pi / 4
        let elevation: Float = .pi / 6
        return SIMD3(cos(elevation) * sin(azimuth), sin(elevation), cos(elevation) * cos(azimuth))
    }()

    /// Renders `mesh` and encodes it as PNG on a transparent background. The work happens on the calling thread, so
    /// call it off the main actor.
    public static func png(for mesh: Mesh, pixels: Int = pixels) throws -> Data {
        let image = try render(mesh, pixels: pixels)
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw Error.renderFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Error.renderFailed }
        return data as Data
    }

    /// Renders `mesh` square, `pixels` wide, with an orthographic camera fitted to it.
    static func render(_ mesh: Mesh, pixels: Int) throws -> CGImage {
        guard !mesh.isEmpty, mesh.indices.allSatisfy({ Int($0) < mesh.positions.count }) else {
            throw Error.emptyMesh
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw Error.noGPU }

        let scene = SCNScene()
        scene.background.contents = CGColor(gray: 0, alpha: 0)
        scene.rootNode.addChildNode(SCNNode(geometry: geometry(mesh)))

        // The camera's axes: `back` points from the mesh to the camera, `right` stays level.
        let back = viewDirection
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
        let up = simd_cross(back, right)
        // Fit the view to the mesh as the camera sees it, with a small margin.
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in mesh.positions {
            let q = SIMD3(simd_dot(p, right), simd_dot(p, up), simd_dot(p, back))
            low = simd_min(low, q)
            high = simd_max(high, q)
        }
        let middle = (low + high) / 2
        let extent = max(high.x - low.x, high.y - low.y, 0.01)
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(extent / 2 * 1.1)
        camera.zNear = 0.01
        camera.zFar = Double(high.z - low.z + 2)
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.simdPosition = right * middle.x + up * middle.y + back * (high.z + 1)
        cameraNode.simdOrientation = simd_quatf(simd_float3x3(columns: (right, up, back)))
        scene.rootNode.addChildNode(cameraNode)

        // A key light over the camera's left shoulder and an ambient fill, so the far side is not black.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 750
        key.simdOrientation = simd_quatf(from: SIMD3(0, 0, -1), to: simd_normalize(-back - up * 1.2 + right * 0.6))
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 300
        scene.rootNode.addChildNode(fill)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false
        let size = CGSize(width: pixels, height: pixels)
        #if targetEnvironment(simulator)
            // The simulator draws with the Mac's GPU, which on an Intel Mac is small and shared: draw less there.
            let antialiasing = SCNAntialiasingMode.none
        #else
            let antialiasing = SCNAntialiasingMode.multisampling4X
        #endif
        let snapshot = renderer.snapshot(atTime: 0, with: size, antialiasingMode: antialiasing)
        #if canImport(UIKit)
            guard let image = snapshot.cgImage else { throw Error.renderFailed }
        #else
            guard let image = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw Error.renderFailed
            }
        #endif
        return image
    }

    /// The mesh with smooth normals (each vertex's faces, weighted by area) and a matte grey material, lit on both sides.
    static func geometry(_ mesh: Mesh) -> SCNGeometry {
        var normals = [SIMD3<Float>](repeating: .zero, count: mesh.positions.count)
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let (a, b, c) = (Int(mesh.indices[t]), Int(mesh.indices[t + 1]), Int(mesh.indices[t + 2]))
            let n = simd_cross(mesh.positions[b] - mesh.positions[a], mesh.positions[c] - mesh.positions[a])
            normals[a] += n
            normals[b] += n
            normals[c] += n
        }
        let packedNormals = normals.flatMap { n -> [Float] in
            let length = simd_length(n)
            let unit = length > 0 ? n / length : SIMD3(0, 1, 0)
            return [unit.x, unit.y, unit.z]
        }
        let packedPositions = mesh.positions.flatMap { [$0.x, $0.y, $0.z] }
        func source(_ floats: [Float], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            SCNGeometrySource(
                data: floats.withUnsafeBytes { Data($0) }, semantic: semantic, vectorCount: floats.count / 3,
                usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0, dataStride: 3 * MemoryLayout<Float>.size)
        }
        let element = SCNGeometryElement(
            data: mesh.indices.withUnsafeBytes { Data($0) }, primitiveType: .triangles,
            primitiveCount: mesh.triangleCount, bytesPerIndex: MemoryLayout<UInt32>.size)
        let geometry = SCNGeometry(
            sources: [source(packedPositions, .vertex), source(packedNormals, .normal)], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = CGColor(gray: 0.8, alpha: 1)
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}

/// Scan previews kept on disk under their blob's hash, so each mesh is rendered once. Renders run one at a time, off
/// the main actor; a preview already on disk is found without waiting for them.
public actor ScanPreviewCache {
    public nonisolated let directory: URL
    /// The pictures' width and height in pixels.
    public nonisolated let pixels: Int

    public init(directory: URL, pixels: Int = ScanPreview.pixels) {
        self.directory = directory
        self.pixels = pixels
    }

    /// The cache in the app's Caches folder. The system may empty it when space runs low; a preview it removes is
    /// rendered again from the mesh.
    public static func inCaches() throws -> ScanPreviewCache {
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return ScanPreviewCache(directory: caches.appending(path: "ScanPreviews", directoryHint: .isDirectory))
    }

    /// A cache of its own in the temporary folder, for tests and in-memory stores. Tests draw small pictures.
    public static func temporary(pixels: Int = ScanPreview.pixels) -> ScanPreviewCache {
        ScanPreviewCache(
            directory: FileManager.default.temporaryDirectory.appending(
                path: "canopy-previews-\(UUID().uuidString)", directoryHint: .isDirectory),
            pixels: pixels)
    }

    /// Where the preview of `ref` is kept: one folder per `ScanPreview.version`, one PNG per blob hash.
    public nonisolated func url(for ref: BlobRef) -> URL {
        directory.appending(path: "v\(ScanPreview.version)", directoryHint: .isDirectory)
            .appending(path: ref.rawValue + ".png", directoryHint: .notDirectory)
    }

    /// The preview of `ref`, if it has been rendered.
    public nonisolated func cached(_ ref: BlobRef) -> URL? {
        let url = url(for: ref)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The preview of `ref`, rendered from `glb` (the blob's bytes, read only when there is no preview yet) the first
    /// time it is asked for.
    public func preview(for ref: BlobRef, glb: @Sendable () throws -> Data) throws -> URL {
        if let cached = cached(ref) { return cached }
        let png = try ScanPreview.png(for: try GLB.File(try glb()).mesh(), pixels: pixels)
        let url = url(for: ref)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
        return url
    }

    /// Deletes every preview, as when the app's data is reset.
    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
