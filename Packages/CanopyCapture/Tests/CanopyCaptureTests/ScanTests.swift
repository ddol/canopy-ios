import CanopyModel
import Foundation
import Testing
import simd

@testable import CanopyCapture

@Suite struct MeshAccumulatorTests {
    /// A scan region around the front of a trunk of radius 0.3 m standing at the origin.
    func makeAccumulator() -> MeshAccumulator {
        MeshAccumulator(
            center: SIMD3(0, 1.37, -0.3), radius: TrunkScan.radius, below: TrunkScan.below, above: TrunkScan.above)
    }

    let anchorA = UUID()
    let anchorB = UUID()

    func trunk(facing: Double, spacing: Double = 0.03, ground: Bool = false, seed: UInt64 = 1) -> Mesh {
        Synthetic.scannedTrunk(
            radius: 0.3, leanDegrees: 0, visibleDegrees: 200, seed: seed, facingDegrees: facing, spacing: spacing,
            includeGround: ground)
    }

    @Test func aCoarserUpdateDoesNotReplaceCapturedDetail() {
        var accumulator = makeAccumulator()
        accumulator.add(trunk(facing: -90), anchor: anchorA, transform: matrix_identity_float4x4)
        let fine = accumulator.mesh().triangleCount
        accumulator.add(trunk(facing: -90, spacing: 0.12), anchor: anchorA, transform: matrix_identity_float4x4)
        #expect(accumulator.mesh().triangleCount == fine)
        #expect(accumulator.updateCount == 2)
    }

    @Test func aFinerUpdateReplacesACoarseOne() {
        var accumulator = makeAccumulator()
        accumulator.add(trunk(facing: -90, spacing: 0.12), anchor: anchorA, transform: matrix_identity_float4x4)
        let coarse = accumulator.mesh().triangleCount
        accumulator.add(trunk(facing: -90), anchor: anchorA, transform: matrix_identity_float4x4)
        #expect(accumulator.mesh().triangleCount > 4 * coarse)
    }

    @Test func partsMissingFromALaterUpdateAreKept() {
        var accumulator = makeAccumulator()
        accumulator.add(trunk(facing: -90), anchor: anchorA, transform: matrix_identity_float4x4)
        let front = accumulator.mesh().triangleCount
        // The same anchor, re-meshed as you walk round: now only the back is in it.
        accumulator.add(trunk(facing: 90), anchor: anchorA, transform: matrix_identity_float4x4)
        #expect(accumulator.mesh().triangleCount > front)
        let progress = TrunkScan.progress(
            world: accumulator.mesh(), floorHeights: [0], center: SIMD3(0, 1.37, -0.3))
        #expect((progress.arcDegrees ?? 0) > 330)
    }

    @Test func keptDetailFollowsTheAnchorWhenARKitMovesIt() throws {
        var accumulator = makeAccumulator()
        accumulator.add(trunk(facing: -90), anchor: anchorA, transform: matrix_identity_float4x4)
        let before = accumulator.mesh()
        var moved = matrix_identity_float4x4
        moved.columns.3 = SIMD4(0.05, 0, 0, 1)
        accumulator.add(.empty, anchor: anchorA, transform: moved)
        let after = accumulator.mesh()
        #expect(after.triangleCount == before.triangleCount)
        let shift = try #require(after.bounds).min.x - (try #require(before.bounds)).min.x
        #expect(abs(shift - 0.05) < 1e-4)
    }

    @Test func overlappingAnchorsAreNotDoubled() {
        var accumulator = makeAccumulator()
        accumulator.add(trunk(facing: -90), anchor: anchorA, transform: matrix_identity_float4x4)
        let single = accumulator.mesh().triangleCount
        accumulator.add(trunk(facing: -90, seed: 2), anchor: anchorB, transform: matrix_identity_float4x4)
        #expect(accumulator.triangleCount > single)  // both kept…
        // …but each cell of space comes from one anchor, so the surface is not doubled.
        let merged = accumulator.mesh().triangleCount
        #expect(abs(merged - single) < single / 10, "\(merged) vs \(single)")
    }

    @Test func onlyTheRegionIsKeptAndCornersAreWelded() throws {
        var accumulator = makeAccumulator()
        var far = trunk(facing: -90)
        far.positions = far.positions.map { $0 + SIMD3(10, 0, 0) }
        accumulator.add(far, anchor: anchorA, transform: matrix_identity_float4x4)
        #expect(accumulator.isEmpty)

        accumulator.add(trunk(facing: -90), anchor: anchorB, transform: matrix_identity_float4x4)
        let mesh = accumulator.mesh()
        #expect(mesh.vertexCount < mesh.triangleCount)  // shared corners welded, not three per triangle
        let bounds = try #require(mesh.bounds)
        #expect(bounds.min.y >= 1.37 - TrunkScan.below - 1e-4)
        #expect(bounds.max.y <= 1.37 + TrunkScan.above + 1e-4)
    }

