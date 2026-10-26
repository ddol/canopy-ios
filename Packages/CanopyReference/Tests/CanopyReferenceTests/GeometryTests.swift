import CanopyModel
import Foundation
import Testing

@testable import CanopyReference

@Suite struct GeoreferenceTests {
    @Test func fitsAnAffineMapExactlyAndInverts() throws {
        let origin = GeoPoint(latitude: 37.769652, longitude: -122.475737)
        let frame = LocalFrame(origin: origin)
        // A site frame that is slightly scaled, rotated and shifted from local ENU, like a datum shift and projection.
        let scale = 1.000007
        let angle = 0.0004
        let shift = SIMD2(1.57, -0.16)
        func site(_ e: Double, _ n: Double) -> SIMD2<Double> {
            SIMD2(scale * (cos(angle) * e - sin(angle) * n), scale * (sin(angle) * e + cos(angle) * n)) + shift
        }
        let offsets = [(0.0, 0.0), (150, 0), (0, 150), (-150, 0), (0, -150)]
        let samples = offsets.map { e, n in
            (geo: frame.geoPoint(of: ENU(east: e, north: n, up: 0)).point, site: site(e, n))
        }
        let georef = try SiteGeoreference(origin: origin, samples: samples)
        #expect(georef.rms < 1e-6)

        let probe = frame.geoPoint(of: ENU(east: 37, north: -91, up: 0)).point
        let expected = site(37, -91)
        let got = georef.site(of: probe)
        #expect(abs(got.x - expected.x) < 1e-6)
        #expect(abs(got.y - expected.y) < 1e-6)
        let back = georef.geo(x: got.x, y: got.y)
        #expect(abs(back.latitude - probe.latitude) < 1e-10)
        #expect(abs(back.longitude - probe.longitude) < 1e-10)
    }

    @Test func refusesTooFewOrCollinearSamples() {
        let origin = GeoPoint(latitude: 37.77, longitude: -122.47)
        #expect(throws: SiteGeoreference.FitError.tooFewSamples) {
            try SiteGeoreference(origin: origin, samples: [(origin, .zero)])
        }
        let frame = LocalFrame(origin: origin)
        let line = [0.0, 10, 20].map {
            (geo: frame.geoPoint(of: ENU(east: $0, north: 0, up: 0)).point, site: SIMD2($0, 0))
        }
        #expect(throws: SiteGeoreference.FitError.self) { try SiteGeoreference(origin: origin, samples: line) }
    }
}

@Suite struct TreeDetectorTests {
    @Test func theMedianOfEightMatchesSorting() {
        var random = SystemRandomNumberGenerator()
        for trial in 0..<2_000 {
            // Plenty of ties: canopy heights are often 0 or repeat.
            let values = (0..<8).map { _ in
                trial.isMultiple(of: 3) ? Float(Int.random(in: 0...3, using: &random)) : Float.random(in: -5...40)
            }
            let sorted = values.sorted()
            let median = TreeDetector.median(
                values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7])
            #expect(median == (sorted[3] + sorted[4]) / 2)
        }
    }

    /// A flat 120 m square of ground at 90 m with cone-shaped crowns of points at known places.
    static func forest(
        _ trees: [(x: Double, y: Double, height: Double, radius: Double)], building: Bool = false
    )
        -> (points: [PointBlock], ground: Heightfield)
    {
        let ground = Heightfield(
            origin: Vector3(x: -60, y: -60, z: 0), cellSize: 1, nx: 121, ny: 121,
            z: [Float](repeating: 90, count: 121 * 121))
        var block = PointBlock()
        var random = SystemRandomNumberGenerator()
        _ = random
        func add(_ x: Double, _ y: Double, _ z: Double, _ c: UInt32) {
            block.x.append(Float(x))
            block.y.append(Float(y))
            block.z.append(Float(z))
            block.classification.append(c)
        }
        // Ground returns every 0.7 m.
        for i in stride(from: -60.0, through: 60, by: 0.7) {
            for j in stride(from: -60.0, through: 60, by: 0.7) { add(i, j, 90, 2) }
        }
        // Crowns: points every 0.35 m inside the radius, height falling off as a cone from the top.
        for tree in trees {
            for i in stride(from: -tree.radius, through: tree.radius, by: 0.35) {
                for j in stride(from: -tree.radius, through: tree.radius, by: 0.35) {
                    let d = (i * i + j * j).squareRoot()
                    guard d <= tree.radius else { continue }
                    let h = tree.height * (1 - 0.45 * d / tree.radius)
                    add(tree.x + i, tree.y + j, 90 + h, 1)
                }
            }
        }
        if building {
            for i in stride(from: 20.0, through: 35, by: 0.35) {
                for j in stride(from: -35.0, through: -20, by: 0.35) { add(i, j, 102, 1) }
            }
        }
        return ([block], ground)
    }

    static let truth: [(x: Double, y: Double, height: Double, radius: Double)] = [
        (-30, -30, 25, 5), (-12, -28, 18, 4), (10, 15, 32, 7), (25, 30, 12, 3), (-35, 20, 8, 2.5), (0, -5, 20, 4.5),
    ]

    @Test func findsEachTreeWithItsHeightAndCrown() {
        let (points, ground) = Self.forest(Self.truth)
        let found = TreeDetector().detect(points: points, ground: ground)
        #expect(found.count == Self.truth.count, "found \(found.count)")
        for tree in Self.truth {
            let nearest = found.min { lhs, rhs in
                hypot(lhs.x - tree.x, lhs.y - tree.y) < hypot(rhs.x - tree.x, rhs.y - tree.y)
            }
            guard let nearest else { continue }
            #expect(hypot(nearest.x - tree.x, nearest.y - tree.y) < 1.0)
            #expect(abs(nearest.height - tree.height) < 0.5, "height \(nearest.height) for \(tree.height)")
            #expect(abs(nearest.crownRadius - tree.radius) < 1.5, "crown \(nearest.crownRadius) for \(tree.radius)")
            #expect(abs(nearest.ground - 90) < 0.01)
            #expect((0...1).contains(nearest.confidence))
        }
    }

    @Test func masksBuildingsAndIgnoresShortStuffAndGround() {
        let shrub = [(x: 40.0, y: 40.0, height: 2.5, radius: 2.0)]
        let (points, ground) = Self.forest(Self.truth + shrub, building: true)
        let outline: [SIMD2<Double>] = [SIMD2(19, -36), SIMD2(36, -36), SIMD2(36, -19), SIMD2(19, -19)]
        let found = TreeDetector().detect(points: points, ground: ground, buildings: [outline])
        #expect(found.count == Self.truth.count)
        #expect(!found.contains { $0.x > 19 && $0.x < 36 && $0.y > -36 && $0.y < -19 })
        let unmasked = TreeDetector().detect(points: points, ground: ground)
        #expect(unmasked.count == Self.truth.count + 1, "the flat roof reads as one 'tree' without the mask")
    }

    @Test func dropsTreesAtTheEdgeOfTheData() {
        let (points, ground) = Self.forest([(x: 57, y: 0, height: 20, radius: 4), (x: 0, y: 0, height: 20, radius: 4)])
        let found = TreeDetector().detect(points: points, ground: ground)
        #expect(found.count == 1)
        #expect(abs(found[0].x) < 1)
    }
}

