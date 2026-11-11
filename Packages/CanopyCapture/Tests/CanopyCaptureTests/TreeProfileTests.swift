import CanopyModel
import Foundation
import Testing
import simd

@testable import CanopyCapture

@Suite struct TreeProfileTests {
    let form = TreeForm(trunkDiameter: 0.5, height: 12, crownHeight: 8, crownWidth: 6)

    @Test func aFormBecomesRingsFromTheGroundUpAndSumsBackToItself() {
        let profile = TreeProfile(form: form)
        #expect(profile.trunk.map(\.height) == [0, 1, 2, 3, 4])
        #expect(profile.crown.map(\.height) == [4, 8, 12])
        #expect(profile.trunk.allSatisfy { $0.radius == 0.25 })
        #expect(profile.crown.allSatisfy { $0.radius == 3 })
        #expect(profile.form == form)
        // Sorted by height, the trunk before the crown where they meet.
        #expect(profile.sections.map(\.part)[4...5] == [.trunk, .crown])
    }

    @Test func followingAShapeKeepsTheRingsFittedToTheTree() throws {
        var profile = TreeProfile(form: form)
        let breast = try #require(profile.trunk.first { $0.height == 1 })
        profile[breast.id] = TreeSection(
            id: breast.id, part: .trunk, height: 1, radius: 0.31, source: .scan, offset: SIMD2(0.02, -0.01))
        let taller = TreeForm(trunkDiameter: 0.5, height: 20, crownHeight: 12, crownWidth: 8)
        let followed = profile.following(taller)
        let kept = try #require(followed.section(breast.id))
        #expect(kept.radius == 0.31)
        #expect(kept.source == .scan)
        #expect(followed.trunk.filter { abs($0.height - 1) < 0.05 }.count == 1)
        #expect(followed.crown.map(\.height) == [8, 14, 20])
        // The summary reads the trunk at breast height, between the fitted ring at 1 m and the one at 2 m.
        #expect(abs(followed.form.trunkDiameter - 2 * (0.31 + (0.25 - 0.31) * 0.37)) < 1e-9)
    }

    @Test func ringsCanBeAddedBetweenAndRemovedDownToOne() throws {
        var profile = TreeProfile(form: form)
        let ground = try #require(profile.trunk.first)
        let addedID = profile.addSection(above: ground.id)
        let added = try #require(addedID)
        #expect(abs(try #require(profile.section(added)).height - 0.5) < 1e-9)
        #expect(profile.trunk.count == 6)
        for ring in profile.trunk { profile.removeSection(ring.id) }
        #expect(profile.trunk.count == 1)
        let top = try #require(profile.crown.last)
        let aboveID = profile.addSection(above: top.id)
        let above = try #require(aboveID)
        #expect(try #require(profile.section(above)).height == 13)
    }

