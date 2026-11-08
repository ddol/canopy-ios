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

/// The wireframe of a `TreeForm`: the frame has its origin at the trunk's base on the ground, y up.
public enum WireframeTree {
    public typealias Segment = Wireframe.Segment

    /// The trunk's lines and the crown's, kept apart so they can be coloured apart.
    public struct Figure: Equatable, Sendable {
        public var trunk: [Segment]
        public var crown: [Segment]
        /// The ring picked out for editing, when a profile is drawn with one.
        public var highlighted: [Segment] = []

        public var all: [Segment] { trunk + crown + highlighted }
    }

    /// The lines of a profile standing at `base`: a ring per section at its height (on the leaning axis, or at its
    /// own fitted centre), with uprights joining each ring of a part to the next, so a tapering trunk and a bulging
    /// crown read as such. The ring with `highlight`'s id is returned apart, to be drawn in another colour.
    public static func figure(
        _ profile: TreeProfile, lean: Lean? = nil, at base: SIMD3<Float> = .zero, detail: Float = 1,
        highlight: TreeSection.ID? = nil
    ) -> Figure {
        let tilt = Self.tilt(lean)
        let ringCount = max(8, Int((Float(ringSegments) * detail).rounded()))
        let uprightCount = max(4, Int((Float(uprights) * detail).rounded()))
        func centre(_ section: TreeSection) -> SIMD3<Float> {
            let h = Float(section.height)
            if let offset = section.offset {
                return base + SIMD3(Float(offset.x), h, Float(offset.y))
            }
            return base + SIMD3(tilt.x * h, h, tilt.z * h)
        }
        var figure = Figure(trunk: [], crown: [])
        for part in TreeSection.Part.allCases {
            var lines: [Segment] = []
            let rings = profile.sections.filter { $0.part == part }
            for section in rings {
                let ring = Wireframe.ring(centre: centre(section), radius: Float(section.radius), count: ringCount)
                if section.id == highlight {
                    figure.highlighted += ring
                } else {
                    lines += ring
                }
            }
            for (lower, upper) in zip(rings, rings.dropFirst()) {
                lines += uprights(
                    from: centre(lower), to: centre(upper), radius: Float(lower.radius),
                    topRadius: Float(upper.radius), count: uprightCount)
            }
            switch part {
            case .trunk: figure.trunk = lines
            case .crown: figure.crown = lines
            }
        }
        return figure
    }

    /// Points around each ring.
    public static let ringSegments = 32
    /// Uprights along the trunk and the crown.
    public static let uprights = 8
    /// Width of each line's tube, in metres.
    public static let lineWidth: Float = 0.012

    /// The lines of a tree standing at `base`: rings of the trunk's diameter at the ground, at breast height (where
    /// the DBH was measured) and at the crown's base, joined by uprights; and rings of the crown's width at its base
    /// and its top, joined by uprights. A lean tilts the trunk and carries the crown with it, as the Mac visualiser
    /// centres the crown over the trunk's top. `detail` below 1 draws fewer ring segments and uprights, for a site
    /// full of trees.
    public static func figure(
        _ form: TreeForm, lean: Lean? = nil, at base: SIMD3<Float> = .zero, detail: Float = 1
    ) -> Figure {
        let form = form.clamped
        let tilt = Self.tilt(lean)
        let ringCount = max(8, Int((Float(ringSegments) * detail).rounded()))
        let uprightCount = max(4, Int((Float(uprights) * detail).rounded()))
        func axis(_ height: Double) -> SIMD3<Float> {
            let h = Float(height)
            return base + SIMD3(tilt.x * h, h, tilt.z * h)
        }

        var trunk: [Segment] = []
        let trunkRadius = Float(form.trunkDiameter / 2)
        var trunkHeights = [0, form.crownBase]
        if form.crownBase > DBH.standardHeight {
            trunkHeights.insert(DBH.standardHeight, at: 1)
        }
        for height in trunkHeights {
            trunk += Wireframe.ring(centre: axis(height), radius: trunkRadius, count: ringCount)
        }
        trunk += uprights(from: axis(0), to: axis(form.crownBase), radius: trunkRadius, count: uprightCount)

        var crown: [Segment] = []
        let crownRadius = Float(form.crownWidth / 2)
        let crownBase = axis(form.crownBase)
        let top = axis(form.height)
        crown += Wireframe.ring(centre: crownBase, radius: crownRadius, count: ringCount)
        crown += Wireframe.ring(centre: top, radius: crownRadius, count: ringCount)
        crown += uprights(from: crownBase, to: top, radius: crownRadius, count: uprightCount)
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

    static func uprights(
        from bottom: SIMD3<Float>, to top: SIMD3<Float>, radius: Float, topRadius: Float? = nil, count: Int
    ) -> [Segment] {
        let upperRadius = topRadius ?? radius
        return (0..<count).map { i in
            let angle = Float(i) / Float(count) * 2 * .pi
            let direction = SIMD3(cos(angle), 0, sin(angle))
            return Segment(from: bottom + direction * radius, to: top + direction * upperRadius)
        }
    }

    /// The tube mesh of some segments, at the tree's line width.
    public static func mesh(_ segments: [Segment], width: Float = lineWidth) -> Mesh {
        Wireframe.mesh(segments, width: width)
    }
}
