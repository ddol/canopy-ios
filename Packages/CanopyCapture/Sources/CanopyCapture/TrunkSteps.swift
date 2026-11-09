import CanopyModel
import Foundation
import simd

/// The trunk's axis and taper from the rings fitted to it: a straight line through their centres and a straight
/// taper through their radii, so the rings above them can be predicted. Offsets are from the trunk's base (x, z), as
/// `TreeSection.offset`.
public struct TrunkTaper: Equatable, Sendable {
    /// The axis's centre at the ground.
    public var centre: SIMD2<Double>
    /// How far the axis moves per metre up.
    public var lean: SIMD2<Double>
    /// The radius at the ground, as the rings above the butt flare continue down to it.
    public var radius: Double
    /// How much the radius changes per metre up: negative as the trunk narrows.
    public var taper: Double
    /// The highest ring it was fitted to, in metres above the ground.
    public var top: Double

    /// Rings below this height are left out: the trunk flares out to its roots there.
    public static let flare = 0.5
    /// The taper a fit may give, per metre up: a trunk narrows by up to 3 cm of radius a metre and never widens by
    /// more than half a centimetre.
    public static let tapers = -0.03...0.005
    /// The lean a fit may give: 30° from vertical.
    public static let maximumLean = tan(30 * Double.pi / 180)

    public init(centre: SIMD2<Double>, lean: SIMD2<Double>, radius: Double, taper: Double, top: Double) {
        self.centre = centre
        self.lean = lean
        self.radius = radius
        self.taper = taper
        self.top = top
    }

    /// Fitted to the trunk's rings that the scan fitted or the player confirmed, from half a metre up. With their
    /// heights too close together for a slope (spread less than 20 cm), the axis takes `lean` and the trunk does not
    /// taper. Nil without such a ring.
    public init?(_ rings: [TreeSection], lean: Lean? = nil) {
        let tilt = WireframeTree.tilt(lean)
        let leanFromScan = SIMD2(Double(tilt.x), Double(tilt.z))
        let fitted = rings.filter {
            $0.part == .trunk && ($0.source == .scan || $0.source == .confirmed) && $0.height >= Self.flare
        }
        guard !fitted.isEmpty else { return nil }
        let samples = fitted.map { ring in
            (height: ring.height, centre: ring.offset ?? leanFromScan * ring.height, radius: ring.radius)
        }
        let n = Double(samples.count)
        let meanHeight = samples.reduce(0) { $0 + $1.height } / n
        let meanCentre = samples.reduce(SIMD2<Double>.zero) { $0 + $1.centre } / n
        let meanRadius = samples.reduce(0) { $0 + $1.radius } / n
        let shh = samples.reduce(0) { $0 + ($1.height - meanHeight) * ($1.height - meanHeight) }
        var slope = leanFromScan
        var taper = 0.0
        if shh / n >= 0.2 * 0.2 {
            slope =
                samples.reduce(SIMD2<Double>.zero) { $0 + ($1.height - meanHeight) * ($1.centre - meanCentre) } / shh
            taper = samples.reduce(0) { $0 + ($1.height - meanHeight) * ($1.radius - meanRadius) } / shh
        }
        let tilt2 = simd_length(slope)
        if tilt2 > Self.maximumLean { slope *= Self.maximumLean / tilt2 }
        taper = min(max(taper, Self.tapers.lowerBound), Self.tapers.upperBound)
        self.init(
            centre: meanCentre - slope * meanHeight, lean: slope, radius: meanRadius - taper * meanHeight,
            taper: taper, top: samples.map(\.height).max() ?? meanHeight)
    }

    /// Where the axis is at `height`.
    public func centre(at height: Double) -> SIMD2<Double> { centre + lean * height }

    /// The radius at `height`, never below the thinnest ring a profile takes.
    public func radius(at height: Double) -> Double { max(radius + taper * height, TreeProfile.radii.lowerBound) }

    /// How far the prediction at `height` may be out: a centimetre at the fitted rings, growing with the distance
    /// above the top one. The standard uncertainty of each coordinate of the centre, and of the radius, in metres.
    public func uncertainty(at height: Double) -> (centre: Double, radius: Double) {
        let above = max(0, height - top)
        return (0.01 + 0.03 * above, 0.01 + 0.01 * above)
    }

    /// The unit vector up the axis, in the ARKit frame.
    public var axis: SIMD3<Double> { simd_normalize(SIMD3(lean.x, 1, lean.y)) }
}

/// Trunk rings a metre apart from the ground up, for fitting a trunk ring by ring: each step the scan's depth
/// points reach is fitted to them (`TrunkCapture.snapping`), and the steps above are predicted from those
/// (`TrunkTaper`) for the camera to align (`RingAligner`).
public enum TrunkSteps {
    /// Metres between steps.
    public static let spacing = 1.0
    /// A step within this many metres of a ring is that ring.
    static let tolerance = 0.05