@Suite struct ScanRegistrationTests {
    @Test func sensorFrameIsARKitTurnedZUp() {
        let ar = SIMD3<Float>(3, 1.4, -4)  // 3 m east, 4 m north, 1.4 m up
        let s = ScanRegistration.sensorPoint(fromARKit: ar)
        #expect(s == SIMD3(3, 4, 1.4))
        #expect(ScanRegistration.arkitPoint(fromSensor: s) == ar)
    }

    @Test func scanPointsAreThinnedRangedAndDeterministic() {
        var points: [SIMD3<Float>] = []
        for k in 0..<1000 {
            points.append(SIMD3(Float(k % 10) * 0.01, 0, Float(k / 10) * 0.01))  // a 0.1 m × 1 m patch, 1 cm apart
        }
        points.append(SIMD3(100, 0, 0))  // out of range
        let block = ScanRegistration.scanPoints(fromARKit: points, voxel: 0.1, maxRange: 60)
        #expect(block.count == 10)
        #expect(!block.x.contains(100))
        #expect(ScanRegistration.scanPoints(fromARKit: points.reversed(), voxel: 0.1) == block)
    }

    @Test func hintPutsTheOriginBehindTheCamera() throws {
        let gps = GeoPoint(latitude: 37.7697, longitude: -122.4757)
        // The camera has walked 3 m east and 4 m north of where the session started.
        let hint = ScanRegistration.hint(
            gps: gps, camera: SIMD3(3, 0.2, -4), groundBelowOrigin: -1.45, northAligned: true)
        let origin = GeoPoint(latitude: hint.position.latitude, longitude: hint.position.longitude)
        let enu = LocalFrame(origin: gps).enu(of: origin)
        #expect(abs(enu.east + 3) < 0.001)
        #expect(abs(enu.north + 4) < 0.001)
        #expect(hint.heading == 0)
        #expect(abs((hint.mountHeight ?? 0) - 1.45) < 1e-6)
        #expect(
            ScanRegistration.hint(gps: gps, camera: .zero, groundBelowOrigin: nil, northAligned: false).heading == nil)
    }

    @Test func registeredScanPlacesARKitPoints() throws {
        var w = ProtoWriter()
        w.string(1, "gms:01")
        w.enumValue(5, RegistrationState.candidate.rawValue)
        w.message(6) { h in
            h.string(1, "h1")
            h.message(2, SensorPose(translation: Vector3(x: 60, y: -60, z: 110.6), rotation: .yaw(25 * .pi / 180)))
            h.message(3) { s in s.double(6, 0.3) }
        }
        let registration = try Registration(serialized: w.data)
        let origin = GeoPoint(latitude: 37.769652, longitude: -122.475737)
        let frame = LocalFrame(origin: origin)
        let samples = [(0.0, 0.0), (100, 0), (0, 100)].map { e, n in
            (geo: frame.geoPoint(of: ENU(east: e, north: n, up: 0)).point, site: SIMD2(e, n))
        }
        let placed = try #require(
            RegisteredScan(registration, georeference: try SiteGeoreference(origin: origin, samples: samples)))
        #expect(placed.sigma == 0.3)
        #expect(placed.passedGates)
        // 10 m north in the sensor frame (ARKit −z) is rotated 25° counter-clockwise.
        let site = placed.site(ofARKit: SIMD3(0, 0, -10))
        #expect(abs(site.x - (60 - 10 * sin(25 * .pi / 180))) < 1e-9)
        #expect(abs(site.y - (-60 + 10 * cos(25 * .pi / 180))) < 1e-9)
        let position = placed.position(ofARKit: SIMD3(0, 0, -10))
        let enu = frame.enu(of: position.geo)
        #expect(abs(enu.east - site.x) < 0.001)
        #expect(abs(position.covariance.horizontalSigma - 0.3) < 1e-9)
    }
}
