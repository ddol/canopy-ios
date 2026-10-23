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
}

/// How far a trunk scan has got, for live feedback while the player walks round.
public struct ScanProgress: Equatable, Sendable {
    /// Triangles captured so far.
    public var triangleCount: Int
    /// Degrees of the trunk's circumference covered 1.37 m above the ground, once a circle can be fitted.
    public var arcDegrees: Double?
    /// Current estimate of the diameter 1.37 m above the ground, in metres.
    public var diameter: Double?

    public init(triangleCount: Int, arcDegrees: Double? = nil, diameter: Double? = nil) {
        self.triangleCount = triangleCount
        self.arcDegrees = arcDegrees
        self.diameter = diameter
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
    ///   - floorHeights: world heights of floor-classified points near the trunk, if ARKit classified any.
    ///   - center: the point on the trunk where the scan started.
    ///   - camera: the camera position, for placing the trunk on the map.
    ///   - northAligned: true when world −z is true north, so the lean's direction can be given.
    public static func analyse(
        world: Mesh, floorHeights: [Float], center: SIMD3<Float>, camera: SIMD3<Float>, northAligned: Bool
    ) throws -> TrunkCapture {
        let (region, ground) = try prepare(world: world, floorHeights: floorHeights, center: center)
        let analysis = try TrunkAnalysis().measure(region, groundHeight: ground, northAligned: northAligned)

        // Keep only the trunk and a margin around it as evidence, centred on the trunk.
        let trunkCenter = center + SIMD3(Float(analysis.center.x), 0, Float(analysis.center.y))
        let cropRadius = min(Double(radius), analysis.circle.radius + evidenceMargin)
        let evidence = world.cropped(around: trunkCenter, radius: Float(cropRadius), below: below, above: above)
        return TrunkCapture(
            analysis: analysis,
            evidence: evidence,
            glb: try GLB.data(for: evidence),
            cropRadius: cropRadius,
            trunkBase: trunkCenter + SIMD3(0, Float(ground), 0),
            cameraPosition: camera
        )
    }

    /// A quick look at how much of the trunk the scan covers so far. Never throws: an incomplete scan just has no
    /// arc or diameter yet.
    public static func progress(world: Mesh, floorHeights: [Float], center: SIMD3<Float>) -> ScanProgress {
        guard let (region, ground) = try? prepare(world: world, floorHeights: floorHeights, center: center) else {
            return ScanProgress(triangleCount: world.triangleCount)
        }
        var analysis = TrunkAnalysis()
        analysis.minimumArcDegrees = 0
        analysis.leanHeights = []
        guard let result = try? analysis.measure(region, groundHeight: ground) else {
            return ScanProgress(triangleCount: world.triangleCount)
        }
        return ScanProgress(
            triangleCount: world.triangleCount,
            arcDegrees: result.circle.arc * 180 / .pi,
            diameter: result.dbh.diameter.value
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
