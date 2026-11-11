import CanopyModel
import CanopyReference
import Foundation
import simd

/// A tree's crown as a small parametric volume, set against the aerial lidar points that fall in it: where it starts
/// and ends, how wide it is, where it is centred, and its outline. No mesh: the crown's rings in a `TreeProfile` are
/// drawn from these few numbers (`TreeProfile.withCrown`), and the controls that match it to the points change them.
///
/// In a scan's frame (`ScanAlignment`): heights above the ground, the centre from the trunk's base (x east, z south).
public struct CrownShape: Codable, Equatable, Sendable {
    /// How the crown's width changes from its base to its top.
    public enum Outline: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Widest a little below the middle, rounding off above and below: most broadleaf trees.
        case round
        /// Widest at the base, narrowing to a point: most conifers.
        case cone
        /// As wide all the way up.
        case column
        /// Narrow at the base, widest near the top: elms, some planes.
        case vase

        public var id: Self { self }

        public var label: String {
            switch self {
            case .round: "Round"
            case .cone: "Cone"
            case .column: "Column"
            case .vase: "Vase"
            }
        }

        /// The crown's radius at `t` of the way from its base (0) to its top (1), as a share of its widest.
        public func width(at t: Double) -> Double {
            let t = min(max(t, 0), 1)
            switch self {
            case .round:
                // An ellipse widest at 0.4, its ends kept a little open so the base and top rings show.
                let u = t < 0.4 ? (0.4 - t) / 0.4 : (t - 0.4) / 0.6
                return max(0.15, (1 - u * u).squareRoot())
            case .cone: return max(0.08, 1 - t * 0.92)
            case .column: return 1
            case .vase: return max(0.3, min(1, 0.3 + t * 1.1))
            }
        }
    }

    /// The crown's lowest foliage above the ground, in metres.
    public var base: Double
    /// The top of the tree above the ground, in metres.
    public var top: Double
    /// The crown's widest radius, in metres.
    public var radius: Double
    /// The crown's centre from the trunk's base, scene x (east) and z (south), in metres.
    public var centre: SIMD2<Double>
    public var outline: Outline

    public static let radii = 0.2...17.5
    public static let heights = 0.5...45.0

    public init(base: Double, top: Double, radius: Double, centre: SIMD2<Double> = .zero, outline: Outline = .round) {
        self.base = base
        self.top = top
        self.radius = radius
        self.centre = centre
        self.outline = outline
    }

    /// The crown a profile's crown rings make: their lowest and highest, their widest, their centre (the widest
    /// ring's) and a round outline; nil without crown rings.
    public init?(_ profile: TreeProfile) {
        let crown = profile.crown
        guard let low = crown.first, let high = crown.last, let widest = crown.max(by: { $0.radius < $1.radius })
        else { return nil }
        self.init(
            base: low.height, top: high.height, radius: widest.radius, centre: widest.offset ?? .zero, outline: .round)
    }

    /// The same crown inside its ranges, with its top at least half a metre above its base.
    public var clamped: CrownShape {
        var shape = self
        shape.base = min(max(base, 0), Self.heights.upperBound - 0.5)
        shape.top = min(max(top, shape.base + 0.5, Self.heights.lowerBound), Self.heights.upperBound)
        shape.radius = min(max(radius, Self.radii.lowerBound), Self.radii.upperBound)
        return shape
    }

    /// The crown's rings: five, from its base to its top, sized by its outline and centred on its centre.
    public var rings: [TreeSection] {
        let shape = clamped
        return (0...4).map { i in
            let t = Double(i) / 4
            return TreeSection(
                part: .crown, height: shape.base + (shape.top - shape.base) * t,
                radius: shape.radius * shape.outline.width(at: t), source: .eye, offset: shape.centre)
        }
    }

    /// How far `point` is outside the crown, in metres (negative inside): from the side of the ring at its height, or
    /// from the base or the top when it is below or above the crown.
    public func distance(to point: SIMD3<Float>, groundHeight: Double) -> Double {
        let height = Double(point.y) - groundHeight
        let span = max(top - base, 0.01)
        let t = (height - base) / span
        let across = simd_distance(SIMD2(Double(point.x), Double(point.z)), centre)
        let side = across - radius * outline.width(at: t)
        let vertical = max(base - height, height - top)
        return max(side, vertical)
    }

    /// How well the crown holds the points: the share of them inside it, from 0 to 1.
    public func coverage(of points: [SIMD3<Float>], groundHeight: Double) -> Double {
        guard !points.isEmpty else { return 0 }
        let inside = points.count { distance(to: $0, groundHeight: groundHeight) <= 0.25 }
        return Double(inside) / Double(points.count)
    }

    /// The crown fitted to the aerial points round a tree, in the scan's frame: centred on them, from the lowest
    /// thirtieth of them to the top hundredth, with the outline whose widths best follow theirs, wide enough to hold
    /// nine in ten of them. Points below `understorey` metres are shrubs and grass, not the crown. Starts from the
    /// points within `reach` of `start`'s centre and looks again round the crown it finds, so a neighbour's crown
    /// pulls it less. Nil with fewer than 20 points in reach.
    public static func fitted(
        to points: [SIMD3<Float>], groundHeight: Double, start: SIMD2<Double> = .zero, reach: Double = 6,
        understorey: Double = 1.5
    ) -> CrownShape? {
        let canopy = points.filter { Double($0.y) - groundHeight >= understorey }
        var centre = start
        var reach = reach
        var shape: CrownShape?
        for _ in 0..<3 {
            let near = canopy.filter { simd_distance(SIMD2(Double($0.x), Double($0.z)), centre) <= reach }
            guard near.count >= 20 else { return shape }
            let heights = near.map { Double($0.y) - groundHeight }.sorted()
            let flat = near.map { SIMD2(Double($0.x), Double($0.z)) }
            centre = flat.reduce(.zero, +) / Double(flat.count)
            let base = quantile(heights, 0.03)
            let top = quantile(heights, 0.99)
            let outline = bestOutline(near, centre: centre, base: base, top: top, groundHeight: groundHeight)
            // The widest radius that holds nine in ten of the points inside the outline at their heights.
            let span = max(top - base, 0.5)
            let needed = near.map { p in
                simd_distance(SIMD2(Double(p.x), Double(p.z)), centre)
                    / outline.width(at: (Double(p.y) - groundHeight - base) / span)
            }.sorted()
            let radius = quantile(needed, 0.9)
            shape = CrownShape(base: base, top: top, radius: radius, centre: centre, outline: outline).clamped
            reach = max(radius * 1.25, 1.5)
        }
        return shape
    }

    /// The outline whose widths, band by band up the crown, are nearest the points'.
    static func bestOutline(
        _ points: [SIMD3<Float>], centre: SIMD2<Double>, base: Double, top: Double, groundHeight: Double
    ) -> Outline {
        let bands = 5
        let span = max(top - base, 0.5)
        var reach = [[Double]](repeating: [], count: bands)
        for p in points {
            let t = (Double(p.y) - groundHeight - base) / span
            guard t >= 0, t <= 1 else { continue }
            reach[min(Int(t * Double(bands)), bands - 1)].append(
                simd_distance(SIMD2(Double(p.x), Double(p.z)), centre))
        }
        let widths = reach.map { $0.count >= 4 ? quantile($0.sorted(), 0.9) : nil }
        guard let widest = widths.compactMap({ $0 }).max(), widest > 0 else { return .round }
        return Outline.allCases.min { a, b in
            error(a, widths, widest, bands) < error(b, widths, widest, bands)
        } ?? .round
    }

    private static func error(_ outline: Outline, _ widths: [Double?], _ widest: Double, _ bands: Int) -> Double {
        widths.enumerated().reduce(0) { sum, band in
            guard let width = band.element else { return sum }
            let t = (Double(band.offset) + 0.5) / Double(bands)
            let d = width / widest - outline.width(at: t)
            return sum + d * d
        }
    }

    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(max(Int((Double(sorted.count - 1) * q).rounded()), 0), sorted.count - 1)
        return sorted[index]
    }
}

