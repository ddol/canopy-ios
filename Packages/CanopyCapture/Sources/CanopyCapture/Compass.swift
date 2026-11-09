import CanopyModel
import CoreGraphics
import Foundation
import simd

/// Where a tree is from the player, for the census view's selected tree and its top-down compass: the horizontal
/// offset, distance and bearing from AR world points (gravity-and-heading aligned: +x east, −z north) or from map
/// positions, the camera's heading, the compass's scale and where a tree lands on it, and whether a tree is in view.
public enum Compass {
    /// The horizontal offset (east, north) in metres from one AR world point to another.
    public static func offset(from start: SIMD3<Float>, to end: SIMD3<Float>) -> SIMD2<Double> {
        SIMD2(Double(end.x - start.x), Double(start.z - end.z))
    }

    /// The horizontal offset (east, north) in metres from one map position to another, in the tangent plane at the
    /// first.
    public static func offset(from start: GeoPoint, to end: GeoPoint) -> SIMD2<Double> {
        let enu = LocalFrame(origin: start).enu(of: end)
        return SIMD2(enu.east, enu.north)
    }

    /// Degrees clockwise from true north, 0 ..< 360, of an offset; nil when it is under a centimetre.
    public static func bearing(of offset: SIMD2<Double>) -> Double? {
        guard simd_length(offset) >= 0.01 else { return nil }
        return normalised(atan2(offset.x, offset.y) * 180 / .pi)
    }

    /// The turn from `heading` to face `bearing`, in degrees, −180 ..< 180: positive to the right (clockwise).
    public static func turn(to bearing: Double, from heading: Double) -> Double {
        let turn = normalised(bearing - heading)
        return turn >= 180 ? turn - 360 : turn
    }

    /// The direction the camera looks, in degrees clockwise from true north: the horizontal part of its −z axis, which
    /// is where the back camera points whichever way the phone is turned. Nil when it points within about 10° of
    /// straight up or down, where the direction means little.
    public static func heading(ofCamera transform: simd_float4x4) -> Double? {
        let back = transform.columns.2
        let forward = SIMD2(Double(-back.x), Double(back.z))  // east, north
        guard simd_length(forward) >= 0.17 else { return nil }
        return bearing(of: forward)
    }

    /// The heading to show, from the camera's pose while AR tracks, else from the compass (Core Location's true
    /// heading). Nil, so the last heading stays, when the camera points almost straight up or down: Core Location
    /// follows the phone's top edge in portrait, which in landscape is a quarter turn from where the player faces.
    public static func heading(camera transform: simd_float4x4?, compass: Double?) -> Double? {
        guard let transform else { return compass }
        return heading(ofCamera: transform)
    }

    /// Which way to turn to face a tree.
    public enum Direction: Equatable, Sendable {
        case ahead
        case behind
        /// Degrees to turn, always positive.
        case left(Double)
        case right(Double)
    }

    /// Which way to turn, from the turn to face a tree (`turn(to:from:)`): ahead within `ahead` degrees either side,
    /// behind within 30° of straight back, else left or right by how much.
    public static func direction(turn: Double, ahead: Double = 15) -> Direction {
        if abs(turn) <= ahead { return .ahead }
        if abs(turn) >= 150 { return .behind }
        return turn < 0 ? .left(-turn) : .right(turn)
    }

