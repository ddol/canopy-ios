import CanopyModel
import Foundation
import simd

public enum TrunkAnalysisError: Error, Equatable {
    /// Not enough of the trunk was scanned 1.37 m above the ground.
    case notEnoughPoints(Int)
    /// The scan covers too little of the trunk's circumference to fit a circle.
    case arcTooShort(degrees: Double)
    /// The fitted diameter is not plausible for a tree trunk.
    case implausibleDiameter(Double)
}

/// Measures a trunk from a cropped LiDAR mesh: DBH from a circle fitted to slices 1.37 m above the ground, and lean
/// from the line through circle centres fitted up the stem.
///
/// The mesh must be in metres with y up, cropped around the trunk (see `Mesh.cropped`), and `groundHeight` is
/// the height of the ground at the trunk in the mesh's frame.
public struct TrunkAnalysis: Sendable {
    public struct Result: Equatable, Sendable {
        public var dbh: DBH
        public var lean: Lean?
        public var circle: FittedCircle
        /// Trunk centre 1.37 m above the ground, in the mesh frame (x, z).
        public var center: SIMD2<Double>
        /// Centres of the circles used for the lean, as (height above ground, x, z).
        public var stemCenters: [SIMD3<Double>]
        /// How many raw depth points the DBH circle was fitted to; 0 when it came from the mesh's slices.
        public var depthPointCount = 0
    }

    /// Offsets from 1.37 m above the ground that are sliced and pooled for the DBH fit, in metres.
    public var sliceOffsets: [Double] = [-0.04, -0.02, 0, 0.02, 0.04]
    /// Heights above ground of the slices used for lean, in metres.
    public var leanHeights: [Double] = [0.6, 0.9, 1.2, 1.5, 1.8, 2.1, 2.4]
    /// Uncertainty from the mesh itself (LiDAR range noise and mesh smoothing), added to the fit's, in metres
    /// of diameter.
    public var systematicDiameterUncertainty = 0.005
    /// The fit needs at least this much of the circumference.
    public var minimumArcDegrees = 75.0
    /// From a sapling to the biggest coast redwood.
    public var plausibleDiameters: ClosedRange<Double> = 0.03...9
    /// Half the height of the band of raw depth points pooled for the DBH fit, in metres: the same reach as the
    /// mesh's slice offsets.
    public var depthBandHalfWidth: Float = 0.05
    /// Raw depth points are preferred to the mesh's slices once the band holds this many.
    public var minimumDepthPoints = 40

    public init() {}

    /// - Parameters:
    ///   - points: raw depth points in the mesh's frame, if any were kept: with enough of them 1.37 m up they are
    ///     fitted instead of the mesh, which is smoothed.
    ///   - northAligned: true when the mesh frame's −z axis points to true north (ARKit's `gravityAndHeading`),
    ///     so the lean's direction can be reported.
    public func measure(
        _ mesh: Mesh, points depthPoints: [SIMD3<Float>] = [], groundHeight: Double, northAligned: Bool = false
    ) throws -> Result {
        let dbhHeight = groundHeight + DBH.standardHeight
        let band = depthPoints.slice(atHeight: Float(dbhHeight), halfWidth: depthBandHalfWidth)
        let fromDepth = band.count >= minimumDepthPoints
        let slice = fromDepth ? band : sliceOffsets.flatMap { mesh.slice(atHeight: Float(dbhHeight + $0)) }
        // The trunk the scan started on, not a stump or a shrub beside it, nor the ground.
        let points = Self.trunk(in: slice, touching: .zero)
        guard points.count >= 12 else { throw TrunkAnalysisError.notEnoughPoints(points.count) }
        let circle: FittedCircle
        do {
            circle = try CircleFit.robustFit(points)
        } catch {
            throw TrunkAnalysisError.notEnoughPoints(points.count)
        }
        let arcDegrees = circle.arc * 180 / .pi
        guard arcDegrees >= minimumArcDegrees else { throw TrunkAnalysisError.arcTooShort(degrees: arcDegrees) }
        let diameter = 2 * circle.radius
        guard plausibleDiameters.contains(diameter) else { throw TrunkAnalysisError.implausibleDiameter(diameter) }
        let uncertainty = (pow(2 * circle.radiusUncertainty, 2) + pow(systematicDiameterUncertainty, 2)).squareRoot()

        let stemCenters: [SIMD3<Double>] = leanHeights.compactMap { height in
            let y = Float(groundHeight + height)
            let band = depthPoints.slice(atHeight: y, halfWidth: 0.03)
            let near = (band.count >= minimumDepthPoints ? band : mesh.slice(atHeight: y)).filter {
                simd_distance($0, circle.center) <= circle.radius * 1.5 + 0.1
            }
            guard near.count >= 8, let fit = try? CircleFit.robustFit(near),
                abs(fit.radius - circle.radius) < 0.5 * circle.radius
            else { return nil }
            return SIMD3(height, fit.center.x, fit.center.y)
        }

        return Result(
            dbh: DBH(diameter: Quantity(diameter, uncertainty: uncertainty), method: .lidarCircleFit),
            lean: Self.lean(through: stemCenters, northAligned: northAligned),
            circle: circle,
            center: circle.center,
            stemCenters: stemCenters,
            depthPointCount: fromDepth ? band.count : 0
        )
    }

