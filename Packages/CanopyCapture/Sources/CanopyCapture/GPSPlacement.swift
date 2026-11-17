import CanopyModel
import Foundation
import simd

/// Where an AR session's world is on the map when GPS places it: the map position of the session's origin, and how
/// far the world is turned about the vertical against the north ARKit aligns it to. GPS sets the origin and leaves the
/// turn at zero. The player can then move and turn the placement by hand, until what is drawn stands on the trees in
/// front of them. ARKit's x is east and its -z north, so an AR point's (x, -z) is its east and north of the origin,
/// before the turn.
public struct GPSPlacement: Equatable, Sendable {
    public var origin: GeoPoint
    /// Radians, anticlockwise seen from above. The AR world's east and north are turned by this much to get the
    /// map's.
    public var yaw: Double

    public init(origin: GeoPoint, yaw: Double = 0) {
        self.origin = origin
        self.yaw = yaw
    }

    /// East and north of the origin, in metres on the map, of an AR world point.
    public func enu(ofARKit point: SIMD3<Float>) -> SIMD2<Double> {
        Self.rotate(SIMD2(Double(point.x), Double(-point.z)), by: yaw)
    }

    /// The AR world's x and z of a point `enu` metres east and north of the origin on the map.
    public func arkitXZ(ofENU enu: SIMD2<Double>) -> SIMD2<Float> {
        let local = Self.rotate(enu, by: -yaw)
        return SIMD2(Float(local.x), Float(-local.y))
    }

    /// Where an AR world point is on the map.
    public func geo(ofARKit point: SIMD3<Float>) -> GeoPoint {
        let enu = enu(ofARKit: point)
        return LocalFrame(origin: origin).geoPoint(of: ENU(east: enu.x, north: enu.y, up: 0)).point
    }

    /// The AR world's x and z of a map point.
    public func arkitXZ(of geo: GeoPoint) -> SIMD2<Float> {
        let enu = LocalFrame(origin: origin).enu(of: geo)
        return arkitXZ(ofENU: SIMD2(enu.east, enu.north))
    }

    /// Placed so that what was drawn at `from` is drawn at `to` (AR world points; their heights are ignored).
    public func moving(drawnAt from: SIMD3<Float>, to: SIMD3<Float>) -> GPSPlacement {
        // A map point m is drawn at a where origin + R(yaw)·h(a) = m. Keeping m fixed while a goes from `from` to
        // `to` moves the origin by R(yaw)·(h(from) - h(to)).
        let shift = Self.rotate(
            SIMD2(Double(from.x - to.x), Double(to.z - from.z)), by: yaw)
        return GPSPlacement(origin: shifted(origin, east: shift.x, north: shift.y), yaw: yaw)
    }

    /// Placed so that everything drawn turns `angle` radians clockwise, seen from above, about the AR point `pivot`.
    public func turning(clockwise angle: Double, about pivot: SIMD3<Float>) -> GPSPlacement {
        // Drawing turned clockwise by θ about p is the map read through h turned anticlockwise by θ about h(p): the
        // yaw grows by θ, and the origin moves so that h(p) still reads where it did.
        let p = SIMD2(Double(pivot.x), Double(-pivot.z))
        let shift = Self.rotate(p - Self.rotate(p, by: angle), by: yaw)
        return GPSPlacement(origin: shifted(origin, east: shift.x, north: shift.y), yaw: yaw + angle)
    }

    /// Where a point `enu` metres east and north of `origin` is on the map.
    private func shifted(_ origin: GeoPoint, east: Double, north: Double) -> GeoPoint {
        LocalFrame(origin: origin).geoPoint(of: ENU(east: east, north: north, up: 0)).point
    }

    static func rotate(_ v: SIMD2<Double>, by angle: Double) -> SIMD2<Double> {
        let (s, c) = (sin(angle), cos(angle))
        return SIMD2(c * v.x - s * v.y, s * v.x + c * v.y)
    }
}