    /// The step heights from 1 m up to a quarter of a metre below `top` (the crown's base, which has its own ring).
    public static func heights(below top: Double) -> [Double] {
        guard top - 0.25 >= spacing else { return [] }
        return stride(from: spacing, through: top - 0.25, by: spacing).map { $0 }
    }

    /// The profile with every step below `top` that the scan reaches fitted to it: a ring set by eye at a step is
    /// snapped, a missing one is added, and a step fitted or confirmed already is left alone. Steps the scan does
    /// not reach are left as they are. The trunk's other rings set by eye from half a metre up (breast height, the
    /// crown's base) are snapped too where the scan reaches them.
    public static func fitted(_ profile: TreeProfile, to capture: TrunkCapture, below top: Double) -> TreeProfile {
        var profile = profile
        let radius = profile.form.trunkDiameter / 2
        for height in heights(below: top) {
            let existing = ring(near: height, in: profile)
            guard existing?.isKept != true else { continue }
            let ring = existing ?? TreeSection(part: .trunk, height: height, radius: radius)
            guard let snapped = try? capture.snapping(ring) else { continue }
            profile[ring.id] = snapped
        }
        for ring in profile.trunk where ring.source == .eye && ring.height >= TrunkTaper.flare {
            if let snapped = try? capture.snapping(ring) { profile[ring.id] = snapped }
        }
        return profile
    }

    /// The profile with a ring at every step below `top` that has none fitted or confirmed: on the axis and at the
    /// taper of the rings fitted below (`TrunkTaper`), set by eye, for the camera to align. Without a fitted ring
    /// to predict from, the steps take the trunk's diameter on the leaning axis.
    public static func predicted(_ profile: TreeProfile, below top: Double, lean: Lean? = nil) -> TreeProfile {
        var profile = profile
        let taper = TrunkTaper(profile.sections, lean: lean)
        let radius = profile.form.trunkDiameter / 2
        for height in heights(below: top) {
            let existing = ring(near: height, in: profile)
            guard existing?.isKept != true else { continue }
            var ring = existing ?? TreeSection(part: .trunk, height: height, radius: radius)
            ring.height = height
            ring.radius = taper?.radius(at: height) ?? radius
            ring.offset = taper?.centre(at: height)
            ring.radiusUncertainty = nil
            ring.source = .eye
            profile[ring.id] = ring
        }
        return profile
    }

    /// The rings for the camera to align, each with what the rings below predict for it: the trunk's rings from
    /// half a metre up that are set by eye or aligned already, not the ones the scan fitted or the player
    /// confirmed. `base` is the world point the tree stands on. Nil when there are none.
    public static func aligner(for profile: TreeProfile, base: SIMD3<Float>, lean: Lean? = nil) -> RingAligner? {
        let taper = TrunkTaper(profile.sections, lean: lean)
        let tilt = WireframeTree.tilt(lean)
        let origin = SIMD3<Double>(base)
        let targets = profile.trunk.filter {
            $0.height >= TrunkTaper.flare && ($0.source == .eye || $0.source == .camera)
        }
        .map { ring -> RingAligner.Target in
            let centre: SIMD2<Double>
            let radius: Double
            let sigma: (centre: Double, radius: Double)
            if let taper {
                centre = taper.centre(at: ring.height)
                radius = taper.radius(at: ring.height)
                sigma = taper.uncertainty(at: ring.height)
            } else {
                // Nothing fitted to predict from: the ring as drawn, loosely.
                centre = ring.offset ?? SIMD2(Double(tilt.x), Double(tilt.z)) * ring.height
                radius = ring.radius
                sigma = (0.15, max(0.05, ring.radius / 2))
            }
            return RingAligner.Target(
                id: ring.id, centre: origin + SIMD3(centre.x, ring.height, centre.y), radius: radius,
                centreSigma: sigma.centre, radiusSigma: sigma.radius)
        }
        guard !targets.isEmpty else { return nil }
        return RingAligner(targets: targets, axis: taper?.axis ?? SIMD3(0, 1, 0))
    }

    /// The profile with the camera's fits applied: each ring that is still set by eye or aligned takes its fitted
    /// centre (from `base`) and radius and is marked as aligned. Rings fitted to the scan, confirmed or gone since
    /// are left alone.
    public static func applying(
        _ fits: [UUID: RingAligner.Fit], to profile: TreeProfile, base: SIMD3<Float>
    ) -> TreeProfile {
        var profile = profile
        let origin = SIMD2(Double(base.x), Double(base.z))
        for (id, fit) in fits {
            guard var ring = profile.section(id), ring.source == .eye || ring.source == .camera else { continue }
            ring.offset = fit.centre - origin
            ring.radius = fit.radius
            ring.radiusUncertainty = fit.radiusUncertainty
            ring.source = .camera
            profile[id] = ring
        }
        return profile
    }

    private static func ring(near height: Double, in profile: TreeProfile) -> TreeSection? {
        profile.trunk.filter { abs($0.height - height) < tolerance }
            .min { abs($0.height - height) < abs($1.height - height) }
    }
}