    /// The eight-point compass name of a bearing: N, NE, E, SE, S, SW, W or NW.
    public static func point(of bearing: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int((normalised(bearing) + 22.5) / 45) % 8]
    }

    /// An angle in degrees as 0 ..< 360.
    public static func normalised(_ degrees: Double) -> Double {
        let angle = degrees.truncatingRemainder(dividingBy: 360)
        return angle < 0 ? angle + 360 : angle
    }

    // MARK: The top-down compass

    /// The radii the compass is drawn at, in metres.
    public static let ranges: [Double] = [5, 10, 20, 30, 50, 100, 200]

    /// The compass radius, in metres, that shows a tree `distance` away inside its rim, with a little room: the
    /// smallest of `ranges` at least an eighth more than the distance, else the largest.
    public static func range(for distance: Double) -> Double {
        ranges.first { $0 >= distance * 1.125 } ?? ranges[ranges.count - 1]
    }

    /// Where an offset (east, north, metres) lands on a compass of radius `range` metres with the player at the centre
    /// and `heading` up, as a fraction of the radius: x to the right, y down, as on screen. A point beyond the rim is
    /// pulled onto it (`clamped`), so it still says which way to turn.
    public static func place(
        _ offset: SIMD2<Double>, heading: Double, range: Double
    ) -> (point: SIMD2<Double>, clamped: Bool) {
        let h = heading * .pi / 180
        let right = offset.x * cos(h) - offset.y * sin(h)
        let ahead = offset.x * sin(h) + offset.y * cos(h)
        var point = SIMD2(right, -ahead) / max(range, 0.01)
        let length = simd_length(point)
        guard length > 1 else { return (point, false) }
        point /= length
        return (point, true)
    }

    // MARK: In view

    /// Whether a tree is in view, from its trunk's points projected into the view (nil for one behind the camera).
    /// Coming into view needs a point well inside (`margin`, a share of the shorter side, from every edge); staying in
    /// view needs one anywhere on screen, so the answer does not flicker at the edge.
    public static func isInView(
        _ points: [CGPoint?], bounds: CGRect, wasInView: Bool, margin: CGFloat = 0.12
    ) -> Bool {
        guard !bounds.isEmpty else { return false }
        let inset = wasInView ? 0 : min(bounds.width, bounds.height) * margin
        let area = bounds.insetBy(dx: inset, dy: inset)
        return points.contains { $0.map(area.contains) ?? false }
    }

    /// Whether a world point is in front of the camera (more than 10 cm along where it looks), so projecting it into
    /// the view means something.
    public static func isInFront(_ point: SIMD3<Float>, ofCamera transform: simd_float4x4) -> Bool {
        let back = transform.columns.2
        let position = transform.columns.3
        let along = simd_dot(point - SIMD3(position.x, position.y, position.z), -SIMD3(back.x, back.y, back.z))
        return along > 0.1
    }

    /// Nearer than this, in metres, the player is at the tree, so it counts as in view whatever the camera sees.
    public static let atTree = 2.0

    // MARK: Moving a tree

    /// Where a view ray meets the level ground at `height` (an AR world y), within `maxDistance` metres of its origin;
    /// nil when it points level or up, or meets it further away.
    public static func ground(
        rayFrom origin: SIMD3<Float>, direction: SIMD3<Float>, height: Float, maxDistance: Float = 60
    ) -> SIMD3<Float>? {
        let direction = simd_normalize(direction)
        guard direction.y < -0.01 else { return nil }
        let distance = (height - origin.y) / direction.y
        guard distance >= 0, distance <= maxDistance else { return nil }
        return origin + direction * distance
    }

    /// A trunk's base from where the reticle hit it: on the ground under the hit, and, when the hit is on the trunk
    /// (more than 30 cm above the ground) rather than at its foot, a trunk's radius further from the camera, since a
    /// ray meets the trunk's near side.
    public static func trunkBase(
        hit: SIMD3<Float>, camera: SIMD3<Float>, ground: Float, radius: Float
    ) -> SIMD3<Float> {
        var base = SIMD3(hit.x, ground, hit.z)
        let away = SIMD2(hit.x - camera.x, hit.z - camera.z)
        if hit.y - ground > 0.3, simd_length(away) > 0.01 {
            let push = simd_normalize(away) * max(radius, 0)
            base.x += push.x
            base.z += push.y
        }
        return base
    }
}

extension GeoReference {
    /// How far AR tracking drifts, as a share of the distance walked from the session origin.
    public static let arDriftPerMetre = 0.01

    /// Places an AR world point on the map through the session origin: its map position (from the best GPS fix so far
    /// and the camera's offset then, good to `accuracy` metres) plus the point's offset from the origin. That is how
    /// the overlay draws the census's trees, so a tree placed in AR stays where it is drawn. The uncertainty adds the
    /// AR offset's own (`arOffsetSigma`, and drift growing with the distance from the origin).
    public static func position(ofARKit point: SIMD3<Float>, origin: GeoPoint, accuracy: Double) -> Position {
        let enu = ENU(east: Double(point.x), north: Double(-point.z), up: 0)
        let (geo, _) = LocalFrame(origin: origin).geoPoint(of: enu)
        let ar = arOffsetSigma + arDriftPerMetre * enu.horizontalDistance
        let gps = max(accuracy, 0)
        let sigma = (gps * gps + ar * ar).squareRoot()
        return Position(geo: geo, covariance: .isotropic(horizontal: sigma, vertical: max(sigma, 1)))
    }
}
