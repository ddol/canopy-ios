import CanopyModel
import Foundation

/// Registering a phone's LiDAR scan against a site's 3DEP points.
///
/// ARKit (with gravity-and-heading alignment) works in a frame where +x is east, +y is up and +z is south. Gerardus
/// sensor frames are z-up, and a pose's heading is the azimuth of the sensor's +y axis. Canopy's sensor frame is the
/// ARKit world frame turned z-up: sensor (x, y, z) = ARKit (x, −z, y). Its origin is where the AR session started,
/// its +y points north, so a north-aligned session has heading 0.
public enum ScanRegistration {
    /// ARKit world → Canopy sensor frame.
    public static func sensorPoint(fromARKit p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(p.x, -p.z, p.y)
    }

    /// Canopy sensor frame → ARKit world.
    public static func arkitPoint(fromSensor p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(p.x, p.z, -p.y)
    }

    /// The scan to upload: ARKit world points in the sensor frame, thinned to one point per `voxel`-sized cube (the
    /// one nearest the cube centre) and at most `maxRange` metres (horizontally) from the session origin.
    public static func scanPoints(
        fromARKit points: [SIMD3<Float>], voxel: Float = 0.1, maxRange: Float = 60
    )
        -> PointBlock
    {
        var best: [SIMD3<Int32>: (point: SIMD3<Float>, distance: Float)] = [:]
        best.reserveCapacity(points.count / 4)
        for p in points where p.x * p.x + p.z * p.z <= maxRange * maxRange {
            let cell = SIMD3<Int32>(
                Int32((p.x / voxel).rounded(.down)), Int32((p.y / voxel).rounded(.down)),
                Int32((p.z / voxel).rounded(.down)))
            let centre = (SIMD3<Float>(Float(cell.x), Float(cell.y), Float(cell.z)) + 0.5) * voxel
            let d = p - centre
            let distance = (d * d).sum()
            if let existing = best[cell], existing.distance <= distance { continue }
            best[cell] = (p, distance)
        }
        var block = PointBlock()
        block.x.reserveCapacity(best.count)
        block.y.reserveCapacity(best.count)
        block.z.reserveCapacity(best.count)
        // Sort for a deterministic upload (the scan id is a hash of header and points).
        for (_, value) in best.sorted(by: { ($0.key.x, $0.key.y, $0.key.z) < ($1.key.x, $1.key.y, $1.key.z) }) {
            let s = sensorPoint(fromARKit: value.point)
            block.x.append(s.x)
            block.y.append(s.y)
            block.z.append(s.z)
        }
        return block
    }

    /// The pose hint for a scan: the session origin's position (from a GPS fix taken at `camera`, an ARKit world
    /// position), north-aligned heading when known, and the origin's height above the ground.
    public static func hint(
        gps: GeoPoint, camera: SIMD3<Float>, groundBelowOrigin: Float?, northAligned: Bool
    ) -> PoseHint {
        // The camera is (x, −z) east and north of the origin, so the origin is that far back from the fix.
        let origin = LocalFrame(origin: gps).geoPoint(of: ENU(east: Double(-camera.x), north: Double(camera.z), up: 0))
            .point
        return PoseHint(
            position: GeodeticPosition(latitude: origin.latitude, longitude: origin.longitude),
            heading: northAligned ? 0 : nil,
            mountHeight: groundBelowOrigin.map { Double(max(0.2, -$0)) }
        )
    }
}

/// A scan placed on the map: maps ARKit world points of the registered session to site and WGS 84 positions.
public struct RegisteredScan: Sendable {
    public let pose: SensorPose
    public let georeference: SiteGeoreference
    /// One-sigma horizontal uncertainty of positions from this registration (m).
    public let sigma: Double
    public let registrationID: String
    public let passedGates: Bool

    public init(
        pose: SensorPose, georeference: SiteGeoreference, sigma: Double, registrationID: String, passedGates: Bool
    ) {
        self.pose = pose
        self.georeference = georeference
        self.sigma = sigma
        self.registrationID = registrationID
        self.passedGates = passedGates
    }

    /// Builds the result of a registration run, or nil when it has no hypothesis.
    public init?(_ registration: Registration, georeference: SiteGeoreference) {
        guard let best = registration.best, let pose = best.pose else { return nil }
        let fromCovariance = pose.horizontalSigma
        let fromSummary = best.summary.map(\.sigmaHorizontal).flatMap { $0 > 0 ? $0 : nil }
        let fromFit = best.quality.map { Double($0.groundP50 + $0.facadeP50) }.flatMap { $0 > 0 ? $0 : nil }
        self.init(
            pose: pose,
            georeference: georeference,
            sigma: max(0.1, fromCovariance ?? fromSummary ?? fromFit ?? 1),
            registrationID: registration.registrationID,
            passedGates: registration.state == .candidate && registration.gates.allSatisfy(\.passed)
        )
    }

    /// The site-frame position of an ARKit world point.
    public func site(ofARKit point: SIMD3<Float>) -> Vector3 {
        let s = ScanRegistration.sensorPoint(fromARKit: point)
        return pose.apply(Vector3(x: Double(s.x), y: Double(s.y), z: Double(s.z)))
    }

    /// The map position of an ARKit world point.
    public func position(ofARKit point: SIMD3<Float>) -> Position {
        let site = site(ofARKit: point)
        let geo = georeference.geo(x: site.x, y: site.y)
        return Position(geo: geo, covariance: .isotropic(horizontal: sigma, vertical: max(sigma, 0.2)))
    }
}
