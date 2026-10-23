import CanopyModel
import Foundation
import Testing

@testable import CanopyReference

@Suite(.enabled(if: Live.enabled), .serialized) struct LiveRegistrationTests {
    /// Cuts 3DEP points around a spot, moves them into a sensor frame with a known pose, uploads them as a scan
    /// and registers it from a hint 5 m off with no heading: the server should recover the pose.
    @Test func recoversAKnownPoseFromASyntheticScan() async throws {
        let client = Live.client
        let site = try await client.preparedSite(Live.stowLake, label: "ggp-stow-lake")
        let georef = try await SiteGeoreference.fetch(for: site, client: client)

        // The first spot with ground under it and under most of the 35 m around it (not the lake).
        var chosen: (spot: SIMD2<Double>, ground: Double)?
        for candidate in [SIMD2<Double>(60, -60), SIMD2(-60, -120), SIMD2(100, 100), SIMD2(0, -170), SIMD2(-120, 150)] {
            var field: Heightfield?
            for try await chunk in client.reference(
                StreamReferenceRequest(
                    l16Token: site.l16Token, layers: [.groundMesh],
                    centre: Vector3(x: candidate.x, y: candidate.y, z: 0),
                    radius: 35))
            {
                if case .groundMesh(let f) = chunk { field = f }
            }
            guard let f = field, let z = f.height(x: candidate.x, y: candidate.y) else { continue }
            let valid = Double(f.z.filter(\.isFinite).count) / Double(max(1, f.z.count))
            if valid > 0.7 {
                chosen = (candidate, z)
                break
            }
        }
        let (spot, groundZ) = try #require(chosen)
        print("REGISTRATION spot \(spot) ground \(groundZ)")
        var reference: [PointBlock] = []
        for try await chunk in client.reference(
            StreamReferenceRequest(
                l16Token: site.l16Token, layers: [.aerialPoints], centre: Vector3(x: spot.x, y: spot.y, z: 0),
                radius: 35, voxelSize: 0.5, aerialClasses: [1, 2]))
        {
            if case .points(_, let block) = chunk { reference.append(block) }
        }
        let yaw = 25.0 * .pi / 180
        let truth = SensorPose(
            translation: Vector3(x: spot.x, y: spot.y, z: groundZ + 1.5), rotation: .yaw(yaw))
        let inverse = Quaternion.yaw(-yaw)
        var scan = PointBlock()
        for block in reference {
            for k in 0..<block.count {
                let d = Vector3(
                    x: Double(block.x[k]) - truth.translation.x, y: Double(block.y[k]) - truth.translation.y,
                    z: Double(block.z[k]) - truth.translation.z)
                guard (d.x * d.x + d.y * d.y).squareRoot() <= 35 else { continue }
                let s = inverse.rotate(d)
                scan.x.append(Float(s.x))
                scan.y.append(Float(s.y))
                scan.z.append(Float(s.z))
            }
        }
        #expect(scan.count > 5000)

        let header = ScanHeader(
            l16Token: site.l16Token, sensorID: "canopy-test", sensorModel: "canopy-synthetic",
            kind: .accumulated, captureRef: "canopy-test-synthetic-stow-lake",
            capturedAt: Date(timeIntervalSince1970: 1_792_540_800))
        let (uploaded, already) = try await client.uploadScan(header, points: scan)
        print("REGISTRATION scan \(uploaded.scanID) points \(uploaded.pointCount) alreadyStored \(already)")
        #expect(uploaded.pointCount == UInt64(scan.count))

        let hintGeo = georef.geo(x: spot.x + 4, y: spot.y - 3)
        let hint = PoseHint(
            position: GeodeticPosition(latitude: hintGeo.latitude, longitude: hintGeo.longitude), mountHeight: 1.5)
        var result: Registration?
        var stages: [String] = []
        for try await event in client.register(scanID: uploaded.scanID, hint: hint) {
            switch event {
            case .progress(let p): if stages.last != p.stage { stages.append(p.stage) }
            case .hypothesis: break
            case .finished(let registration): result = registration
            }
        }
        let registration = try #require(result)
        print("REGISTRATION \(registration.registrationID) state \(registration.state) stages \(stages)")
        for gate in registration.gates {
            print("REGISTRATION gate \(gate.name) \(gate.value) / \(gate.threshold) \(gate.passed ? "pass" : "FAIL")")
        }
        let best = try #require(registration.best)
        let pose = try #require(best.pose)
        let dx = pose.translation.x - truth.translation.x
        let dy = pose.translation.y - truth.translation.y
        let heading = best.summary?.heading ?? .nan
        print(
            "REGISTRATION best t \(pose.translation) error \((dx * dx + dy * dy).squareRoot()) m, heading \(heading)°, sigma \(best.summary?.sigmaHorizontal ?? -1)"
        )
        #expect((dx * dx + dy * dy).squareRoot() < 0.5)
        // Sensor +y is rotated 25° counter-clockwise from north: an azimuth of 335°.
        #expect(abs(heading - 335) < 2)

        let placed = try #require(RegisteredScan(registration, georeference: georef))
        // An ARKit point 10 m ahead (−z) of the origin, on the sensor's +y axis.
        let ahead = placed.site(ofARKit: SIMD3(0, 0, -10))
        let expected = truth.apply(Vector3(x: 0, y: 10, z: 0))
        #expect(abs(ahead.x - expected.x) < 0.6)
        #expect(abs(ahead.y - expected.y) < 0.6)
    }
}
