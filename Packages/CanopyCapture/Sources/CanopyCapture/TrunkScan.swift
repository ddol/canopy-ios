import CanopyModel
import Foundation
import simd

/// The result of measuring a trunk: the analysis, the cropped evidence mesh and its GLB bytes.
public struct TrunkCapture: Sendable {
    public var analysis: TrunkAnalysis.Result
    /// The evidence mesh, centred on the trunk at the height where the scan started.
    public var evidence: Mesh
    public var glb: Data
    /// Horizontal radius of the evidence crop around the trunk centre, in metres.
    public var cropRadius: Double
    /// World position of the trunk centre at ground level.
    public var trunkBase: SIMD3<Float>
    public var cameraPosition: SIMD3<Float>
    /// The raw depth points kept round the trunk, relative to `trunkBase`: x and z from the trunk's axis at the
    /// ground, y above the ground. Empty on a device without scene depth.
    public var points: [SIMD3<Float>] = []
    /// The ground's height in the evidence mesh's frame, whose origin is on the trunk's axis at the height the scan
    /// started.
    public var groundHeight: Double = 0

    /// A ring fitted to the scan `height` metres above the ground: a circle through the raw depth points in a band
    /// there when it holds enough of them, else through the evidence mesh's slice. The centre is from the trunk's
    /// base (x, z). Throws when the scan has too little of the trunk at that height.
    public func fitSection(at height: Double, halfWidth: Float = 0.05) throws -> FittedCircle {
        let analysis = TrunkAnalysis()
        let band = points.slice(atHeight: Float(height), halfWidth: halfWidth)
        let slice =
            band.count >= analysis.minimumDepthPoints
            ? band
            : [-0.04, -0.02, 0, 0.02, 0.04].flatMap { evidence.slice(atHeight: Float(groundHeight + height + $0)) }
        guard slice.count >= 12 else { throw TrunkAnalysisError.notEnoughPoints(slice.count) }
        let circle: FittedCircle
        do {
            circle = try CircleFit.robustFit(slice)
        } catch {
            throw TrunkAnalysisError.notEnoughPoints(slice.count)
        }
        let arcDegrees = circle.arc * 180 / .pi
        guard arcDegrees >= 60 else { throw TrunkAnalysisError.arcTooShort(degrees: arcDegrees) }
        let diameter = 2 * circle.radius
        guard analysis.plausibleDiameters.contains(diameter) else {
            throw TrunkAnalysisError.implausibleDiameter(diameter)
        }
        return circle
    }

    /// `fitSection` applied to a profile's ring: its radius and centre from the scan, marked as fitted.
    public func snapping(_ section: TreeSection) throws -> TreeSection {
        let circle = try fitSection(at: section.height)
        var snapped = section
        snapped.radius = circle.radius
        snapped.offset = circle.center
        snapped.radiusUncertainty = circle.radiusUncertainty
        snapped.source = .scan
        return snapped
    }
}

/// How far a trunk scan has got, for live feedback while the player walks round.
public struct ScanProgress: Equatable, Sendable {
    /// Triangles captured so far.
    public var triangleCount: Int
    /// Degrees of the trunk's circumference covered 1.37 m above the ground, once a circle can be fitted.
    public var arcDegrees: Double?
    /// Current estimate of the diameter 1.37 m above the ground, in metres.
    public var diameter: Double?
    /// Raw depth points kept round the trunk so far.
    public var pointCount = 0
    /// Whether the current diameter came from the raw depth points rather than the mesh.
    public var fromDepthPoints = false

    public init(
        triangleCount: Int, arcDegrees: Double? = nil, diameter: Double? = nil, pointCount: Int = 0,
        fromDepthPoints: Bool = false
    ) {
        self.triangleCount = triangleCount
        self.arcDegrees = arcDegrees
        self.diameter = diameter
        self.pointCount = pointCount
        self.fromDepthPoints = fromDepthPoints
    }

    /// Enough of the circumference for a confident fit.
    public var isWellCovered: Bool { (arcDegrees ?? 0) >= 270 }
}

