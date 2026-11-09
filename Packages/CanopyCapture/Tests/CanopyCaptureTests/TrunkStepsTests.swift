import CanopyModel
import Foundation
import Testing
import simd

@testable import CanopyCapture

@Suite struct TrunkStepsTests {
    /// A 12 m tree whose crown starts 6 m up.
    let form = TreeForm(trunkDiameter: 0.6, height: 12, crownHeight: 6, crownWidth: 6)
    /// The trunk: 30 cm across at the ground less a centimetre a metre up, leaning 5 cm a metre towards +x.
    func radius(_ height: Double) -> Double { 0.3 - 0.01 * height }
    let lean = SIMD2(0.05, 0.0)

    /// A scan of that trunk whose depth points reach 3.2 m up, relative to its base.
    func capture() -> TrunkCapture {
        var points: [SIMD3<Float>] = []
        var random = SeededRandom(state: 5)
        for _ in 0..<6000 {
            let angle = random.unit() * 2 * .pi
            let height = random.unit() * 3.2
            let r = radius(height) + random.gaussian(0.003)
            let centre = lean * height
            points.append(SIMD3(Float(centre.x + cos(angle) * r), Float(height), Float(centre.y + sin(angle) * r)))
        }
        return TrunkCapture(
            analysis: TrunkAnalysis.Result(
                dbh: DBH(diameter: Quantity(0.57, uncertainty: 0.01), method: .lidarCircleFit), lean: nil,
                circle: FittedCircle(
                    center: .zero, radius: 0.29, radiusUncertainty: 0.002, centerUncertainty: 0.002,
                    rmsResidual: 0.003, arc: 2 * .pi, pointCount: 100),
                center: .zero, stemCenters: []),
            evidence: .empty, glb: Data(), cropRadius: 0.9, trunkBase: .zero, cameraPosition: SIMD3(0, 1.5, 3),
            points: points, groundHeight: 0)
    }

    @Test func stepsAreAMetreApartBelowTheCrownsBase() {
        #expect(TrunkSteps.heights(below: 4) == [1, 2, 3])
        #expect(TrunkSteps.heights(below: 3.2) == [1, 2])
        #expect(TrunkSteps.heights(below: 1.1).isEmpty)
    }

    @Test func theStepsTheScanReachesAreFittedToIt() throws {
        let profile = TrunkSteps.fitted(TreeProfile(form: form), to: capture(), below: form.crownBase)
        let steps = profile.trunk.filter { $0.source == .scan }
        // The breast-height ring is fitted with the steps.
        #expect(steps.map(\.height) == [1, 1.37, 2, 3])
        for ring in steps {
            #expect(abs(ring.radius - radius(ring.height)) < 0.005)
            #expect(simd_distance(try #require(ring.offset), lean * ring.height) < 0.005)
        }
        // Above 3.2 m the scan has nothing, so no ring is made up there; the ground and crown-base rings stay.
        #expect(profile.trunk.map(\.height) == [0, 1, 1.37, 2, 3, 6])
    }

    @Test func theStepsAboveArePredictedFromTheRingsBelow() throws {
        let fitted = TrunkSteps.fitted(TreeProfile(form: form), to: capture(), below: form.crownBase)
        let taper = try #require(TrunkTaper(fitted.sections))
        #expect(abs(taper.taper + 0.01) < 0.002)
        #expect(simd_distance(taper.lean, lean) < 0.003)
        #expect(taper.top == 3)

        let profile = TrunkSteps.predicted(fitted, below: form.crownBase)
        #expect(profile.trunk.map(\.height) == [0, 1, 1.37, 2, 3, 4, 5, 6])
        for height in [4.0, 5.0] {
            let ring = try #require(profile.trunk.first { $0.height == height })
            #expect(ring.source == .eye)
            #expect(abs(ring.radius - radius(height)) < 0.01)
            #expect(simd_distance(try #require(ring.offset), lean * height) < 0.02)
        }
        // The fitted steps are left as they were.
        #expect(profile.trunk.filter { $0.source == .scan } == fitted.trunk.filter { $0.source == .scan })
    }

