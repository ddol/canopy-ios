import CanopyModel
import CanopyReference
import CoreGraphics
import Foundation
import Testing
import simd

@testable import CanopyMap

@Suite struct WireframeRendererTests {
    let origin = GeoPoint(latitude: 37.7650, longitude: -122.4690)

    /// A site frame that is exactly ENU about `origin`.
    func georeference(about origin: GeoPoint) throws -> SiteGeoreference {
        let frame = LocalFrame(origin: origin)
        let samples = [(0.0, 0.0), (100.0, 0.0), (0.0, 100.0), (100.0, 100.0), (-50.0, 30.0), (20.0, -80.0)].map {
            (geo: frame.geoPoint(of: ENU(east: $0.0, north: $0.1, up: 0)).point, site: SIMD2($0.0, $0.1))
        }
        return try SiteGeoreference(origin: origin, samples: samples)
    }

    @Test func siteMetresLandInSceneMetresAboutTheAnchor() throws {
        // The scene is anchored 200 m east and 100 m north of the site origin, at elevation 40.
        let anchor = LocalFrame(origin: origin).geoPoint(of: ENU(east: 200, north: 100, up: 0)).point
        let transform = SiteToScene(
            georeference: try georeference(about: origin), scene: LocalFrame(origin: anchor), elevation: 40)
        let p = transform.place(SIMD3(250, 100, 45))
        #expect(abs(p.x - 50) < 0.02)
        #expect(abs(p.z) < 0.02)
        #expect(abs(p.y - 5) < 0.001)
        let q = transform.place(SIMD3(200, 400, 40))
        #expect(abs(q.x) < 0.02)
        #expect(abs(q.z + 300) < 0.05)
    }

    @Test func aMeasuredTreeTakesItsFigureFromTheMeasurements() {
        let marker = MapLayers.TreeMarker(
            id: UUID(), location: origin, status: .verified, hazardCount: 0, dbh: 0.6, height: 20)
        let form = WireframeTrees.form(marker)
        #expect(form.trunkDiameter == 0.6)
        #expect(form.height == 20)
        #expect(abs(form.crownBase - 20 / 3) < 1e-9)
        let unmeasured = WireframeTrees.form(
            MapLayers.TreeMarker(id: UUID(), location: origin, status: .detected, hazardCount: 0))
        #expect(unmeasured.height == 8)
        #expect(unmeasured.trunkDiameter == 0.3)
    }

    @Test func theReferenceCarriesItsSitesWhenMerged() throws {
        let a = MapLayers.Reference(canopies: [], lines: [])
        let b = MapLayers.Reference(canopies: [], lines: [])
        #expect(MapLayers.Reference.merged([a, b])?.sites.isEmpty == true)
        #expect(a.sites.isEmpty)
    }
}

/// The 3D map's gestures, checked as geometry: the ground a finger is on stays under it, as on Apple's map.
@Suite struct MapGestureTests {
    typealias Coordinator = WireframeMap.Coordinator

    let size = CGSize(width: 400, height: 800)

    func rig(tilt degrees: Float = 55, azimuth: Float = 0.4) -> CameraRig {
        CameraRig(target: SIMD3(30, 2, -40), distance: 300, tilt: degrees * .pi / 180, azimuth: azimuth, size: size)
    }

    func close(_ a: SIMD3<Float>?, _ b: SIMD3<Float>?, within metres: Float) -> Bool {
        guard let a, let b else { return false }
        return simd_distance(SIMD2(a.x, a.z), SIMD2(b.x, b.z)) < metres
    }

    @Test func theCentreOfTheViewLooksAtTheTarget() throws {
        let rig = rig()
        let ground = try #require(rig.ground(at: CGPoint(x: 200, y: 400)))
        #expect(simd_distance(ground, rig.target) < 0.01)
        // Above the horizon there is no ground.
        #expect(self.rig(tilt: 12).ground(at: CGPoint(x: 200, y: 0)) == nil)
    }

    @Test func aDraggedPointStaysUnderTheFinger() throws {
        let rig = rig()
        let start = CGPoint(x: 120, y: 520)
        let anchor = try #require(rig.ground(at: start))
        for now in [CGPoint(x: 300, y: 380), CGPoint(x: 60, y: 700), CGPoint(x: 210, y: 300)] {
            let moved = Coordinator.drag(rig, anchor: anchor, from: start, to: now)
            #expect(close(moved.ground(at: now), anchor, within: 0.05))
            #expect(moved.tilt == rig.tilt && moved.distance == rig.distance && moved.azimuth == rig.azimuth)
        }
    }

    @Test func pinchingZoomsAboutThePointBetweenTheFingers() throws {
        let rig = rig()
        let start = [CGPoint(x: 140, y: 500), CGPoint(x: 260, y: 560)]
        let anchor = try #require(rig.ground(at: TwoFingerIntent.centroid(start)))
        // Spread to twice the spacing about a centroid that also moved.
        let now = [CGPoint(x: 90, y: 440), CGPoint(x: 330, y: 560)]
        let moved = Coordinator.transform(rig, anchor: anchor, from: start, to: now)
        #expect(abs(moved.distance - rig.distance / 2) < 0.5)
        #expect(close(moved.ground(at: TwoFingerIntent.centroid(now)), anchor, within: 0.05))
    }

    @Test func twistingTurnsTheMapTheWayTheFingersTurn() throws {
        // Seen from nearly straight down, every finger keeps its own ground point, not just the one between them.
        let rig = rig(tilt: 88)
        let start = [CGPoint(x: 120, y: 400), CGPoint(x: 280, y: 400)]
        let grounds = try start.map { try #require(rig.ground(at: $0)) }
        let anchor = try #require(rig.ground(at: TwoFingerIntent.centroid(start)))
        // A quarter turn clockwise on screen about the centroid.
        let now = [CGPoint(x: 200, y: 320), CGPoint(x: 200, y: 480)]
        let moved = Coordinator.transform(rig, anchor: anchor, from: start, to: now)
        for (finger, ground) in zip(now, grounds) {
            #expect(close(moved.ground(at: finger), ground, within: 3))
        }
    }

    @Test func twoFingersUpTogetherTiltAndAnythingElseTransforms() {
        let start = [CGPoint(x: 140, y: 500), CGPoint(x: 260, y: 500)]
        #expect(
            TwoFingerIntent.classify(from: start, to: [CGPoint(x: 141, y: 497), CGPoint(x: 261, y: 498)]) == .undecided)
        let up = [CGPoint(x: 142, y: 470), CGPoint(x: 259, y: 468)]
        #expect(TwoFingerIntent.classify(from: start, to: up) == .tilt)
        let spread = [CGPoint(x: 110, y: 500), CGPoint(x: 290, y: 500)]
        #expect(TwoFingerIntent.classify(from: start, to: spread) == .transform)
        let twist = [CGPoint(x: 150, y: 520), CGPoint(x: 250, y: 470)]
        #expect(TwoFingerIntent.classify(from: start, to: twist) == .transform)
        let drag = [CGPoint(x: 180, y: 500), CGPoint(x: 300, y: 500)]
        #expect(TwoFingerIntent.classify(from: start, to: drag) == .transform)

        // Up tilts towards the horizon; the tilt stops short of flat and of straight down.
        let rig = rig()
        #expect(Coordinator.tilt(rig, from: start, to: up).tilt < rig.tilt)
        let far = [CGPoint(x: 140, y: -2000), CGPoint(x: 260, y: -2000)]
        #expect(Coordinator.tilt(rig, from: start, to: far).tilt == CameraRig.tilts.lowerBound)
    }
}
