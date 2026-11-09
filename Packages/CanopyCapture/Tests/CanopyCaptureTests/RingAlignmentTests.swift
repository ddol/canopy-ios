import CanopyModel
import Foundation
import Testing
import simd

@testable import CanopyCapture

extension Synthetic {
    /// A camera at `eye` looking at `target`, level (its x axis horizontal), with ARKit's conventions.
    static func camera(
        at eye: SIMD3<Double>, lookingAt target: SIMD3<Double>, size: SIMD2<Int> = SIMD2(640, 480),
        focal: Float = 500
    ) -> CameraPose {
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        let transform = simd_float4x4(
            columns: (
                SIMD4(SIMD3<Float>(right), 0), SIMD4(SIMD3<Float>(up), 0), SIMD4(SIMD3<Float>(-forward), 0),
                SIMD4(SIMD3<Float>(eye), 1)
            ))
        let intrinsics = simd_float3x3(
            columns: (SIMD3(focal, 0, 0), SIMD3(0, focal, 0), SIMD3(Float(size.x) / 2, Float(size.y) / 2, 1)))
        return CameraPose(intrinsics: intrinsics, transform: transform, imageSize: size)
    }

    /// What `camera` sees of a trunk: a dark stem whose horizontal sections are circles of `radius` round `centre`
    /// moved `lean` per metre up, 20 m tall, against a lighter background that varies across the view. Four
    /// samples a pixel, with a little noise.
    static func trunkImage(
        _ camera: CameraPose, centre: SIMD2<Double>, radius: Double, lean: SIMD2<Double> = .zero, seed: UInt64 = 1
    ) -> GrayImage {
        var random = SeededRandom(state: seed)
        let world = CameraPose.double(camera.transform)
        let eye = camera.position
        let fx = Double(camera.intrinsics[0][0])
        let fy = Double(camera.intrinsics[1][1])
        let cx = Double(camera.intrinsics[2][0])
        let cy = Double(camera.intrinsics[2][1])
        let o = SIMD2(eye.x - centre.x - lean.x * eye.y, eye.z - centre.y - lean.y * eye.y)
        func hits(_ u: Double, _ v: Double) -> Bool {
            let local = world * SIMD4((u - cx) / fx, -(v - cy) / fy, -1, 0)
            let d = SIMD2(local.x - lean.x * local.y, local.z - lean.y * local.y)
            let a = simd_dot(d, d)
            let b = 2 * simd_dot(o, d)
            let c = simd_dot(o, o) - radius * radius
            let discriminant = b * b - 4 * a * c
            guard discriminant >= 0, a > 0 else { return false }
            let t = (-b - discriminant.squareRoot()) / (2 * a)
            let y = eye.y + t * local.y
            return t > 0 && y >= 0 && y <= 20
        }
        var pixels = [UInt8](repeating: 0, count: camera.imageSize.x * camera.imageSize.y)
        for j in 0..<camera.imageSize.y {
            for i in 0..<camera.imageSize.x {
                let background = 175 + 20 * sin(Double(i) / 37) + 10 * cos(Double(j) / 23)
                var total = 0.0
                for (du, dv) in [(-0.25, -0.25), (0.25, -0.25), (-0.25, 0.25), (0.25, 0.25)] {
                    total += hits(Double(i) + du, Double(j) + dv) ? 70 : background
                }
                let value = total / 4 + random.gaussian(2)
                pixels[j * camera.imageSize.x + i] = UInt8(min(max(value.rounded(), 0), 255))
            }
        }
        return GrayImage(width: camera.imageSize.x, height: camera.imageSize.y, pixels: pixels)
    }

    /// A camera `distance` metres from `centre` on a bearing (degrees from +x towards +z), at 1.5 m, looking at the
    /// trunk `height` metres up.
    static func cameraRound(
        _ centre: SIMD2<Double>, bearing: Double, distance: Double = 5, height: Double
    ) -> CameraPose {
        let angle = bearing * .pi / 180
        let eye = SIMD3(centre.x + cos(angle) * distance, 1.5, centre.y + sin(angle) * distance)
        return camera(at: eye, lookingAt: SIMD3(centre.x, height, centre.y))
    }
}

@Suite struct RingAlignmentTests {
    @Test func aPointProjectsToItsPixelAndTheRayThroughItPointsBack() throws {
        let camera = Synthetic.camera(at: SIMD3(1, 1.5, 6), lookingAt: SIMD3(0, 4, 0))
        let point = SIMD3(0.3, 5.0, -0.2)
        let pixel = try #require(camera.project(point))
        #expect(camera.contains(pixel, margin: 0))
        let ray = camera.ray(through: pixel)
        #expect(simd_length(simd_cross(ray, simd_normalize(point - camera.position))) < 1e-6)
        // Behind the camera: nowhere in the image.
        #expect(camera.project(SIMD3(2, 1.5, 12)) == nil)
    }