extension TreeProfile {
    /// The profile with its crown rings drawn from `shape` in place of those it had; the trunk stays.
    public func withCrown(_ shape: CrownShape) -> TreeProfile {
        TreeProfile(sections: sections.filter { $0.part == .trunk } + shape.rings)
    }
}

/// The aerial lidar points round a tree, moved into a trunk scan's frame so they can be drawn with it and a crown
/// fitted to them.
public enum CanopyPoints {
    /// The ASPRS classes of vegetation: low, medium and high.
    public static let vegetation: [UInt32] = [3, 4, 5]

    /// Points from the site's frame (x and y on the ground, z up, as Gerardus streams them) into the scan's: metres
    /// east and south of the trunk's base and up from the scan's ground. `base` is the trunk's base in the site
    /// frame, `groundElevation` the ground's site z there, and `correction` how far, east and north, the census
    /// position is out (`VectorTreePlacement.correction`), so the points move with Gerardus's tree when it is set on
    /// the trunk. At most `limit` points are kept, evenly through the blocks.
    public static func scanFrame(
        _ blocks: [PointBlock], georeference: SiteGeoreference, base: SIMD2<Double>, groundElevation: Double,
        groundHeight: Double, correction: SIMD2<Double> = .zero, limit: Int = 60_000
    ) -> [SIMD3<Float>] {
        let m = georeference.matrix
        let det = m.a * m.d - m.b * m.c
        guard abs(det) > 1e-9 else { return [] }
        let total = blocks.reduce(0) { $0 + $1.count }
        let step = max(1, Int((Double(total) / Double(limit)).rounded(.up)))
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(min(total, limit))
        var index = 0
        for block in blocks {
            for k in 0..<block.count {
                defer { index += 1 }
                guard index % step == 0 else { continue }
                let u = Double(block.x[k]) - base.x
                let v = Double(block.y[k]) - base.y
                // Site offsets back to metres east and north (the site frame is an affine map of them).
                let east = (m.d * u - m.b * v) / det - correction.x
                let north = (-m.c * u + m.a * v) / det - correction.y
                let up = Double(block.z[k]) - groundElevation + groundHeight
                out.append(SIMD3(Float(east), Float(up), Float(-north)))
            }
        }
        return out
    }
}