    @Test func aTaperNeverWidensTheTrunkUpwardsNorLeansPastThirtyDegrees() throws {
        let rings = [1.0, 2.0, 3.0].map { h in
            TreeSection(part: .trunk, height: h, radius: 0.2 + 0.1 * h, source: .scan, offset: SIMD2(h, 0))
        }
        let taper = try #require(TrunkTaper(rings))
        #expect(taper.taper == TrunkTaper.tapers.upperBound)
        #expect(abs(simd_length(taper.lean) - TrunkTaper.maximumLean) < 1e-9)
        // One ring, or rings too close together: upright, no taper.
        let one = try #require(TrunkTaper([rings[1]]))
        #expect(one.lean == .zero)
        #expect(one.taper == 0)
        #expect(one.radius(at: 7) == rings[1].radius)
        // Nothing fitted: nothing to predict from.
        #expect(TrunkTaper([TreeSection(part: .trunk, height: 2, radius: 0.3)]) == nil)
    }

    @Test func theAlignerAimsAtTheRingsTheScanDidNotFitWithTheirPredictions() throws {
        let base = SIMD3<Float>(10, -1, 4)
        let profile = TrunkSteps.predicted(
            TrunkSteps.fitted(TreeProfile(form: form), to: capture(), below: form.crownBase), below: form.crownBase)
        let aligner = try #require(TrunkSteps.aligner(for: profile, base: base))
        // The steps at 4 and 5 m and the crown-base ring; not the ground ring or the fitted ones.
        let heights = aligner.targets.map { $0.centre.y - Double(base.y) }
        #expect(heights.map { ($0 * 100).rounded() / 100 } == [4, 5, 6])
        let five = try #require(aligner.targets.first { abs($0.centre.y - Double(base.y) - 5) < 1e-6 })
        #expect(abs(five.centre.x - (10 + 0.25)) < 0.02)
        #expect(abs(five.radius - radius(5)) < 0.01)
        // Further above the fitted rings, less sure.
        #expect(five.centreSigma > (aligner.targets.first?.centreSigma ?? 1))
        #expect(aligner.axis.x > 0.04)
    }

    @Test func theCamerasFitsMarkTheRingsByEyeAndLeaveTheScannedOnes() throws {
        let base = SIMD3<Float>(10, -1, 4)
        let profile = TrunkSteps.predicted(
            TrunkSteps.fitted(TreeProfile(form: form), to: capture(), below: form.crownBase), below: form.crownBase)
        let four = try #require(profile.trunk.first { $0.height == 4 })
        let two = try #require(profile.trunk.first { $0.height == 2 })
        let fit = RingAligner.Fit(
            centre: SIMD2(10.3, 4.1), radius: 0.2, radiusUncertainty: 0.004, views: 3, lines: 6)
        let aligned = TrunkSteps.applying([four.id: fit, two.id: fit], to: profile, base: base)
        let ring = try #require(aligned.section(four.id))
        #expect(ring.source == .camera)
        #expect(ring.radius == 0.2)
        #expect(simd_distance(try #require(ring.offset), SIMD2(0.3, 0.1)) < 1e-6)
        #expect(ring.isKept)
        #expect(aligned.section(two.id) == two)
    }

    @Test func thePredictedStepsAlignToWhatTheCameraSees() throws {
        // Above the scan the trunk narrows faster than the rings below say: 18 cm across at 5 m, not 25.
        let profile = TrunkSteps.predicted(
            TrunkSteps.fitted(TreeProfile(form: form), to: capture(), below: form.crownBase), below: form.crownBase)
        let five = try #require(profile.trunk.first { $0.height == 5 })
        var aligner = try #require(TrunkSteps.aligner(for: profile, base: .zero))
        for (index, bearing) in [200.0, 260, 320].enumerated() {
            let camera = Synthetic.cameraRound(lean * 5, bearing: bearing, height: 5)
            aligner.add(
                camera,
                image: Synthetic.trunkImage(camera, centre: .zero, radius: 0.18, lean: lean, seed: UInt64(index + 3)))
        }
        let aligned = TrunkSteps.applying(aligner.fits, to: profile, base: .zero)
        let ring = try #require(aligned.section(five.id))
        #expect(ring.source == .camera)
        #expect(abs(ring.radius - 0.18) < 0.01)
        #expect(simd_distance(try #require(ring.offset), lean * 5) < 0.015)
    }
}