    @Test func floorHeightsComeFromTheLatestUpdateInsideTheRegion() {
        var accumulator = makeAccumulator()
        var lifted = matrix_identity_float4x4
        lifted.columns.3 = SIMD4(0, 0.2, 0, 1)
        accumulator.add(
            .empty, anchor: anchorA, transform: matrix_identity_float4x4, floor: [SIMD3(0, 0, -1), SIMD3(9, 0, 9)])
        #expect(accumulator.floorHeights() == [0])
        accumulator.add(.empty, anchor: anchorA, transform: lifted, floor: [SIMD3(0, 0, -1)])
        #expect(accumulator.floorHeights() == [0.2])
    }

    @Test func meshIsTheSameWhateverOrderCellsArrived() {
        var a = makeAccumulator()
        var b = makeAccumulator()
        a.add(trunk(facing: -90), anchor: anchorA, transform: matrix_identity_float4x4)
        a.add(trunk(facing: 90), anchor: anchorB, transform: matrix_identity_float4x4)
        b.add(trunk(facing: 90), anchor: anchorB, transform: matrix_identity_float4x4)
        b.add(trunk(facing: -90), anchor: anchorA, transform: matrix_identity_float4x4)
        #expect(a.mesh() == b.mesh())
    }
}

@Suite struct TrunkScanTests {
    let center = SIMD3<Float>(0, 1.37, -0.3)

    /// Walking round a trunk of radius 0.3 m: the front is scanned in detail, then ARKit re-meshes it coarsely
    /// while the back comes in.
    func walkedRound() -> MeshAccumulator {
        var accumulator = MeshAccumulator(
            center: center, radius: TrunkScan.radius, below: TrunkScan.below, above: TrunkScan.above)
        let anchor = UUID()
        let front = Synthetic.scannedTrunk(radius: 0.3, leanDegrees: 0, visibleDegrees: 200, facingDegrees: -90)
        accumulator.add(front, anchor: anchor, transform: matrix_identity_float4x4)
        var later = Synthetic.scannedTrunk(
            radius: 0.3, leanDegrees: 0, visibleDegrees: 200, seed: 7, facingDegrees: -90, spacing: 0.15,
            includeGround: false)
        later.append(
            Synthetic.scannedTrunk(
                radius: 0.3, leanDegrees: 0, visibleDegrees: 200, seed: 8, facingDegrees: 90, includeGround: false))
        accumulator.add(later, anchor: anchor, transform: matrix_identity_float4x4)
        return accumulator
    }

    @Test func measuresAWalkedRoundTrunkWithinOneCentimetre() throws {
        let accumulator = walkedRound()
        let capture = try TrunkScan.analyse(
            world: accumulator.mesh(), floorHeights: [], center: center, camera: SIMD3(0, 1.5, -2),
            northAligned: true)
        #expect(abs(capture.analysis.dbh.diameter.value - 0.6) < 0.01, "\(capture.analysis.dbh.diameter.value)")
        #expect(capture.analysis.circle.arc * 180 / .pi > 330)
        // The trunk's base is found at the origin, on the ground.
        #expect(simd_length(capture.trunkBase) < 0.02)
    }

    @Test func evidenceIsTheTrunkPlusAMargin() throws {
        let capture = try TrunkScan.analyse(
            world: walkedRound().mesh(), floorHeights: [], center: center, camera: .zero, northAligned: false)
        #expect(abs(capture.cropRadius - (0.3 + TrunkScan.evidenceMargin)) < 0.01)
        let bounds = try #require(capture.evidence.bounds)
        // Centred on the trunk (the origin), not on the scan centre 0.3 m away on its surface.
        #expect(abs((bounds.min.z + bounds.max.z) / 2) < 0.05)
        #expect(Double(max(-bounds.min.x, bounds.max.x)) <= capture.cropRadius + 1e-3)
        #expect(try GLB.File(capture.glb).mesh() == capture.evidence)
    }

    @Test func progressReportsTheArcCoveredSoFar() {
        var accumulator = MeshAccumulator(
            center: center, radius: TrunkScan.radius, below: TrunkScan.below, above: TrunkScan.above)
        #expect(TrunkScan.progress(world: accumulator.mesh(), floorHeights: [], center: center).arcDegrees == nil)
        accumulator.add(
            Synthetic.scannedTrunk(radius: 0.3, leanDegrees: 0, visibleDegrees: 120),
            anchor: UUID(), transform: matrix_identity_float4x4)
        let progress = TrunkScan.progress(world: accumulator.mesh(), floorHeights: [], center: center)
        #expect(abs((progress.arcDegrees ?? 0) - 120) < 15)
        #expect(abs((progress.diameter ?? 0) - 0.6) < 0.05)
        #expect(!progress.isWellCovered)
        #expect(progress.triangleCount > 0)
    }

    @Test func refusesAnEmptyScan() {
        #expect(throws: CaptureError.notEnoughMesh) {
            try TrunkScan.analyse(world: .empty, floorHeights: [], center: center, camera: .zero, northAligned: false)
        }
    }
}