    /// The points of a slice on the trunk whose surface passes nearest `point` (the scan's start, on the bark): the
    /// slice is split into the trunks it crosses (`TrunkStems`), and the points within 15 cm of that trunk's ring are
    /// kept. With no piece large enough to fit yet, the piece holding the point nearest `point`; with nothing to
    /// split, the slice as it is.
    static func trunk(in slice: [SIMD2<Double>], touching point: SIMD2<Double>) -> [SIMD2<Double>] {
        guard slice.count >= 12 else { return slice }
        let rings = TrunkStems.rings(through: slice)
        if let ring = rings.min(by: { a, b in
            abs(simd_distance(a.center, point) - a.radius) < abs(simd_distance(b.center, point) - b.radius)
        }) {
            return slice.filter { abs(simd_distance($0, ring.center) - ring.radius) <= 0.15 }
        }
        let pieces = TrunkStems.pieces(slice)
        guard
            let nearest = slice.min(by: { simd_distance($0, point) < simd_distance($1, point) }),
            let piece = pieces.first(where: { $0.contains(nearest) })
        else { return slice }
        return piece.count >= 12 ? piece : slice
    }

    /// Fits x = a + b·h and z = c + d·h through the stem centres; the lean is the angle of (b, 1, d) from
    /// vertical.
    static func lean(through centers: [SIMD3<Double>], northAligned: Bool) -> Lean? {
        guard centers.count >= 3 else { return nil }
        let n = Double(centers.count)
        let meanH = centers.map(\.x).reduce(0, +) / n
        let meanX = centers.map(\.y).reduce(0, +) / n
        let meanZ = centers.map(\.z).reduce(0, +) / n
        let shh = centers.reduce(0) { $0 + ($1.x - meanH) * ($1.x - meanH) }
        guard shh > 1e-6 else { return nil }
        let slopeX = centers.reduce(0) { $0 + ($1.x - meanH) * ($1.y - meanX) } / shh
        let slopeZ = centers.reduce(0) { $0 + ($1.x - meanH) * ($1.z - meanZ) } / shh
        let residuals = centers.flatMap { c in
            [c.y - (meanX + slopeX * (c.x - meanH)), c.z - (meanZ + slopeZ * (c.x - meanH))]
        }
        let variance = residuals.reduce(0) { $0 + $1 * $1 } / max(2 * n - 4, 1)
        let slopeSigma = (variance / shh).squareRoot()

        let tilt = (slopeX * slopeX + slopeZ * slopeZ).squareRoot()
        let angle = atan(tilt) * 180 / .pi
        let angleSigma = slopeSigma / (1 + tilt * tilt) * 180 / .pi
        var azimuth: Quantity?
        if northAligned, tilt > 2 * slopeSigma {
            // ARKit gravityAndHeading: +x east, −z north. Clockwise from north.
            var degrees = atan2(slopeX, -slopeZ) * 180 / .pi
            if degrees < 0 { degrees += 360 }
            azimuth = Quantity(degrees, uncertainty: min(180, atan2(slopeSigma, tilt) * 180 / .pi))
        }
        return Lean(angle: Quantity(angle, uncertainty: max(angleSigma, 0.1)), azimuth: azimuth)
    }
}
