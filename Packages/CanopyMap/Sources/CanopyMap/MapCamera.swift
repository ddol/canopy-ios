import CoreGraphics
import UIKit
import UIKit.UIGestureRecognizerSubclass
import simd

/// The 3D map's camera: looking at `target` from `distance` metres, `tilt` radians above the ground, turned `azimuth`
/// radians from north-up (camera south of the target looking north; a larger azimuth turns the map clockwise). Scene
/// axes are ARKit's: x east, y up, z south. Plain values, so the gestures' geometry is tested without a view.
struct CameraRig: Equatable {
    var target: SIMD3<Float>
    var distance: Float
    var tilt: Float
    var azimuth: Float
    /// The view's size in points.
    var size: CGSize
    /// Vertical field of view, in degrees (SceneKit's default projection direction).
    var fieldOfView: Float = 52

    /// From a few metres off a trunk, close enough to move among the trees and buildings, to the whole city.
    static let distances: ClosedRange<Float> = 3...20000
    /// From all but level, looking along the street, to straight down; straight down itself would leave the camera
    /// without a heading.
    static let tilts: ClosedRange<Float> = (3 * .pi / 180)...(88 * .pi / 180)

    var position: SIMD3<Float> {
        target + SIMD3(sin(azimuth) * cos(tilt), sin(tilt), cos(azimuth) * cos(tilt)) * distance
    }

    /// The direction from the camera through a point in the view.
    func ray(through point: CGPoint) -> SIMD3<Float> {
        let forward = simd_normalize(target - position)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        let half = tan(fieldOfView / 2 * .pi / 180)
        let width = Float(max(size.width, 1))
        let height = Float(max(size.height, 1))
        let x = (2 * Float(point.x) / width - 1) * half * width / height
        let y = (1 - 2 * Float(point.y) / height) * half
        return simd_normalize(forward + right * x + up * y)
    }

    /// Where a point in the view meets the level ground through the target; nil above the horizon or so near it
    /// (farther than `horizon` times the distance) that a finger's width there would be hundreds of metres.
    func ground(at point: CGPoint, horizon: Float = 25) -> SIMD3<Float>? {
        let origin = position
        let direction = ray(through: point)
        guard direction.y < -1e-4 else { return nil }
        let along = (target.y - origin.y) / direction.y
        guard along > 0, along < distance * horizon else { return nil }
        return origin + direction * along
    }

    /// The rig slid over the ground so that `point` on the ground is under `screen` in the view, as a map stays under
    /// the finger dragging it. Unchanged when `screen` looks above the horizon.
    func keeping(_ point: SIMD3<Float>, under screen: CGPoint) -> CameraRig {
        guard let now = ground(at: screen) else { return self }
        var rig = self
        rig.target += SIMD3(point.x - now.x, 0, point.z - now.z)
        return rig
    }

    /// Ground metres per point at the target's depth.
    var metresPerPoint: Float {
        distance * 2 * tan(fieldOfView / 2 * .pi / 180) / Float(max(size.height, 1))
    }

    func clamped() -> CameraRig {
        var rig = self
        rig.distance = min(max(distance, Self.distances.lowerBound), Self.distances.upperBound)
        rig.tilt = min(max(tilt, Self.tilts.lowerBound), Self.tilts.upperBound)
        return rig
    }
}

/// What two fingers on the map are doing, decided once they have moved a little, as on Apple's map: both moving up or
/// down together, side by side and keeping their spacing, tilt it; anything else pinches, turns and drags it.
enum TwoFingerIntent: Equatable {
    case undecided
    case tilt
    case transform

    /// Points the fingers must move before the intent is decided.
    static let slop: CGFloat = 10

