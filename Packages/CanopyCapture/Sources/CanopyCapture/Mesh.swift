import Foundation
import simd

/// A colourless triangle mesh: vertex positions in metres and triangle indices. Nothing else, by design:
/// no normals, colours, textures or images.
///
/// Coordinates follow ARKit and glTF: right-handed, y up.
public struct Mesh: Equatable, Sendable {
    public var positions: [SIMD3<Float>]
    /// Three indices per triangle, counter-clockwise.
    public var indices: [UInt32]

    public init(positions: [SIMD3<Float>], indices: [UInt32]) {
        self.positions = positions
        self.indices = indices
    }

    public static let empty = Mesh(positions: [], indices: [])

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { indices.isEmpty }

    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard var low = positions.first else { return nil }
        var high = low
        for p in positions {
            low = simd_min(low, p)
            high = simd_max(high, p)
        }
        return (low, high)
    }

    /// Appends another mesh, offsetting its indices.
    public mutating func append(_ other: Mesh) {
        let offset = UInt32(positions.count)
        positions += other.positions
        indices += other.indices.map { $0 + offset }
    }

    /// The triangles inside a vertical cylinder around `center` (all three corners within `radius` horizontally
    /// and between `below` and `above` metres of `center` vertically), re-indexed and moved so `center` is the
    /// origin. This is how evidence is cropped to its subject.
    public func cropped(around center: SIMD3<Float>, radius: Float, below: Float, above: Float) -> Mesh {
        let r2 = radius * radius
        func keep(_ p: SIMD3<Float>) -> Bool {
            let d = p - center
            return d.x * d.x + d.z * d.z <= r2 && d.y >= -below && d.y <= above
        }
        var remap = [Int32](repeating: -1, count: positions.count)
        var result = Mesh.empty
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let corners = (Int(indices[t]), Int(indices[t + 1]), Int(indices[t + 2]))
            guard keep(positions[corners.0]), keep(positions[corners.1]), keep(positions[corners.2]) else { continue }
            for index in [corners.0, corners.1, corners.2] {
                if remap[index] < 0 {
                    remap[index] = Int32(result.positions.count)
                    result.positions.append(positions[index] - center)
                }
                result.indices.append(UInt32(remap[index]))
            }
        }
        return result
    }

    /// Where the mesh crosses the horizontal plane at height `y`, as (x, z) points: one per triangle edge that
    /// crosses it.
    public func slice(atHeight y: Float) -> [SIMD2<Double>] {
        var seen = Set<UInt64>()
        var points: [SIMD2<Double>] = []
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let triangle = [indices[t], indices[t + 1], indices[t + 2]]
            for (a, b) in [(triangle[0], triangle[1]), (triangle[1], triangle[2]), (triangle[2], triangle[0])] {
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let p = positions[Int(a)]
                let q = positions[Int(b)]
                guard (p.y - y) * (q.y - y) < 0 else { continue }
                let s = (y - p.y) / (q.y - p.y)
                let hit = p + (q - p) * s
                points.append(SIMD2(Double(hit.x), Double(hit.z)))
            }
        }
        return points
    }
}
