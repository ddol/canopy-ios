import CanopyModel
import CoreGraphics
import Foundation
import Testing
import simd

@testable import CanopyCapture

@Suite struct CompassTests {
    let stowLake = GeoPoint(latitude: 37.7699, longitude: -122.4757)

    /// A camera at `position` looking along `forward` (AR world), with the world's up as near its up as can be.
    func camera(looking forward: SIMD3<Float>, at position: SIMD3<Float> = .zero) -> simd_float4x4 {
        let back = -simd_normalize(forward)
        let worldUp = abs(back.y) > 0.99 ? SIMD3<Float>(0, 0, -1) : SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(worldUp, back))
        let up = simd_cross(back, right)
        return simd_float4x4(
            SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(position, 1))
    }

    // MARK: Distance and bearing

    @Test func arWorldOffsetsAreEastAndNorth() {
        // +x is east and −z north.
        let offset = Compass.offset(from: SIMD3(1, 1.5, 2), to: SIMD3(4, 0, -2))
        #expect(offset == SIMD2(3, 4))
        #expect(simd_length(offset) == 5)
        let bearing = Compass.bearing(of: offset)
        #expect(abs(bearing! - 36.87) < 0.01)
    }

    @Test func mapOffsetsAgreeWithTheLocalFrame() {
        let tree = LocalFrame(origin: stowLake).geoPoint(of: ENU(east: -6, north: -8, up: 0)).point
        let offset = Compass.offset(from: stowLake, to: tree)
        #expect(abs(offset.x + 6) < 0.001)
        #expect(abs(offset.y + 8) < 0.001)
        #expect(abs(simd_length(offset) - 10) < 0.001)
        // South-west.
        #expect(abs(Compass.bearing(of: offset)! - 216.87) < 0.01)
        #expect(Compass.point(of: Compass.bearing(of: offset)!) == "SW")
    }

    @Test func bearingsGoClockwiseFromNorth() {
        #expect(Compass.bearing(of: SIMD2(0, 10)) == 0)
        #expect(Compass.bearing(of: SIMD2(10, 0)) == 90)
        #expect(Compass.bearing(of: SIMD2(0, -10)) == 180)
        #expect(Compass.bearing(of: SIMD2(-10, 0)) == 270)
        #expect(Compass.bearing(of: SIMD2(0.001, 0)) == nil)
    }

    @Test func turnsAreTheShortWayRound() {
        #expect(Compass.turn(to: 90, from: 0) == 90)
        #expect(Compass.turn(to: 10, from: 350) == 20)
        #expect(Compass.turn(to: 350, from: 10) == -20)
        #expect(Compass.turn(to: 180, from: 0) == -180)
        #expect(Compass.turn(to: 45, from: 45) == 0)
    }

    @Test func directionsToTurn() {
        #expect(Compass.direction(turn: 10) == .ahead)
        #expect(Compass.direction(turn: -15) == .ahead)
        #expect(Compass.direction(turn: -40) == .left(40))
        #expect(Compass.direction(turn: 100) == .right(100))
        #expect(Compass.direction(turn: 160) == .behind)
        #expect(Compass.direction(turn: -180) == .behind)
    }

    @Test func pointsOfTheCompass() {
        #expect(Compass.point(of: 0) == "N")
        #expect(Compass.point(of: 22) == "N")
        #expect(Compass.point(of: 23) == "NE")
        #expect(Compass.point(of: 359) == "N")
        #expect(Compass.point(of: -90) == "W")
        #expect(Compass.point(of: 135) == "SE")
    }

    // MARK: Heading

    @Test func theCameraHeadsWhereItLooks() throws {
        #expect(try #require(Compass.heading(ofCamera: camera(looking: SIMD3(0, 0, -1)))) == 0)
        #expect(abs(try #require(Compass.heading(ofCamera: camera(looking: SIMD3(1, 0, 0)))) - 90) < 1e-4)
        #expect(abs(try #require(Compass.heading(ofCamera: camera(looking: SIMD3(0, 0, 1)))) - 180) < 1e-4)
        #expect(abs(try #require(Compass.heading(ofCamera: camera(looking: SIMD3(-1, 0, -1)))) - 315) < 1e-4)
    }

    @Test func tiltingTheCameraKeepsItsHeading() throws {
        // Looking 60° down towards the east, or 45° up towards the south.
        let down = camera(looking: SIMD3(cos(Float.pi / 3), -sin(Float.pi / 3), 0))
        #expect(abs(try #require(Compass.heading(ofCamera: down)) - 90) < 1e-3)
        let up = camera(looking: SIMD3(0, 1, 1))
        #expect(abs(try #require(Compass.heading(ofCamera: up)) - 180) < 1e-3)
    }

    @Test func aCameraLookingStraightDownHasNoHeading() {
        #expect(Compass.heading(ofCamera: camera(looking: SIMD3(0, -1, 0))) == nil)
        #expect(Compass.heading(ofCamera: camera(looking: SIMD3(0.05, -1, 0))) == nil)
    }

    @Test func theCompassStandsInOnlyWhileARIsNotTracking() {
        // Tracking: the camera's heading, whatever the compass says.
        #expect(
            Compass.heading(camera: camera(looking: SIMD3(1, 0, 0)), compass: 10).map { abs($0 - 90) < 1e-4 } == true)
        // Tracking but looking straight down: no new heading, so the last one stays. Core Location's heading follows
        // the phone's top edge in portrait, which in landscape is a quarter turn off.
        #expect(Compass.heading(camera: camera(looking: SIMD3(0, -1, 0)), compass: 10) == nil)
        // Not tracking: the compass.
        #expect(Compass.heading(camera: nil, compass: 10) == 10)
        #expect(Compass.heading(camera: nil, compass: nil) == nil)
    }

    // MARK: The compass

    @Test func theRangeFitsTheTreeWithRoomToSpare() {
        #expect(Compass.range(for: 0) == 5)
        #expect(Compass.range(for: 4) == 5)
        #expect(Compass.range(for: 4.5) == 10)
        #expect(Compass.range(for: 12) == 20)
        #expect(Compass.range(for: 45) == 100)
        #expect(Compass.range(for: 900) == 200)
    }

    @Test func aTreeStraightAheadIsAboveThePlayer() {
        // Facing east, a tree 10 m east on a 20 m compass is half way up.
        let placed = Compass.place(SIMD2(10, 0), heading: 90, range: 20)
        #expect(!placed.clamped)
        #expect(abs(placed.point.x) < 1e-9)
        #expect(abs(placed.point.y + 0.5) < 1e-9)
    }

    @Test func treesToTheSidesAndBehindLandWhereTheyAre() {
        // Facing north: east is to the right, south below.
        let east = Compass.place(SIMD2(5, 0), heading: 0, range: 10).point
        #expect(abs(east.x - 0.5) < 1e-9 && abs(east.y) < 1e-9)
        let south = Compass.place(SIMD2(0, -5), heading: 0, range: 10).point
        #expect(abs(south.x) < 1e-9 && abs(south.y - 0.5) < 1e-9)
        // Facing east, north is to the left.
        let north = Compass.place(SIMD2(0, 5), heading: 90, range: 10).point
        #expect(abs(north.x + 0.5) < 1e-9 && abs(north.y) < 1e-9)
        // Facing south-west, a tree to the north-west is on the right.
        let northWest = Compass.place(SIMD2(-3, 3), heading: 225, range: 10).point
        #expect(northWest.x > 0.4 && abs(northWest.y) < 1e-9)
    }

    @Test func aTreeBeyondTheRimIsPulledOntoIt() {
        let placed = Compass.place(SIMD2(30, 30), heading: 0, range: 20)
        #expect(placed.clamped)
        #expect(abs(simd_length(placed.point) - 1) < 1e-9)
        #expect(abs(placed.point.x - placed.point.y * -1) < 1e-9)
        #expect(placed.point.x > 0 && placed.point.y < 0)
    }

    // MARK: In view

    @Test func comingIntoViewNeedsAPointWellInside() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        // 12 % of the shorter side is a 48-point margin.
        #expect(!Compass.isInView([CGPoint(x: 20, y: 400)], bounds: bounds, wasInView: false))
        #expect(Compass.isInView([CGPoint(x: 60, y: 400)], bounds: bounds, wasInView: false))
        #expect(Compass.isInView([nil, CGPoint(x: 200, y: 400)], bounds: bounds, wasInView: false))
        #expect(!Compass.isInView([nil, nil], bounds: bounds, wasInView: false))
        #expect(!Compass.isInView([CGPoint(x: 200, y: 400)], bounds: .zero, wasInView: false))
    }

    @Test func onlyPointsInFrontOfTheCameraCount() {
        let looking = camera(looking: SIMD3(1, 0, 0), at: SIMD3(0, 1.5, 0))
        #expect(Compass.isInFront(SIMD3(5, 0, 2), ofCamera: looking))
        #expect(!Compass.isInFront(SIMD3(-5, 0, 0), ofCamera: looking))
        #expect(!Compass.isInFront(SIMD3(0, 0, 3), ofCamera: looking))
    }

    @Test func stayingInViewNeedsOnlyAPointOnScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        #expect(Compass.isInView([CGPoint(x: 20, y: 400)], bounds: bounds, wasInView: true))
        #expect(!Compass.isInView([CGPoint(x: -5, y: 400)], bounds: bounds, wasInView: true))
        #expect(!Compass.isInView([nil], bounds: bounds, wasInView: true))
    }

    // MARK: Moving a tree

    @Test func aRayDownMeetsTheGround() throws {
        // From 1.5 m up, 45° down towards the north: the ground 1.5 m north.
        let point = try #require(
            Compass.ground(rayFrom: SIMD3(0, 1.5, 0), direction: SIMD3(0, -1, -1), height: 0))
        #expect(simd_distance(point, SIMD3(0, 0, -1.5)) < 1e-5)
    }

    @Test func aRayLevelOrUpOrTooFarMissesTheGround() {
        #expect(Compass.ground(rayFrom: SIMD3(0, 1.5, 0), direction: SIMD3(0, 0, -1), height: 0) == nil)
        #expect(Compass.ground(rayFrom: SIMD3(0, 1.5, 0), direction: SIMD3(0, 1, -1), height: 0) == nil)
        #expect(
            Compass.ground(rayFrom: SIMD3(0, 1.5, 0), direction: SIMD3(0, -0.01, -1), height: 0, maxDistance: 60) == nil
        )
    }

    @Test func aHitOnTheTrunkIsPushedBackToItsCentre() {
        // The camera is south of the trunk; the reticle met its near side 1.2 m up.
        let base = Compass.trunkBase(hit: SIMD3(0, 1.2, -3), camera: SIMD3(0, 1.5, 0), ground: 0, radius: 0.2)
        #expect(simd_distance(base, SIMD3(0, 0, -3.2)) < 1e-5)
    }

    @Test func aHitAtTheFootStaysWhereItIs() {
        let base = Compass.trunkBase(hit: SIMD3(2, 0.1, -2), camera: SIMD3(0, 1.5, 0), ground: 0, radius: 0.2)
        #expect(base == SIMD3(2, 0, -2))
    }

    @Test func throughTheSessionOriginAPointLandsAtItsOffset() {
        let position = GeoReference.position(ofARKit: SIMD3(3, 0.2, -4), origin: stowLake, accuracy: 4)
        let enu = LocalFrame(origin: stowLake).enu(of: position.geo)
        #expect(abs(enu.east - 3) < 0.001)
        #expect(abs(enu.north - 4) < 0.001)
        // The fix's 4 m with the AR offset's 0.1 m and 1 % of the 5 m from the origin.
        #expect(abs(position.covariance.horizontalSigma - (16 + 0.15 * 0.15).squareRoot()) < 1e-9)
    }

    @Test func aTreePlacedThroughTheSessionOriginIsDrawnWhereItWasPut() {
        // The overlay draws census trees through a GPS-placed site frame (`ARSiteFrame(origin:…)`): a point placed on
        // the map through the same session origin comes back to where it was put in AR.
        let siteOrigin = LocalFrame(origin: stowLake).geoPoint(of: ENU(east: -40, north: 25, up: 0)).point
        let georeference = SiteOverlayTests.georeference(about: siteOrigin)
        let frame = ARSiteFrame(
            origin: stowLake, georeference: georeference, arGroundAtOrigin: -1.5, siteGroundAtOrigin: 12)
        let put = SIMD3<Float>(7.5, -1.5, -18)
        let placed = GeoReference.position(ofARKit: put, origin: stowLake, accuracy: 5)
        let site = frame.site(of: placed.geo)
        let drawn = frame.arkit(SIMD3<Double>(site.x, site.y, 12))
        #expect(abs(drawn.x - put.x) < 0.01)
        #expect(abs(drawn.z - put.z) < 0.01)
    }
}
