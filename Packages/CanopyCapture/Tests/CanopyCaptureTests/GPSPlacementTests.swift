import CanopyModel
import Foundation
import Testing
import simd

@testable import CanopyCapture

/// Moving and turning a GPS placement by hand, as the census's radar does to line the overlay up with the trees.
@Suite struct GPSPlacementTests {
    let origin = GeoPoint(latitude: 37.7694, longitude: -122.4862)

    /// Where a map point is drawn in the AR world, on the ground plane.
    func drawn(_ geo: GeoPoint, by placement: GPSPlacement) -> SIMD3<Float> {
        let xz = placement.arkitXZ(of: geo)
        return SIMD3(xz.x, 0, xz.y)
    }

    func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, within tolerance: Float = 0.01) -> Bool {
        simd_length(SIMD2(a.x - b.x, a.z - b.z)) < tolerance
    }

    @Test func unturnedItIsTheOriginsEastAndNorth() {
        let placement = GPSPlacement(origin: origin)
        let tree = LocalFrame(origin: origin).geoPoint(of: ENU(east: 6, north: 8, up: 0)).point
        #expect(near(drawn(tree, by: placement), SIMD3(6, 0, -8)))
        let back = LocalFrame(origin: origin).enu(of: placement.geo(ofARKit: SIMD3(6, 1, -8)))
        #expect(abs(back.east - 6) < 0.01 && abs(back.north - 8) < 0.01)
    }

    @Test func movingPutsWhatWasDrawnAtOnePointAtAnother() {
        let placement = GPSPlacement(origin: origin, yaw: 0.3)
        let tree = LocalFrame(origin: origin).geoPoint(of: ENU(east: 12, north: -4, up: 0)).point
        let was = drawn(tree, by: placement)
        let to = was + SIMD3(1.5, 0, -2)
        let moved = placement.moving(drawnAt: was, to: to)
        #expect(near(drawn(tree, by: moved), to))
        // Everything moves with it, by the same amount.
        let other = LocalFrame(origin: origin).geoPoint(of: ENU(east: -20, north: 30, up: 0)).point
        #expect(near(drawn(other, by: moved), drawn(other, by: placement) + SIMD3(1.5, 0, -2)))
        #expect(moved.yaw == placement.yaw)
    }

    @Test func turningSwingsTheDrawingClockwiseAboutThePivot() {
        let placement = GPSPlacement(origin: origin)
        let pivot = SIMD3<Float>(3, 1.4, -2)
        // A tree drawn 10 m north of the pivot.
        let tree = placement.geo(ofARKit: pivot + SIMD3(0, 0, -10))
        let turned = placement.turning(clockwise: .pi / 2, about: pivot)
        // A quarter turn clockwise seen from above takes north to east.
        #expect(near(drawn(tree, by: turned), pivot + SIMD3(10, 0, 0)))
        // The pivot itself stays put.
        let underPivot = placement.geo(ofARKit: pivot)
        #expect(near(drawn(underPivot, by: turned), pivot))
        // And turning back undoes it.
        let back = turned.turning(clockwise: -.pi / 2, about: pivot)
        #expect(near(drawn(tree, by: back), drawn(tree, by: placement)))
    }

    @Test func aTurnedFrameDrawsSitesTurnedToo() {
        let georeference = SiteOverlayTests.georeference(about: origin)
        let placement = GPSPlacement(origin: origin).turning(clockwise: .pi / 2, about: .zero)
        let frame = ARSiteFrame(
            placement: placement, georeference: georeference, arGroundAtOrigin: 0, siteGroundAtOrigin: 0)
        // Site (0, 10) is 10 m north of the origin: after a quarter turn clockwise it is drawn 10 m east.
        let p = frame.arkit(SIMD3<Double>(0, 10, 0))
        #expect(abs(p.x - 10) < 0.01 && abs(p.z) < 0.01)
        let back = frame.site(ofARKit: p)
        #expect(abs(back.x) < 0.01 && abs(back.y - 10) < 0.01)
        let position = GeoReference.position(ofARKit: p, placement: placement, accuracy: 3)
        let enu = LocalFrame(origin: origin).enu(of: position.geo)
        #expect(abs(enu.east) < 0.01 && abs(enu.north - 10) < 0.01)
    }
}