/// Measuring a trunk from a scan: the region around the trunk that is accumulated, the analysis, and the evidence
/// crop. Pure geometry; the ARKit side is `CaptureSession`.
public enum TrunkScan {
    /// Horizontal radius around the scan centre (a point on the trunk's surface) that is kept and analysed. The far
    /// side of the trunk must fall inside it, so this covers trunks up to 2 m across.
    public static let radius: Float = 2.0
    /// How far below and above the scan centre the region reaches, in metres.
    public static let below: Float = 3
    public static let above: Float = 4
    /// The evidence keeps the trunk and this much around it, in metres.
    public static let evidenceMargin = 0.6

    /// Measures the trunk in an accumulated scan.
    ///
    /// - Parameters:
    ///   - world: the scanned mesh in world coordinates (y up).
    ///   - points: raw depth points kept round the trunk, world coordinates, if the device gave any.
    ///   - floorHeights: world heights of floor-classified points near the trunk, if ARKit classified any.
    ///   - center: the point on the trunk where the scan started.
    ///   - camera: the camera position, for placing the trunk on the map.
    ///   - northAligned: true when world −z is true north, so the lean's direction can be given.
    public static func analyse(
        world: Mesh, points: [SIMD3<Float>] = [], floorHeights: [Float], center: SIMD3<Float>,
        camera: SIMD3<Float>, northAligned: Bool
    ) throws -> TrunkCapture {
        let (region, ground) = try prepare(world: world, floorHeights: floorHeights, center: center)
        let local = points.cropped(around: center, radius: radius, below: below, above: above)
        let analysis = try TrunkAnalysis().measure(
            region, points: local, groundHeight: ground, northAligned: northAligned)

        // Keep only the trunk and a margin around it as evidence, centred on the trunk.
        let trunkCenter = center + SIMD3(Float(analysis.center.x), 0, Float(analysis.center.y))
        let cropRadius = min(Double(radius), analysis.circle.radius + evidenceMargin)
        let evidence = world.cropped(around: trunkCenter, radius: Float(cropRadius), below: below, above: above)
        let trunkBase = trunkCenter + SIMD3(0, Float(ground), 0)
        return TrunkCapture(
            analysis: analysis,
            evidence: evidence,
            glb: try GLB.data(for: evidence),
            cropRadius: cropRadius,
            trunkBase: trunkBase,
            cameraPosition: camera,
            points: points.cropped(around: trunkBase, radius: radius, below: 0.5, above: below + above),
            groundHeight: ground
        )
    }

    /// A quick look at how much of the trunk the scan covers so far. Never throws: an incomplete scan just has no
    /// arc or diameter yet.
    public static func progress(
        world: Mesh, points: [SIMD3<Float>] = [], floorHeights: [Float], center: SIMD3<Float>
    ) -> ScanProgress {
        guard let (region, ground) = try? prepare(world: world, floorHeights: floorHeights, center: center) else {
            return ScanProgress(triangleCount: world.triangleCount, pointCount: points.count)
        }
        var analysis = TrunkAnalysis()
        analysis.minimumArcDegrees = 0
        analysis.leanHeights = []
        let local = points.cropped(around: center, radius: radius, below: below, above: above)
        guard let result = try? analysis.measure(region, points: local, groundHeight: ground) else {
            return ScanProgress(triangleCount: world.triangleCount, pointCount: points.count)
        }
        return ScanProgress(
            triangleCount: world.triangleCount,
            arcDegrees: result.circle.arc * 180 / .pi,
            diameter: result.dbh.diameter.value,
            pointCount: points.count,
            fromDepthPoints: result.depthPointCount > 0
        )
    }

    /// The region around the scan centre (in coordinates centred on it) and the ground height in that frame.
    static func prepare(world: Mesh, floorHeights: [Float], center: SIMD3<Float>) throws -> (Mesh, Double) {
        let region = world.cropped(around: center, radius: radius, below: below, above: above)
        guard region.triangleCount > 50 else { throw CaptureError.notEnoughMesh }
        if !floorHeights.isEmpty {
            let sorted = floorHeights.map { Double($0 - center.y) }.sorted()
            return (region, sorted[sorted.count / 2])
        }
        guard let ground = region.groundHeight(near: .zero, radius: 1.5) else { throw CaptureError.noGround }
        return (region, ground)
    }
}

public enum CaptureError: Error, Equatable {
    /// Nothing in the mesh under the centre of the view.
    case noSurface
    case notEnoughMesh
    case noGround
    /// Finish was asked for without a scan in progress.
    case notScanning
}
