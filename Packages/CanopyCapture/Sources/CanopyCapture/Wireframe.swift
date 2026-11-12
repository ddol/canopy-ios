import Foundation
import simd

/// Lines for RealityKit, which draws no lines of its own: each segment becomes a thin square tube in a triangle
/// mesh. Rings, polylines and the tube mesh are shared by the fitted tree and the site overlay.
public enum Wireframe {
    /// A straight line, in metres.
    public struct Segment: Equatable, Sendable {
        public var from: SIMD3<Float>
        public var to: SIMD3<Float>

        public init(from: SIMD3<Float>, to: SIMD3<Float>) {
            self.from = from
            self.to = to
        }
    }

    /// A horizontal circle (in a y-up frame) of `count` segments.
    public static func ring(centre: SIMD3<Float>, radius: Float, count: Int = 32) -> [Segment] {
        let points = (0..<count).map { i -> SIMD3<Float> in
            let angle = Float(i) / Float(count) * 2 * .pi
            return centre + SIMD3(cos(angle) * radius, 0, sin(angle) * radius)
        }
        return (0..<count).map { Segment(from: points[$0], to: points[($0 + 1) % count]) }
    }

    /// A horizontal circle drawn as `dashes` dashes with gaps as long between them, turned by `phase` (0 to 1, a
    /// dash and a gap): moving `phase` makes the dashes march round ("marching ants").
    public static func dashedRing(centre: SIMD3<Float>, radius: Float, dashes: Int, phase: Float) -> [Segment] {
        let step = 2 * Float.pi / Float(dashes)
        let offset = (phase - phase.rounded(.down)) * step
        return (0..<dashes).flatMap { i -> [Segment] in
            let start = Float(i) * step + offset
            // Each dash of a few short pieces, so it follows the circle.
            return (0..<3).map { k in
                let a = start + Float(k) / 6 * step
                let b = start + Float(k + 1) / 6 * step
                return Segment(
                    from: centre + SIMD3(cos(a) * radius, 0, sin(a) * radius),
                    to: centre + SIMD3(cos(b) * radius, 0, sin(b) * radius))
            }
        }
    }

    /// A straight line drawn as dashes `dash` metres long with gaps as long, moved along it by `phase` (0 to 1, a
    /// dash and a gap) from `from` towards `to`.
    public static func dashedLine(from: SIMD3<Float>, to: SIMD3<Float>, dash: Float, phase: Float) -> [Segment] {
        let length = simd_distance(from, to)
        guard length > 0.01, dash > 0 else { return [] }
        let direction = (to - from) / length
        var segments: [Segment] = []
        var start = ((phase - phase.rounded(.down)) - 1) * 2 * dash
        while start < length {
            let a = max(start, 0)
            let b = min(start + dash, length)
            if b > a { segments.append(Segment(from: from + direction * a, to: from + direction * b)) }
            start += 2 * dash
        }
        return segments
    }

    /// The segments along a run of points, closed back to the start when asked.
    public static func polyline(_ points: [SIMD3<Float>], closed: Bool) -> [Segment] {
        guard points.count >= 2 else { return [] }
        var segments = (1..<points.count).map { Segment(from: points[$0 - 1], to: points[$0]) }
        if closed, points.count >= 3, points.first != points.last {
            segments.append(Segment(from: points[points.count - 1], to: points[0]))
        }
        return segments
    }

    /// Each segment as a square tube of `width` with four side faces, all in one mesh. Faces are wound outwards;
    /// draw them without culling so they read from inside too. Zero-length segments are skipped.
    public static func mesh(_ segments: [Segment], width: Float) -> Mesh {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(segments.count * 8)
        indices.reserveCapacity(segments.count * 24)
        let half = width / 2
        for segment in segments {
            let direction = segment.to - segment.from
            let length = simd_length(direction)
            guard length > 1e-6 else { continue }
            let along = direction / length
            // A side vector not parallel to the segment, then two perpendiculars.
            let reference: SIMD3<Float> = abs(along.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
            let u = simd_normalize(simd_cross(along, reference)) * half
            let v = simd_normalize(simd_cross(along, u)) * half
            let corners = [u + v, u - v, -u - v, -u + v]
            let base = UInt32(positions.count)
            for corner in corners {
                positions.append(segment.from + corner)
            }
            for corner in corners {
                positions.append(segment.to + corner)
            }
            for i in 0..<4 {
                let a = base + UInt32(i)
                let b = base + UInt32((i + 1) % 4)
                let c = a + 4
                let d = b + 4
                indices += [a, b, d, a, d, c]
            }
        }
        return Mesh(positions: positions, indices: indices)
    }
}

/// An axis-aligned box in world metres that a tap selects a wireframe item by.
public struct PickBox: Equatable, Sendable {
    public var centre: SIMD3<Float>
    public var size: SIMD3<Float>

    public init(centre: SIMD3<Float>, size: SIMD3<Float>) {
        self.centre = centre
        self.size = size
    }
}

/// One thing drawn in a wireframe layer: a tree, a building, a street line. With a `pickBox` a tap can select it.
public struct WireframeItem: Equatable, Sendable {
    public var id: String
    public var segments: [Wireframe.Segment]
    public var pickBox: PickBox?

    public init(id: String, segments: [Wireframe.Segment], pickBox: PickBox? = nil) {
        self.id = id
        self.segments = segments
        self.pickBox = pickBox
    }
}

/// A named set of wireframe items drawn in one colour. Showing a layer again replaces it.
public struct WireframeLayer: Equatable, Sendable {
    public var name: String
    public var items: [WireframeItem]
    /// Red, green, blue and alpha, 0 to 1.
    public var color: SIMD4<Float>
    public var lineWidth: Float
    /// Drawn through the reconstructed mesh and whatever is in front, as the fitted tree is; otherwise the mesh
    /// and nearer wireframes hide it, which keeps a whole site readable.
    public var throughWalls: Bool

    public init(
        name: String, items: [WireframeItem], color: SIMD4<Float>, lineWidth: Float = 0.012, throughWalls: Bool = false
    ) {
        self.name = name
        self.items = items
        self.color = color
        self.lineWidth = lineWidth
        self.throughWalls = throughWalls
    }

    public var isEmpty: Bool { items.allSatisfy(\.segments.isEmpty) }
}
