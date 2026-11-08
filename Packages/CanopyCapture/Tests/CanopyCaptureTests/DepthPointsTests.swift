import CanopyModel
import Foundation
import Testing
import simd

@testable import CanopyCapture

@Suite struct DepthPointsTests {
    /// A 4 × 3 depth map of a wall 2 m in front of the camera, principal point at the centre.
    let width = 4
    let height = 3
    let intrinsics = simd_float3x3(columns: (SIMD3(2, 0, 0), SIMD3(0, 2, 0), SIMD3(2, 1.5, 1)))

    @Test func pixelsUnprojectInFrontOfTheCameraAndThroughItsTransform() {
        let depth = [Float](repeating: 2, count: 12)
        let points = DepthFrame.unproject(
            depth: depth, confidence: nil, width: width, height: height, intrinsics: intrinsics,
            cameraTransform: matrix_identity_float4x4)
        #expect(points.count == 12)
        #expect(points.allSatisfy { abs($0.z + 2) < 1e-5 })
        // The pixel right of the principal point lands at +x; the one below it at −y.
        let right = points[1 * width + 3]
        #expect(right.x > 0 && abs(right.y - 0.5) < 1e-5)
        let below = points[2 * width + 2]
        #expect(below.y < 0)

        var moved = matrix_identity_float4x4
        moved.columns.3 = SIMD4(1, 2, 3, 1)
        let translated = DepthFrame.unproject(
            depth: depth, confidence: nil, width: width, height: height, intrinsics: intrinsics,
            cameraTransform: moved)
        #expect(translated.allSatisfy { abs($0.z - 1) < 1e-5 })
    }

    @Test func lowConfidenceFarAndEmptyPixelsAreDropped() {
        var depth = [Float](repeating: 2, count: 12)
        depth[0] = 0
        depth[1] = 9
        depth[2] = .nan
        var confidence = [UInt8](repeating: 2, count: 12)
        confidence[3] = 1
        let points = DepthFrame.unproject(
            depth: depth, confidence: confidence, width: width, height: height, intrinsics: intrinsics,
            cameraTransform: matrix_identity_float4x4)
        #expect(points.count == 8)
        let strided = DepthFrame.unproject(
            depth: [Float](repeating: 2, count: 12), confidence: nil, width: width, height: height,
            intrinsics: intrinsics, cameraTransform: matrix_identity_float4x4, stride: 2)
        #expect(strided.count == 4)
    }

    @Test func intrinsicsScaleToTheDepthResolution() {
        let full = simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 1000, 0), SIMD3(960, 720, 1)))
        let scaled = DepthFrame.intrinsics(full, from: SIMD2(1920, 1440), to: SIMD2(256, 192))
        #expect(abs(scaled[0][0] - 1000 * 256 / 1920) < 1e-3)
        #expect(abs(scaled[2][1] - 720 * 192 / 1440) < 1e-3)
    }

    @Test func theAccumulatorKeepsOneAveragedPointPerVoxelInsideTheRegion() {
        var accumulator = DepthAccumulator(center: SIMD3(0, 1.37, 0), radius: 2, below: 3, above: 4)
        accumulator.add([SIMD3(0.301, 1.0, 0.002), SIMD3(0.303, 1.004, 0.004), SIMD3(5, 1, 0), SIMD3(0, -5, 0)])
        #expect(accumulator.count == 1)
        #expect(accumulator.pointsSeen == 2)
        #expect(accumulator.frameCount == 1)
        let point = accumulator.points()[0]
        #expect(abs(point.x - 0.302) < 1e-5)
        #expect(abs(point.y - 1.002) < 1e-5)
        accumulator.add([SIMD3(0.5, 2, 0.5)])
        #expect(accumulator.count == 2)
    }

    @Test func slicesAndCropsOfPointClouds() {
        let points = [SIMD3<Float>(1, 1.36, 0), SIMD3(0, 1.45, 1), SIMD3(3, 1.37, 0), SIMD3(0, 9, 0)]
        let band = points.slice(atHeight: 1.37, halfWidth: 0.05)
        #expect(band.count == 2)
        #expect(band[0] == SIMD2(1, 0))
        let local = points.cropped(around: SIMD3(0, 1.37, 0), radius: 2, below: 3, above: 4)
        #expect(local.count == 2)
        #expect(simd_distance(local[0], SIMD3(1, -0.01, 0)) < 1e-5)
    }

    /// Points on a cylinder of radius 0.3 standing on the ground at the origin, 300° of it seen, 3 mm noise.
    func cylinderPoints(radius: Float = 0.3, noise: Float = 0.003, seed: UInt64 = 5) -> [SIMD3<Float>] {
        var random = SeededRandom(state: seed)
        var points: [SIMD3<Float>] = []
        for i in 0..<300 {
            let height = Float(i) * 0.01
            for degrees in stride(from: 0, to: 300, by: 3) {
                let angle = Float(degrees) * .pi / 180
                let r = radius + Float(random.gaussian(Double(noise)))
                points.append(SIMD3(cos(angle) * r, height, sin(angle) * r))
            }
        }
        return points
    }

    @Test func enoughDepthPointsAreFittedInsteadOfTheMesh() throws {
        let result = try TrunkAnalysis().measure(.empty, points: cylinderPoints(), groundHeight: 0)
        #expect(result.depthPointCount >= 40)
        #expect(abs(result.dbh.diameter.value - 0.6) < 0.01)
        #expect(result.circle.arc * 180 / .pi > 280)
        let lean = try #require(result.lean)
        #expect(lean.angle.value < 1)
        #expect(result.stemCenters.count == 7)
    }

    @Test func tooFewDepthPointsFallBackToTheMesh() throws {
        let mesh = Synthetic.scannedTrunk(
            radius: 0.3, leanDegrees: 0, visibleDegrees: 300, seed: 1, facingDegrees: -90, spacing: 0.03,
            includeGround: false)
        let few = Array(cylinderPoints().prefix(30))
        let result = try TrunkAnalysis().measure(mesh, points: few, groundHeight: 0)
        #expect(result.depthPointCount == 0)
        #expect(abs(result.dbh.diameter.value - 0.6) < 0.02)
    }

    @Test func progressCountsThePointsAndSaysWhereTheDiameterCameFrom() {
        let mesh = Synthetic.scannedTrunk(
            radius: 0.3, leanDegrees: 0, visibleDegrees: 300, seed: 1, facingDegrees: -90, spacing: 0.03,
            includeGround: true)
        let center = SIMD3<Float>(0, 1.37, -0.3)
        let withPoints = TrunkScan.progress(world: mesh, points: cylinderPoints(), floorHeights: [0], center: center)
        #expect(withPoints.pointCount == 30_000)
        #expect(withPoints.fromDepthPoints)
        let meshOnly = TrunkScan.progress(world: mesh, floorHeights: [0], center: center)
        #expect(meshOnly.pointCount == 0)
        #expect(!meshOnly.fromDepthPoints)
        #expect(meshOnly.diameter != nil)
    }
}
