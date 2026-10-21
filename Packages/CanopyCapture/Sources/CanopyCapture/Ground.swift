import Foundation
import simd

extension Mesh {
    /// An estimate of the ground height near a point (x, z), from the near-horizontal triangles within
    /// `radius`: the lower quartile of their centre heights, which ignores the trunk (vertical) and most low
    /// vegetation. Falls back to a low percentile of all vertex heights when there are no horizontal triangles.
    /// On a slope this lands between the uphill and downhill sides; see docs/ARCHITECTURE.md.
    public func groundHeight(near point: SIMD2<Float>, radius: Float = 1.0) -> Double? {
        let r2 = radius * radius
        func near(_ p: SIMD3<Float>) -> Bool {
            let dx = p.x - point.x
            let dz = p.z - point.y
            return dx * dx + dz * dz <= r2
        }
        var horizontal: [Float] = []
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let a = positions[Int(indices[t])]
            let b = positions[Int(indices[t + 1])]
            let c = positions[Int(indices[t + 2])]
            let centre = (a + b + c) / 3
            guard near(centre) else { continue }
            let normal = simd_cross(b - a, c - a)
            let length = simd_length(normal)
            guard length > 0, abs(normal.y) / length > 0.85 else { continue }
            horizontal.append(centre.y)
        }
        if !horizontal.isEmpty {
            horizontal.sort()
            return Double(horizontal[horizontal.count / 4])
        }
        let heights = positions.filter(near).map(\.y).sorted()
        guard !heights.isEmpty else { return nil }
        return Double(heights[Int(Double(heights.count - 1) * 0.02)])
    }
}
