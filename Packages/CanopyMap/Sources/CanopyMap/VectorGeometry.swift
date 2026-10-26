import CanopyReference
import Foundation
import simd

/// Geometry remains in site ENU metres until the final SceneKit coordinate conversion.
enum VectorGeometry {
    struct Face {
        var vertices: [SIMD3<Float>]
        var triangles: [UInt32]
    }

    static func scenePoint(_ point: SIMD3<Float>, elevation: Float) -> SIMD3<Float> {
        SIMD3(point.x, point.z - elevation, -point.y)
    }

    /// Ear clipping in the polygon's own plane, for concave footprints and vertical wall/roof faces alike: a box
    /// wall whose top follows the roofline can be concave where a step meets a gable. Invalid or degenerate faces keep
    /// their outlines but get no fill.
    static func face(_ input: [SIMD3<Float>]) -> Face {
        var vertices: [SIMD3<Float>] = []
        for p in input where vertices.last != p { vertices.append(p) }
        if vertices.count > 1, vertices.first == vertices.last { vertices.removeLast() }
        guard (3...2048).contains(vertices.count),
            vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        else {
            return Face(vertices: [], triangles: [])
        }
        // Newell's normal about the centroid, so site-frame coordinates hundreds of metres out keep their precision.
        let centre = vertices.reduce(SIMD3<Float>.zero, +) / Float(vertices.count)
        let local = vertices.map { $0 - centre }
        var normal = SIMD3<Float>.zero
        for i in local.indices { normal += simd_cross(local[i], local[(i + 1) % local.count]) }
        guard simd_length(normal) > 0.0002 else { return Face(vertices: vertices, triangles: []) }
        normal = simd_normalize(normal)
        // An in-plane basis, from the world axis least like the normal: true metres in the face, so a vertical wall
        // is never squashed onto the ground plane.
        let n = simd_abs(normal)
        let axis: SIMD3<Float> = n.x <= n.y && n.x <= n.z ? [1, 0, 0] : n.y <= n.z ? [0, 1, 0] : [0, 0, 1]
        let u = simd_normalize(simd_cross(normal, axis))
        let v = simd_cross(normal, u)
        let points = local.map { SIMD2(simd_dot($0, u), simd_dot($0, v)) }
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
            let u = b - a
            let v = c - a
            return u.x * v.y - u.y * v.x
        }
        let area = points.indices.reduce(Float(0)) { sum, i in
            let a = points[i]
            let b = points[(i + 1) % points.count]
            return sum + a.x * b.y - b.x * a.y
        }
        guard abs(area) > 0.0001 else { return Face(vertices: vertices, triangles: []) }
        let sign: Float = area > 0 ? 1 : -1
        var remaining = Array(vertices.indices)
        var triangles: [UInt32] = []
        while remaining.count > 3 {
            var clipped = false
            for k in remaining.indices {
                let a = remaining[(k + remaining.count - 1) % remaining.count]
                let b = remaining[k]
                let c = remaining[(k + 1) % remaining.count]
                guard cross(points[a], points[b], points[c]) * sign > 0.0001 else { continue }
                let contains = remaining.contains { p in
                    p != a && p != b && p != c
                        && cross(points[a], points[b], points[p]) * sign >= -0.0001
                        && cross(points[b], points[c], points[p]) * sign >= -0.0001
                        && cross(points[c], points[a], points[p]) * sign >= -0.0001
                }
                guard !contains else { continue }
                triangles += [UInt32(a), UInt32(b), UInt32(c)]
                remaining.remove(at: k)
                clipped = true
                break
            }
            guard clipped else { return Face(vertices: vertices, triangles: []) }
        }
        triangles += remaining.map(UInt32.init)
        return Face(vertices: vertices, triangles: triangles)
    }

    /// `height_m` is an extrusion above each vertex, never an absolute elevation. Explicit wall and roof planes
    /// already carry their full z and must never be extruded a second time. `wallSurfaces` says the BUILDINGS layer
    /// sent `WALL_SURFACE`s: then a building part is only its base outline, and its walls are those surfaces. An older
    /// server sends none, and its parts are extruded to their `height`.
    static func faces(_ line: LineFeature, layer: ReferenceLayer, wallSurfaces: Bool = false) -> [Face] {
        var ring = line.vertices
        guard line.closed, ring.count >= 3 else { return [] }
        if ring.first == ring.last { ring.removeLast() }
        if line.kind == .buildingPart, wallSurfaces { return [Face(vertices: ring, triangles: [])] }
        let height: Float
        if line.kind == .buildingPart {
            height =
                (line.tags["height"].flatMap(Float.init) ?? line.height)
                - (line.tags["min_height"].flatMap(Float.init) ?? 0)
        } else {
            height = line.height
        }
        if layer == .footprints || line.kind == .buildingPart,
            height.isFinite, height > 0
        {
            let up = SIMD3<Float>(0, 0, height)
            return ring.indices.map { i in
                let a = ring[i]
                let b = ring[(i + 1) % ring.count]
                return face([a, b, b + up, a + up])
            }
        }
        return [face(ring)]
    }
}
