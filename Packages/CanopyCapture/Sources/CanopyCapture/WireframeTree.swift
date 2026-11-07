import CanopyModel
import Foundation
import simd

/// The shape of a tree as the player eyeballs it against the real one in AR: a trunk and a crown, each a
/// cylinder. The same figure the Mac visualiser draws for a TREE feature (a trunk line to the crown's base, a
/// ring of the crown's radius at its base and at its top), with the trunk's diameter added.
public struct TreeForm: Equatable, Sendable {
    /// Trunk diameter, in metres.
    public var trunkDiameter: Double
    /// Height of the top of the crown above the ground, in metres.
    public var height: Double
    /// Height of the crown (foliage) from its base to the top of the tree, in metres.
    public var crownHeight: Double
    /// Width (diameter) of the crown, in metres.
    public var crownWidth: Double

    public static let trunkDiameters = 0.03...2.5
    public static let heights = 1.0...45.0
    public static let crownWidths = 0.2...35.0

    public init(trunkDiameter: Double, height: Double, crownHeight: Double, crownWidth: Double) {
        self.trunkDiameter = trunkDiameter
        self.height = height
        self.crownHeight = crownHeight
        self.crownWidth = crownWidth
    }

    /// A starting point from a trunk measurement: a tree about 25 trunk diameters tall, the crown its upper
    /// two thirds and about as wide as it is tall. The player adjusts from here.
    public init(dbh: DBH) {
        let diameter = min(max(dbh.diameter.value, Self.trunkDiameters.lowerBound), Self.trunkDiameters.upperBound)
        let height = min(max(diameter * 25, 3), Self.heights.upperBound)
        self.init(
            trunkDiameter: diameter, height: height, crownHeight: height * 2 / 3,
            crownWidth: min(max(height * 0.6, Self.crownWidths.lowerBound), Self.crownWidths.upperBound))
    }

    /// Height of the crown's base above the ground, in metres.
    public var crownBase: Double { height - crownHeight }

    /// The same form with every dimension inside its range, the crown no taller than the tree and no thinner
    /// than the trunk.
    public var clamped: TreeForm {
        var form = self
        form.trunkDiameter = min(max(trunkDiameter, Self.trunkDiameters.lowerBound), Self.trunkDiameters.upperBound)
        form.height = min(max(height, Self.heights.lowerBound), Self.heights.upperBound)
        form.crownHeight = min(max(crownHeight, 0), form.height)
        form.crownWidth = min(
            max(crownWidth, form.trunkDiameter, Self.crownWidths.lowerBound), Self.crownWidths.upperBound)
        return form
    }
}

/// Builds the wireframe of a `TreeForm` as triangle meshes RealityKit can draw: the frame has its origin at the
/// trunk's base on the ground, y up, and every line is a thin square tube so it has width on screen (RealityKit
/// draws no lines of its own).
public enum WireframeTree {
    /// A straight line of the wireframe, in metres from the trunk's base.
    public struct Segment: Equatable, Sendable {
        public var from: SIMD3<Float>
        public var to: SIMD3<Float>

        public init(from: SIMD3<Float>, to: SIMD3<Float>) {
            self.from = from
            self.to = to
        }
    }

    /// The trunk's lines and the crown's, kept apart so they can be coloured apart.
    public struct Figure: Equatable, Sendable {
        public var trunk: [Segment]
        public var crown: [Segment]
    }

    /// Points around each ring.
    public static let ringSegments = 32
    /// Uprights along the trunk and the crown.
    public static let uprights = 8
    /// Width of each line's tube, in metres.
    public static let lineWidth: Float = 0.012

    /// The lines of a tree: rings of the trunk's diameter at the ground, at breast height (where the DBH was
    /// measured) and at the crown's base, joined by uprights; and rings of the crown's width at its base and
    /// its top, joined by uprights. A lean tilts the trunk and carries the crown with it, as the Mac visualiser
    /// centres the crown over the trunk's top.
    public static func figure(_ form: TreeForm, lean: Lean? = nil) -> Figure {
        let form = form.clamped
        let tilt = Self.tilt(lean)
        func axis(_ height: Double) -> SIMD3<Float> {
            let h = Float(height)
            return SIMD3(tilt.x * h, h, tilt.z * h)
        }

        var trunk: [Segment] = []
        let trunkRadius = Float(form.trunkDiameter / 2)
        var trunkHeights = [0, form.crownBase]
        if form.crownBase > DBH.standardHeight {
            trunkHeights.insert(DBH.standardHeight, at: 1)
        }
        for height in trunkHeights {
            trunk += ring(centre: axis(height), radius: trunkRadius)
        }
        trunk += uprights(from: axis(0), to: axis(form.crownBase), radius: trunkRadius)

        var crown: [Segment] = []
        let crownRadius = Float(form.crownWidth / 2)
        let base = axis(form.crownBase)
        let top = axis(form.height)
        crown += ring(centre: base, radius: crownRadius)
        crown += ring(centre: top, radius: crownRadius)
        crown += uprights(from: base, to: top, radius: crownRadius)
        return Figure(trunk: trunk, crown: crown)
    }

    /// The horizontal offset per metre of height of a leaning trunk, in the ARKit frame (+x east, −z north)
    /// when the lean has a direction; a lean without one tilts nothing.
    static func tilt(_ lean: Lean?) -> SIMD3<Float> {
        guard let lean, let azimuth = lean.azimuth, lean.angle.value > 0 else { return .zero }
        let slope = Float(tan(min(lean.angle.value, 45) * .pi / 180))
        let radians = Float(azimuth.value * .pi / 180)
        return SIMD3(sin(radians) * slope, 0, -cos(radians) * slope)
    }

    static func ring(centre: SIMD3<Float>, radius: Float) -> [Segment] {
        let points = (0..<ringSegments).map { i -> SIMD3<Float> in
            let angle = Float(i) / Float(ringSegments) * 2 * .pi
            return centre + SIMD3(cos(angle) * radius, 0, sin(angle) * radius)
        }
        return (0..<ringSegments).map { Segment(from: points[$0], to: points[($0 + 1) % ringSegments]) }
    }

    static func uprights(from bottom: SIMD3<Float>, to top: SIMD3<Float>, radius: Float) -> [Segment] {
        (0..<uprights).map { i in
            let angle = Float(i) / Float(uprights) * 2 * .pi
            let offset = SIMD3(cos(angle) * radius, 0, sin(angle) * radius)
            return Segment(from: bottom + offset, to: top + offset)
        }
    }

    /// Each segment as a square tube of `width` with four side faces, all in one mesh. Faces are wound
    /// outwards; draw them without culling so they read from inside the crown too.
    public static func mesh(_ segments: [Segment], width: Float = lineWidth) -> Mesh {
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
