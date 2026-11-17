import CanopyCapture
import SceneKit
import UIKit
import simd

/// Aerial lidar points as one SceneKit point cloud: each point a few pixels across, coloured by what the survey says it
/// hit (ground, vegetation, building), so the vectors and trees can be set against it.
enum AerialPointsNode {
    /// The colour of a point of LAS class `kind`; by its height above the ground when the survey gave no class.
    static func color(class kind: UInt8?, height: Float) -> SIMD4<Float> {
        switch kind {
        case 2: SIMD4(0.58, 0.49, 0.37, 1)  // ground
        case 3: SIMD4(0.62, 0.78, 0.36, 1)  // low vegetation
        case 4: SIMD4(0.42, 0.68, 0.28, 1)  // medium vegetation
        case 5: SIMD4(0.22, 0.52, 0.2, 1)  // high vegetation
        case 6: SIMD4(0.55, 0.6, 0.72, 1)  // building
        case 9: SIMD4(0.35, 0.55, 0.85, 1)  // water
        case nil:
            // Unclassified: from brown on the ground to dark green 30 m up.
            simd_mix(
                SIMD4(0.58, 0.49, 0.37, 1), SIMD4(0.22, 0.52, 0.2, 1), SIMD4(repeating: min(max(height / 30, 0), 1)))
        default: SIMD4(0.6, 0.6, 0.6, 1)
        }
    }

    /// The scene positions and colours of `cloud`'s points: each placed by `place` (site frame to scene), its colour
    /// by its class, or by its height above `ground` (scene y) when it has none.
    static func vertices(
        _ cloud: MapLayers.AerialPoints.Cloud, ground: Float, place: (SIMD3<Float>) -> SIMD3<Float>
    ) -> (positions: [SIMD3<Float>], colors: [SIMD4<Float>]) {
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
        positions.reserveCapacity(cloud.points.count)
        colors.reserveCapacity(cloud.points.count)
        let classed = cloud.classes.count == cloud.points.count
        for (i, point) in cloud.points.enumerated() {
            let p = place(point)
            positions.append(p)
            colors.append(color(class: classed ? cloud.classes[i] : nil, height: p.y - ground))
        }
        return (positions, colors)
    }

    /// One node drawing every point given, `size` pixels across.
    static func node(positions: [SIMD3<Float>], colors: [SIMD4<Float>], size: CGFloat = 3) -> SCNNode {
        guard !positions.isEmpty, colors.count == positions.count else { return SCNNode() }
        let vertices = positions.map { SCNVector3($0) }
        let source = SCNGeometrySource(vertices: vertices)
        let colorData = colors.withUnsafeBytes { Data($0) }
        let colorSource = SCNGeometrySource(
            data: colorData, semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
            componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let indices = (0..<UInt32(positions.count)).map { $0 }
        let element = SCNGeometryElement(
            data: indices.withUnsafeBytes { Data($0) }, primitiveType: .point, primitiveCount: positions.count,
            bytesPerIndex: 4)
        element.pointSize = size
        element.minimumPointScreenSpaceRadius = size / 2
        element.maximumPointScreenSpaceRadius = size
        let geometry = SCNGeometry(sources: [source, colorSource], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white
        material.lightingModel = .constant
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }
}
