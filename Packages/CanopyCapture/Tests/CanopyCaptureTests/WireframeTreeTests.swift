import CanopyModel
import Foundation
import Testing
import simd

@testable import CanopyCapture

@Suite struct WireframeTreeTests {
    let form = TreeForm(trunkDiameter: 0.5, height: 12, crownHeight: 8, crownWidth: 6)

    @Test func theFormFromADBHIsPlausibleAndInRange() {
        let form = TreeForm(dbh: DBH(diameter: Quantity(0.4, uncertainty: 0.01), method: .lidarCircleFit))
        #expect(form.trunkDiameter == 0.4)
        #expect(form.height == 10)
        #expect(form.crownHeight < form.height)
        #expect(form == form.clamped)
    }

    @Test func clampingKeepsTheCrownInsideTheTreeAndWiderThanTheTrunk() {
        let wild = TreeForm(trunkDiameter: 1.0, height: 5, crownHeight: 9, crownWidth: 0.1).clamped
        #expect(wild.crownHeight == 5)
        #expect(wild.crownBase == 0)
        #expect(wild.crownWidth == 1.0)
        #expect(TreeForm(trunkDiameter: 9, height: 0, crownHeight: 0, crownWidth: 1).clamped.trunkDiameter == 2.5)
    }

    @Test func theFigureStandsOnTheGroundAndReachesTheHeightAndWidth() {
        let figure = WireframeTree.figure(form)
        let points = (figure.trunk + figure.crown).flatMap { [$0.from, $0.to] }
        let ys = points.map(\.y)
        #expect(abs(ys.min()!) < 1e-5)
        #expect(abs(ys.max()! - 12) < 1e-4)
        let crownRadius = figure.crown.map { simd_length(SIMD2($0.from.x, $0.from.z)) }.max()!
        #expect(abs(crownRadius - 3) < 1e-4)
        let trunkRadius = figure.trunk.map { simd_length(SIMD2($0.from.x, $0.from.z)) }.max()!
        #expect(abs(trunkRadius - 0.25) < 1e-4)
    }

    @Test func theTrunkHasARingAtBreastHeightAndTheCrownBase() {
        let heights = Set(WireframeTree.figure(form).trunk.map { ($0.from.y * 1000).rounded() / 1000 })
        #expect(heights.contains(0))
        #expect(heights.contains(1.37))
        #expect(heights.contains(4))
    }

    @Test func aLeanTiltsTheTrunkTowardItsAzimuthAndCarriesTheCrown() {
        // 10° toward east (+x in ARKit's heading-aligned frame).
        let lean = Lean(angle: Quantity(10, uncertainty: 1), azimuth: Quantity(90, uncertainty: 5))
        let figure = WireframeTree.figure(form, lean: lean)
        let topRing = figure.crown.filter { abs($0.from.y - 12) < 1e-4 }
        let centreX = topRing.map(\.from.x).reduce(0, +) / Float(topRing.count)
        let centreZ = topRing.map(\.from.z).reduce(0, +) / Float(topRing.count)
        #expect(abs(centreX - 12 * tan(10 * Float.pi / 180)) < 1e-3)
        #expect(abs(centreZ) < 1e-3)
        // Without a direction the lean draws nothing different.
        #expect(
            WireframeTree.figure(form, lean: Lean(angle: Quantity(10, uncertainty: 1))) == WireframeTree.figure(form))
    }

    @Test func theMeshIsATubePerSegment() {
        let segments = [WireframeTree.Segment(from: .zero, to: SIMD3(0, 2, 0))]
        let mesh = WireframeTree.mesh(segments, width: 0.02)
        #expect(mesh.vertexCount == 8)
        #expect(mesh.triangleCount == 8)
        let bounds = mesh.bounds!
        #expect(abs(bounds.max.x - bounds.min.x - 0.02) < 1e-5)
        #expect(abs(bounds.max.y - 2) < 1e-5)
        #expect(WireframeTree.mesh([WireframeTree.Segment(from: .zero, to: .zero)]).isEmpty)
    }
}