    static func classify(from start: [CGPoint], to now: [CGPoint]) -> TwoFingerIntent {
        guard start.count >= 2, now.count >= 2 else { return .undecided }
        let a = CGPoint(x: now[0].x - start[0].x, y: now[0].y - start[0].y)
        let b = CGPoint(x: now[1].x - start[1].x, y: now[1].y - start[1].y)
        let moved = max(hypot(a.x, a.y), hypot(b.x, b.y))
        guard moved >= slop else { return .undecided }
        let spreadChange = abs(spacing(now) - spacing(start))
        let turned = abs(angle(from: start, to: now))
        let upOrDown = abs(a.y) > 2 * abs(a.x) && abs(b.y) > 2 * abs(b.x) && a.y * b.y > 0
        return upOrDown && spreadChange < moved * 0.5 && turned < 0.12 ? .tilt : .transform
    }

    static func spacing(_ points: [CGPoint]) -> CGFloat {
        hypot(points[1].x - points[0].x, points[1].y - points[0].y)
    }

    /// How far the line between the fingers turned, clockwise on screen, in radians from -π to π.
    static func angle(from start: [CGPoint], to now: [CGPoint]) -> CGFloat {
        let before = atan2(start[1].y - start[0].y, start[1].x - start[0].x)
        let after = atan2(now[1].y - now[0].y, now[1].x - now[0].x)
        var turn = after - before
        while turn > .pi { turn -= 2 * .pi }
        while turn < -.pi { turn += 2 * .pi }
        return turn
    }

    /// A twist smaller than this, in radians (about 8°), leaves the map's heading alone, so a pinch does not turn it
    /// by accident; past it the map turns with the fingers, less this much, so it starts turning smoothly.
    static let turnThreshold: CGFloat = 0.14

    /// How far the map turns for fingers that turned `angle` radians.
    static func turn(_ angle: CGFloat) -> CGFloat {
        abs(angle) <= turnThreshold ? 0 : angle - (angle > 0 ? turnThreshold : -turnThreshold)
    }

    static func centroid(_ points: [CGPoint]) -> CGPoint {
        let n = CGFloat(max(points.count, 1))
        return CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
    }
}

/// The map's drag, pinch, turn and tilt as one gesture that follows one or two fingers, so the map can carry on
/// smoothly as a finger lands or lifts (Apple's map does the same). It begins once a finger has moved a little, so
/// taps still reach the tap recognisers, and measures from where the fingers were when the last one landed or lifted
/// (`origins`), so the ground under each finger stays under it from the moment it touched.
final class MapTouchGesture: UIGestureRecognizer {
    private var tracked: [UITouch] = []
    private var starts: [ObjectIdentifier: CGPoint] = [:]
    /// Changes whenever a finger lands or lifts, so the handler starts again from where the fingers are.
    private(set) var fingers = 0
    /// Where the tracked fingers were when the last one landed or lifted.
    private(set) var origins: [CGPoint] = []

    /// Where the tracked fingers are, at most two.
    var points: [CGPoint] { tracked.prefix(2).map { $0.location(in: view) } }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            guard tracked.count < 2 else {
                ignore(touch, for: event)
                continue
            }
            tracked.append(touch)
            starts[ObjectIdentifier(touch)] = touch.location(in: view)
        }
        fingers += 1
        origins = points
        if state == .began || state == .changed { state = .changed }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible {
            let moved = tracked.contains { touch in
                guard let start = starts[ObjectIdentifier(touch)] else { return false }
                let now = touch.location(in: view)
                return hypot(now.x - start.x, now.y - start.y) > TwoFingerIntent.slop
            }
            if moved { state = .began }
        } else {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches, ending: .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches, ending: .cancelled)
    }

    private func lift(_ touches: Set<UITouch>, ending: UIGestureRecognizer.State) {
        tracked.removeAll { touches.contains($0) }
        fingers += 1
        origins = points
        if tracked.isEmpty {
            state = state == .possible ? .failed : ending
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func reset() {
        super.reset()
        tracked = []
        starts = [:]
        fingers = 0
        origins = []
    }
}
