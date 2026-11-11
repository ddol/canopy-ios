import CanopyModel
import CanopyReference
import Foundation
import Testing
import simd

@testable import CanopyCapture

@Suite struct CrownShapeTests {
    /// Aerial returns from a crown of `shape`, with ground and grass under it and a neighbour's crown beside it.
    func points(_ shape: CrownShape, groundHeight: Double = -1.3, neighbour: Bool = true) -> [SIMD3<Float>] {
        var random = SeededRandom(state: 11)
        var points: [SIMD3<Float>] = []
        func add(_ shape: CrownShape, count: Int) {
            while points.count < count {
                let t = random.unit()
                let angle = random.unit() * 2 * .pi
                // Most returns are near the crown's surface, seen from above.
                let r = shape.radius * shape.outline.width(at: t) * (0.75 + 0.25 * random.unit())
                let height = shape.base + (shape.top - shape.base) * t
                points.append(
                    SIMD3(
                        Float(shape.centre.x + cos(angle) * r), Float(groundHeight + height),
                        Float(shape.centre.y + sin(angle) * r)))
            }
        }
        add(shape, count: 3000)
        // Grass and shrubs under it.
        for _ in 0..<500 {
            points.append(
                SIMD3(
                    Float(random.unit() * 10 - 5), Float(groundHeight + random.unit() * 0.8),
                    Float(random.unit() * 10 - 5)))
        }
        if neighbour {
            let next = CrownShape(base: 3, top: 9, radius: 3, centre: shape.centre + SIMD2(9, 0), outline: .round)
            add(next, count: points.count + 2000)
        }
        return points
    }

    @Test func aCrownIsFittedToItsPointsAndNotItsNeighbours() throws {
        let truth = CrownShape(base: 4, top: 14, radius: 4.5, centre: SIMD2(0.8, -0.5), outline: .round)
        let fitted = try #require(CrownShape.fitted(to: points(truth), groundHeight: -1.3))
        #expect(abs(fitted.base - 4) < 0.6, "\(fitted)")
        #expect(abs(fitted.top - 14) < 0.3, "\(fitted)")
        #expect(abs(fitted.radius - 4.5) < 0.6, "\(fitted)")
        #expect(simd_distance(fitted.centre, truth.centre) < 0.3, "\(fitted)")
        #expect(fitted.outline == .round)
        #expect(fitted.coverage(of: points(truth, neighbour: false).filter { $0.y > 0 }, groundHeight: -1.3) > 0.9)
    }

    @Test(arguments: CrownShape.Outline.allCases)
    func theOutlineIsTheOneThePointsFollow(_ outline: CrownShape.Outline) throws {
        let truth = CrownShape(base: 3, top: 15, radius: 3.5, outline: outline)
        let fitted = try #require(CrownShape.fitted(to: points(truth, neighbour: false), groundHeight: -1.3))
        #expect(fitted.outline == outline)
    }

    @Test func tooFewPointsFitNothing() {
        let few = (0..<10).map { SIMD3<Float>(Float($0) * 0.1, 5, 0) }
        #expect(CrownShape.fitted(to: few, groundHeight: 0) == nil)
    }

    @Test func aShapeBecomesTheProfilesCrownAndTheTrunkStays() throws {
        let profile = TreeProfile(form: TreeForm(trunkDiameter: 0.5, height: 12, crownHeight: 8, crownWidth: 6))
        let shape = CrownShape(base: 5, top: 16, radius: 5, centre: SIMD2(0.4, 0.2), outline: .cone)
        let crowned = profile.withCrown(shape)
        #expect(crowned.trunk == profile.trunk)
        #expect(crowned.crown.map(\.height) == [5, 7.75, 10.5, 13.25, 16])
        #expect(crowned.crown.first?.radius == 5)
        #expect(crowned.crown.allSatisfy { $0.offset == SIMD2(0.4, 0.2) })
        // Read back from its rings, the crown's size and place are the shape's.
        let read = try #require(CrownShape(crowned))
        #expect(read.base == 5 && read.top == 16 && read.radius == 5 && read.centre == SIMD2(0.4, 0.2))
        #expect(crowned.form.height == 16)
        #expect(crowned.form.crownWidth == 10)
    }

    @Test func aerialPointsMoveIntoTheScansFrame() throws {
        // A site frame turned 90° from east-north (x north, y west) and 100 m off.
        let origin = GeoPoint(latitude: 37.9, longitude: -122.58)
        let frame = LocalFrame(origin: origin)
        let georeference = try SiteGeoreference(
            origin: origin,
            samples: [
                (origin, SIMD2(100, 100)),
                (frame.geoPoint(of: ENU(east: 10, north: 0, up: 0)).point, SIMD2(100, 90)),
                (frame.geoPoint(of: ENU(east: 0, north: 10, up: 0)).point, SIMD2(110, 100)),
            ])
        // A point 3 m east and 2 m north of the trunk's base, 8 m above the ground there.
        let block = PointBlock(x: [102], y: [97], z: [58])
        let moved = CanopyPoints.scanFrame(
            [block], georeference: georeference, base: SIMD2(100, 100), groundElevation: 50, groundHeight: -1.3)
        let point = try #require(moved.first)
        #expect(simd_distance(point, SIMD3(3, 6.7, -2)) < 0.01, "\(point)")
        // Set on the trunk, Gerardus's tree was 1 m east of the census position: the points move with it.
        let corrected = CanopyPoints.scanFrame(
            [block], georeference: georeference, base: SIMD2(100, 100), groundElevation: 50, groundHeight: -1.3,
            correction: SIMD2(1, 0))
        #expect(simd_distance(try #require(corrected.first), SIMD3(2, 6.7, -2)) < 0.01)
    }
}
