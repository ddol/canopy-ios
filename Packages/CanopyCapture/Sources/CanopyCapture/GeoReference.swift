import CanopyModel
import Foundation
import simd

/// Places an AR world point on the map, from the device's GPS fix and the point's offset from the camera.
///
/// With ARKit's gravity-and-heading alignment, world +x is east, +y is up and +z is south, so the offset is
/// (east: dx, north: −dz, up: dy). Without north alignment the direction is unknown, and the point is placed at
/// the device with the offset distance added to its uncertainty.
public enum GeoReference {
    /// Uncertainty added for the AR offset itself (tracking drift over a few metres), in metres.
    public static let arOffsetSigma = 0.1

    public static func position(
        of point: SIMD3<Float>,
        camera: SIMD3<Float>,
        device: GeoPoint,
        horizontalAccuracy: Double,
        northAligned: Bool
    ) -> Position {
        let offset = point - camera
        let gps = max(horizontalAccuracy, 0)
        guard northAligned else {
            let distance = Double(simd_length(SIMD2(offset.x, offset.z)))
            let sigma = (gps * gps + distance * distance + arOffsetSigma * arOffsetSigma).squareRoot()
            return Position(geo: device, covariance: .isotropic(horizontal: sigma, vertical: sigma))
        }
        let enu = ENU(east: Double(offset.x), north: Double(-offset.z), up: Double(offset.y))
        let (geo, _) = LocalFrame(origin: device).geoPoint(of: enu)
        let sigma = (gps * gps + arOffsetSigma * arOffsetSigma).squareRoot()
        return Position(geo: geo, covariance: .isotropic(horizontal: sigma, vertical: max(sigma, 1)))
    }
}