    @Test func theProfileFigureTapersBetweenRingsAndPicksOutTheHighlightedOne() throws {
        var profile = TreeProfile(form: form)
        let ground = try #require(profile.trunk.first)
        profile[ground.id] = TreeSection(id: ground.id, part: .trunk, height: 0, radius: 0.5)
        let figure = WireframeTree.figure(profile, highlight: ground.id)
        // The highlighted ring is apart from the trunk, at the ground, half a metre out.
        #expect(figure.highlighted.count == WireframeTree.ringSegments)
        #expect(figure.highlighted.allSatisfy { abs($0.from.y) < 1e-6 })
        #expect(abs(simd_length(SIMD2(figure.highlighted[0].from.x, figure.highlighted[0].from.z)) - 0.5) < 1e-5)
        // An upright from the ground ring (0.5 m out) to the ring a metre up (0.25 m out) tapers.
        let upright = try #require(
            figure.trunk.first { abs($0.from.y) < 1e-6 && abs($0.to.y - 1) < 1e-5 })
        #expect(abs(simd_length(SIMD2(upright.from.x, upright.from.z)) - 0.5) < 1e-5)
        #expect(abs(simd_length(SIMD2(upright.to.x, upright.to.z)) - 0.25) < 1e-5)
        // A ring with its own fitted centre sits there, not on the axis.
        let breast = try #require(profile.trunk.first { $0.height == 1 })
        profile[breast.id] = TreeSection(
            id: breast.id, part: .trunk, height: 1, radius: 0.25, source: .scan, offset: SIMD2(0.3, -0.2))
        let shifted = WireframeTree.figure(profile).trunk.filter {
            abs($0.from.y - 1) < 1e-5 && $0.from.y == $0.to.y
        }
        let centre = shifted.reduce(SIMD3<Float>.zero) { $0 + $1.from } / Float(shifted.count)
        #expect(abs(centre.x - 0.3) < 1e-3)
        #expect(abs(centre.z + 0.2) < 1e-3)
    }

    @Test func markingDrawsEachRingByHowItWasSetAndCameraRingsStayPut() throws {
        var profile = TreeProfile(form: form)
        let breast = try #require(profile.trunk.first { $0.height == 1 })
        profile[breast.id] = TreeSection(id: breast.id, part: .trunk, height: 1, radius: 0.24, source: .scan)
        let aligned = TreeSection(part: .trunk, height: 3, radius: 0.22, source: .camera, offset: SIMD2(0.05, 0))
        profile[aligned.id] = aligned
        let marked = WireframeTree.figure(profile, marking: true)
        #expect(marked.marked[.scan]?.count == WireframeTree.ringSegments)
        #expect(marked.marked[.camera]?.count == WireframeTree.ringSegments)
        #expect(marked.marked[.eye] == nil)
        #expect(marked.all.count == WireframeTree.figure(profile).all.count)
        // Unmarked, they are drawn with the trunk as before.
        #expect(WireframeTree.figure(profile).marked.isEmpty)
        // A ring set from the camera is kept when the shape sliders move the rest.
        let followed = profile.following(TreeForm(trunkDiameter: 0.4, height: 14, crownHeight: 9, crownWidth: 7))
        #expect(followed.section(aligned.id) == aligned)
    }

    @Test func aRingSnapsToTheScannedTrunkAtItsHeight() throws {
        // A 0.6 m trunk scanned all the way round, as raw depth points relative to its base.
        var points: [SIMD3<Float>] = []
        var random = SeededRandom(state: 3)
        for i in 0..<4000 {
            let angle = Double(i) / 4000 * 2 * .pi * 7
            let height = Double(i) / 4000 * 3
            let r = 0.3 + random.gaussian(0.004)
            points.append(SIMD3(Float(cos(angle) * r), Float(height), Float(sin(angle) * r)))
        }
        let capture = TrunkCapture(
            analysis: TrunkAnalysis.Result(
                dbh: DBH(diameter: Quantity(0.6, uncertainty: 0.01), method: .lidarCircleFit), lean: nil,
                circle: FittedCircle(
                    center: .zero, radius: 0.3, radiusUncertainty: 0.002, centerUncertainty: 0.002,
                    rmsResidual: 0.003, arc: 2 * .pi, pointCount: 100),
                center: .zero, stemCenters: []),
            evidence: .empty, glb: Data(), cropRadius: 0.9, trunkBase: .zero, cameraPosition: SIMD3(0, 1.5, 3),
            points: points, groundHeight: 0)
        let ring = try capture.snapping(TreeSection(part: .trunk, height: 2.0, radius: 0.1))
        #expect(abs(ring.radius - 0.3) < 0.005)
        #expect(ring.source == .scan)
        #expect(simd_length(try #require(ring.offset)) < 0.01)
        #expect(throws: TrunkAnalysisError.self) {
            try capture.fitSection(at: 6)
        }
    }
}

@Suite struct TreeFittingTests {
    @Test func theShapeSlidersMoveWhileTheBreastHeightRingStaysSnapped() throws {
        let form = TreeForm(trunkDiameter: 0.5, height: 12, crownHeight: 8, crownWidth: 6)
        var profile = TreeProfile(form: form)
        let breast = try #require(profile.trunk.first { $0.height == 1 })
        profile[breast.id] = TreeSection(id: breast.id, part: .trunk, height: 1, radius: 0.31, source: .scan)
        var fitting = TreeFitting(shape: form, profile: profile)

        var wider = fitting.shape
        wider.trunkDiameter = 0.8
        fitting.reshape(wider)

        // The slider reads what it was set to, not the kept ring.
        #expect(fitting.shape.trunkDiameter == 0.8)
        // The kept ring stays; the trunk's other rings follow the slider.
        #expect(fitting.profile.section(breast.id)?.radius == 0.31)
        let others = fitting.profile.trunk.filter { $0.id != breast.id }
        #expect(!others.isEmpty)
        #expect(others.allSatisfy { $0.radius == 0.4 })
        // The summary still reads the fitted ring: at breast height, between it at 1 m and the slider's at 2 m.
        #expect(abs(fitting.profile.form.trunkDiameter - 2 * (0.31 + (0.4 - 0.31) * 0.37)) < 1e-9)
    }
}