    @Test func aRenderedTrunksEdgesAreFoundWhereItsSilhouetteFalls() throws {
        let camera = Synthetic.camera(at: SIMD3(0, 1.5, 5), lookingAt: SIMD3(0, 5, 0))
        let image = Synthetic.trunkImage(camera, centre: .zero, radius: 0.25)
        let edges = try #require(RingAligner.edges(of: SIMD3(0, 5, 0), radius: 0.25, camera: camera, image: image))
        // Where lines from the camera graze the ring at 5 m: about ±0.25 m across the view.
        let distance = 5.0
        let sine = (1 - pow(0.25 / distance, 2)).squareRoot()
        let grazing = [-1.0, 1.0].map { side in
            SIMD3(side * 0.25 * sine, 5, 0.25 * 0.25 / distance)
        }
        let expected = try grazing.map { try #require(camera.project($0)) }
        for (found, wanted) in zip(edges.sorted { $0.x < $1.x }, expected.sorted { $0.x < $1.x }) {
            #expect(simd_distance(found, wanted) < 0.75)
        }
    }

    @Test func oneViewpointWidensARingPredictedTooThin() throws {
        let id = UUID()
        var aligner = RingAligner(targets: [
            RingAligner.Target(
                id: id, centre: SIMD3(0.02, 5, -0.03), radius: 0.18, centreSigma: 0.05, radiusSigma: 0.05)
        ])
        let camera = Synthetic.cameraRound(.zero, bearing: 90, height: 5)
        #expect(aligner.add(camera, image: Synthetic.trunkImage(camera, centre: .zero, radius: 0.25)) == 1)
        let fit = try #require(aligner.fit(id))
        #expect(abs(fit.radius - 0.25) < 0.01)
        #expect(fit.views == 1)
        #expect(fit.lines == 2)
        #expect(fit.radiusUncertainty < 0.02)
    }

    @Test func viewpointsRoundTheTrunkFixItsCentreAndRadius() throws {
        let id = UUID()
        let truth = SIMD2(0.0, 0.0)
        var aligner = RingAligner(targets: [
            RingAligner.Target(
                id: id, centre: SIMD3(0.06, 6, -0.05), radius: 0.32, centreSigma: 0.15, radiusSigma: 0.1)
        ])
        for (index, bearing) in [0.0, 70, 140, 210].enumerated() {
            let camera = Synthetic.cameraRound(truth, bearing: bearing, height: 6)
            let image = Synthetic.trunkImage(camera, centre: truth, radius: 0.22, seed: UInt64(index + 1))
            #expect(aligner.add(camera, image: image) == 1)
        }
        let fit = try #require(aligner.fit(id))
        #expect(fit.views == 4)
        #expect(simd_distance(fit.centre, truth) < 0.01)
        #expect(abs(fit.radius - 0.22) < 0.01)
    }

    @Test func aLeaningTrunkIsFollowedUpItsAxis() throws {
        // Leaning 5° towards +x: 44 cm over at 5 m.
        let lean = SIMD2(tan(5 * Double.pi / 180), 0)
        let truth = lean * 5
        let id = UUID()
        var aligner = RingAligner(
            targets: [
                RingAligner.Target(
                    id: id, centre: SIMD3(truth.x - 0.04, 5, 0.03), radius: 0.2, centreSigma: 0.1, radiusSigma: 0.05)
            ], axis: SIMD3(lean.x, 1, 0))
        for (index, bearing) in [30.0, 100, 170].enumerated() {
            let camera = Synthetic.cameraRound(truth, bearing: bearing, height: 5)
            let image = Synthetic.trunkImage(camera, centre: .zero, radius: 0.18, lean: lean, seed: UInt64(index + 7))
            #expect(aligner.add(camera, image: image) == 1)
        }
        let fit = try #require(aligner.fit(id))
        #expect(simd_distance(fit.centre, truth) < 0.015)
        #expect(abs(fit.radius - 0.18) < 0.01)
    }

    @Test func aStrayEdgeIsDroppedAndTheRestAgree() throws {
        let centre = SIMD2(1.0, 2.0)
        let radius = 0.3
        var lines: [RingAligner.Line] = []
        for bearing in stride(from: 0.0, to: 360, by: 60) {
            let angle = bearing * .pi / 180
            let normal = SIMD2(cos(angle), sin(angle))
            lines.append(RingAligner.Line(normal: normal, offset: simd_dot(normal, centre) - radius, sigma: 0.005))
        }
        lines[2].offset += 0.1  // a branch beside the trunk taken for its edge
        let prior = RingAligner.Target(
            id: UUID(), centre: SIMD3(1.05, 4, 2.04), radius: 0.25, centreSigma: 0.2, radiusSigma: 0.1)
        let solution = try #require(RingAligner.solve(lines, prior: prior))
        #expect(solution.kept == [true, true, false, true, true, true])
        #expect(simd_distance(solution.centre, centre) < 0.002)
        #expect(abs(solution.radius - radius) < 0.002)
    }

    @Test func aRingOutOfViewGetsNothingAndStandingStillAddsNoViewpoint() throws {
        let id = UUID()
        var aligner = RingAligner(targets: [
            RingAligner.Target(id: id, centre: SIMD3(0, 5, 0), radius: 0.25, centreSigma: 0.05, radiusSigma: 0.05)
        ])
        let away = Synthetic.camera(at: SIMD3(5, 1.5, 0), lookingAt: SIMD3(10, 3, 0))
        #expect(aligner.add(away, image: Synthetic.trunkImage(away, centre: .zero, radius: 0.25)) == 0)
        #expect(aligner.fit(id) == nil)
        let camera = Synthetic.cameraRound(.zero, bearing: 0, height: 5)
        let image = Synthetic.trunkImage(camera, centre: .zero, radius: 0.25)
        aligner.add(camera, image: image)
        aligner.add(camera, image: image)
        #expect(aligner.fit(id)?.views == 1)
        #expect(aligner.fit(id)?.lines == 2)
        aligner.remove(id)
        #expect(aligner.fits.isEmpty)
    }

    @Test func aFeaturelessViewFindsNoEdge() {
        let image = GrayImage(width: 64, height: 64, pixels: [UInt8](repeating: 128, count: 64 * 64))
        #expect(
            EdgeSearch.find(in: image, near: SIMD2(32, 32), along: SIMD2(1, 0), reach: 10, across: 2) == nil)
    }
}
