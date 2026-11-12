import CanopyModel
import Foundation
import Testing
import simd

@testable import CanopyCapture

/// Redwoods: trunks wider than the region a scan starts with, stumps in front of them, scans of hundreds of
/// thousands of triangles.
@Suite struct BigTrunkTests {
    @Test func theRegionGrowsToTakeInABigTrunk() {
        #expect(TrunkScan.radius(forDiameter: 0.4) == TrunkScan.radius)
        #expect(abs(TrunkScan.radius(forDiameter: 3.9) - 5.1) < 1e-5)
        #expect(TrunkScan.radius(forDiameter: 12) == TrunkScan.maximumRadius)
    }

    @Test func aRedwoodFourMetresAcrossIsMeasured() throws {
        // Scanned on one side, 140° of it, starting from a point on its bark; a stump 0.8 m across stands in front.
        let radius = 2.0
        var world = StemMesh.cylinder(
            centre: SIMD2(0, -radius), radius: radius, from: -1.4, to: 4, arcDegrees: 140, startDegrees: 20)
        world.append(StemMesh.cylinder(centre: SIMD2(0.2, 1.2), radius: 0.4, from: -1.4, to: -0.4))
        world.append(StemMesh.slopedGround(at: -1.37))
        let capture = try TrunkScan.analyse(
            world: world, floorHeights: [], center: .zero, camera: SIMD3(0, 0, 3), northAligned: true,
            regionRadius: TrunkScan.radius(forDiameter: 4))
        #expect(abs(capture.analysis.dbh.diameter.value - 4) < 0.05, "\(capture.analysis.dbh.diameter.value)")
        #expect(simd_distance(capture.analysis.center, SIMD2(0, -radius)) < 0.05)
    }

    @Test func theTrunkTheScanStartedOnIsMeasuredNotTheStumpBesideIt() throws {
        // The scan starts on the near side of a trunk 1 m across; a stump 0.6 m across is 0.5 m to one side.
        var world = StemMesh.cylinder(centre: SIMD2(0, -0.5), radius: 0.5, from: -1.4, to: 2.5)
        world.append(StemMesh.cylinder(centre: SIMD2(1.2, 0.1), radius: 0.3, from: -1.4, to: 0.2))
        world.append(StemMesh.slopedGround(at: -1.37))
        let capture = try TrunkScan.analyse(
            world: world, floorHeights: [], center: .zero, camera: SIMD3(0, 0, 2), northAligned: true)
        #expect(abs(capture.analysis.dbh.diameter.value - 1) < 0.02)
    }

    @Test func aMovedRegionKeepsWhatIsInsideItAndDropsTheRest() {
        var accumulator = MeshAccumulator(center: .zero, radius: 2, below: 3, above: 6)
        let near = StemMesh.cylinder(centre: SIMD2(0, -0.5), radius: 0.4, from: 0, to: 1)
        let far = StemMesh.cylinder(centre: SIMD2(1.6, 0), radius: 0.2, from: 0, to: 1)
        var both = near
        both.append(far)
        accumulator.add(both, anchor: UUID(), transform: matrix_identity_float4x4)
        let before = accumulator.triangleCount
        accumulator.reframe(center: SIMD3(-0.5, 0, -0.5), radius: 1.2)
        #expect(accumulator.triangleCount < before)
        #expect(accumulator.triangleCount >= near.triangleCount * 9 / 10)
        accumulator.clear()
        #expect(accumulator.isEmpty)
    }

    @Test func depthPointsGetCoarserRatherThanRunningAway() {
        var depth = DepthAccumulator(center: .zero, radius: 2, below: 3, above: 6)
        depth.maximumVoxels = 1000
        var random = SeededRandom(state: 2)
        depth.add(
            (0..<5000).map { _ in
                SIMD3(Float(random.unit() * 2 - 1), Float(random.unit() * 2), Float(random.unit() * 2 - 1))
            })
        #expect(depth.count <= 1000)
        #expect(depth.voxelSize > 0.01)
    }

    @Test func aMeshTooBigToDrawIsThinnedEvenly() {
        let mesh = StemMesh.cylinder(centre: .zero, radius: 1, from: 0, to: 3)
        let thinned = mesh.thinnedIndices(to: 1000)
        #expect(thinned.count / 3 <= 1000)
        #expect(thinned.count / 3 > 800)
        #expect(mesh.thinnedIndices(to: mesh.triangleCount) == mesh.indices)
    }
}
