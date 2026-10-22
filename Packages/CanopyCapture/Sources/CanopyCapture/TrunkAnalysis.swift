import CanopyModel
import Foundation
import simd

public enum TrunkAnalysisError: Error, Equatable {
    /// Not enough of the trunk was scanned at breast height.
    case notEnoughPoints(Int)
    /// The scan covers too little of the trunk's circumference to fit a circle.
    case arcTooShort(degrees: Double)
    /// The fitted diameter is not plausible for a tree trunk.
    case implausibleDiameter(Double)
}

/// Measures a trunk from a cropped LiDAR mesh: DBH from a circle fitted to slices at breast height, and lean
/// from the line through circle centres fitted up the stem.
///
/// The mesh must be in metres with y up, cropped around the trunk (see `Mesh.cropped`), and `groundHeight` is
/// the height of the ground at the trunk in the mesh's frame.
public struct TrunkAnalysis: Sendable {
    public struct Result: Equatable, Sendable {
        public var dbh: DBH
        public var lean: Lean?
        public var circle: FittedCircle
        /// Trunk centre at breast height, in the mesh frame (x, z).
        public var center: SIMD2<Double>
        /// Centres of the circles used for the lean, as (height above ground, x, z).
        public var stemCenters: [SIMD3<Double>]
    }

    /// Heights above and below breast height that are sliced and pooled for the DBH fit, in metres.
    public var sliceOffsets: [Double] = [-0.04, -0.02, 0, 0.02, 0.04]
    /// Heights above ground of the slices used for lean, in metres.
    public var leanHeights: [Double] = [0.6, 0.9, 1.2, 1.5, 1.8, 2.1, 2.4]
    /// Uncertainty from the mesh itself (LiDAR range noise and mesh smoothing), added to the fit's, in metres
    /// of diameter.
    public var systematicDiameterUncertainty = 0.005
    /// The fit needs at least this much of the circumference.
    public var minimumArcDegrees = 75.0
    public var plausibleDiameters: ClosedRange<Double> = 0.03...4

    public init() {}

    /// - Parameters:
    ///   - northAligned: true when the mesh frame's −z axis points to true north (ARKit's `gravityAndHeading`),
    ///     so the lean's direction can be reported.
    public func measure(_ mesh: Mesh, groundHeight: Double, northAligned: Bool = false) throws -> Result {
        let breast = groundHeight + DBH.standardHeight
        let points = sliceOffsets.flatMap { mesh.slice(atHeight: Float(breast + $0)) }
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
            let slice = mesh.slice(atHeight: Float(groundHeight + height))
            guard slice.count >= 8, let fit = try? CircleFit.robustFit(slice),
                abs(fit.radius - circle.radius) < 0.5 * circle.radius
            else { return nil }
            return SIMD3(height, fit.center.x, fit.center.y)
        }

        return Result(
            dbh: DBH(diameter: Quantity(diameter, uncertainty: uncertainty), method: .lidarCircleFit),
            lean: Self.lean(through: stemCenters, northAligned: northAligned),
            circle: circle,
            center: circle.center,
            stemCenters: stemCenters
        )
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
