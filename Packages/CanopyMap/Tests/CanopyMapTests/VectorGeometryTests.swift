import CanopyReference
import Foundation
import Testing
import simd

@testable import CanopyMap

@Suite struct VectorGeometryTests {
    private func line(
        _ points: [Float], kind: FeatureKind = .building, height: Float = 8, tags: [String: String] = [:]
    ) throws -> LineFeature {
        var wire = ProtoWriter()
        wire.enumValue(2, kind.rawValue)
        wire.packedFloats(3, points)
        wire.bool(4, true)
        wire.float(5, height)
        for (key, value) in tags.sorted(by: { $0.key < $1.key }) {
            wire.message(6) {
                $0.string(1, key)
                $0.string(2, value)
            }
        }
        return try LineFeature(fields: ProtoReader.fields(ArraySlice([UInt8](wire.data))))
    }

    /// The triangles' summed area in 3D, whatever plane they lie in.
    private func area(_ face: VectorGeometry.Face) -> Float {
        stride(from: 0, to: face.triangles.count, by: 3).reduce(Float(0)) { sum, i in
            let a = face.vertices[Int(face.triangles[i])]
            let b = face.vertices[Int(face.triangles[i + 1])]
            let c = face.vertices[Int(face.triangles[i + 2])]
            return sum + simd_length(simd_cross(b - a, c - a)) / 2
        }
    }

    /// A 10 × 6 m part at ground height 40, its outline at the base (as derivation 11 sends it).
    private let partOutline: [Float] = [0, 0, 40, 10, 0, 40, 10, 6, 40, 0, 6, 40]

    @Test func boxWallWithHeightMetadataIsNotExtrudedTwice() throws {
        let wall = try line([0, 0, 40, 10, 0, 40, 10, 0, 48, 0, 0, 48])
        let faces = VectorGeometry.faces(wall, layer: .boxes)
        #expect(faces.count == 1)
        #expect(faces.first?.triangles.count == 6)
        #expect(faces.first?.vertices.map(\.z).max() == 48)
    }

    @Test func footprintHeightIsRelativeToItsGroundVertices() throws {
        let outline = try line([0, 0, 40, 10, 0, 41, 10, 10, 42, 0, 10, 41])
        let faces = VectorGeometry.faces(outline, layer: .footprints)
        #expect(faces.count == 4)
        #expect(faces.flatMap(\.vertices).map(\.z).max() == 50)
    }

    @Test func concavePolygonTriangulationPreservesAreaAndBothWindings() {
        let ring: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(3, 0, 0), SIMD3(3, 1, 0),
            SIMD3(1, 1, 0), SIMD3(1, 3, 0), SIMD3(0, 3, 0),
        ]
        for vertices in [ring, Array(ring.reversed())] {
            let face = VectorGeometry.face(vertices)
            #expect(face.triangles.count == 12)
            var area: Float = 0
            for i in stride(from: 0, to: face.triangles.count, by: 3) {
                let a = face.vertices[Int(face.triangles[i])]
                let b = face.vertices[Int(face.triangles[i + 1])]
                let c = face.vertices[Int(face.triangles[i + 2])]
                area += abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
            }
            #expect(area == 5)
        }
    }

    @Test func wallSurfaceIsOneFaceAndNeverExtruded() throws {
        // A gable end: the eaves at 46 m, the ridge at 49 m, on a wall 6 m wide.
        let wall = try line(
            [0, 0, 40, 6, 0, 40, 6, 0, 46, 3, 0, 49, 0, 0, 46], kind: .wallSurface, height: 0,
            tags: ["part": "p1", "edge": "0", "role": "gable", "top": "roofline"])
        let faces = VectorGeometry.faces(wall, layer: .buildings, wallSurfaces: true)
        #expect(faces.count == 1)
        let face = try #require(faces.first)
        #expect(face.vertices.count == 5)
        #expect(face.vertices.map(\.z).max() == 49)
        #expect(abs(area(face) - 45) < 0.001)
        // Even a stray height_m on a wall surface adds nothing: its vertices already carry their z.
        let tall = try line(wall.xyz, kind: .wallSurface, height: 12)
        #expect(
            VectorGeometry.faces(tall, layer: .buildings, wallSurfaces: true).flatMap(\.vertices).map(\.z).max() == 49)
    }

    @Test func partIsOnlyAnOutlineWhenWallSurfacesArrived() throws {
        let part = try line(partOutline, kind: .buildingPart, height: 0, tags: ["height": "9", "roof:height": "3"])
        let faces = VectorGeometry.faces(part, layer: .buildings, wallSurfaces: true)
        #expect(faces.count == 1)
        #expect(faces.first?.triangles.isEmpty == true)
        #expect(faces.flatMap(\.vertices).map(\.z).allSatisfy { $0 == 40 })
    }

    @Test func olderServerPartsAreStillExtrudedToTheirHeight() throws {
        let part = try line(partOutline, kind: .buildingPart, height: 9, tags: ["height": "9"])
        let faces = VectorGeometry.faces(part, layer: .buildings)
        #expect(faces.count == 4)
        #expect(faces.flatMap(\.vertices).map(\.z).max() == 49)
    }

    @Test func roofLidIsDrawnLikeAnyRoofPlane() throws {
        let lid = try line(
            [0, 0, 46, 10, 0, 46, 10, 6, 46, 0, 6, 46], kind: .roofPlane, height: 0,
            tags: ["part": "p1", "role": "lid"])
        let faces = VectorGeometry.faces(lid, layer: .buildings, wallSurfaces: true)
        #expect(faces.count == 1)
        #expect(faces.first.map(area) == 60)
    }

    @Test func concaveRooflineBoxWallTriangulatesInItsOwnPlane() throws {
        // Along a 30° street edge, hundreds of metres from the origin: the lower roof's eave at 46 m, a step up to
        // 52 m where a gable's slope begins, down to 49 m. Concave where the step meets the gable.
        let profile: [SIMD2<Float>] = [[0, 40], [10, 40], [10, 46], [6, 46], [3, 52], [0, 49]]
        let along = SIMD2<Float>(cos(.pi / 6), sin(.pi / 6))
        let vertices = profile.map { p -> SIMD3<Float> in
            SIMD3(150 + along.x * p.x, 80 + along.y * p.x, p.y)
        }
        let wall = try line(vertices.flatMap { [$0.x, $0.y, $0.z] }, height: 12, tags: ["top": "roofline"])
        for wall in [wall, try line(vertices.reversed().flatMap { [$0.x, $0.y, $0.z] }, height: 12)] {
            let faces = VectorGeometry.faces(wall, layer: .boxes)
            #expect(faces.count == 1)
            let face = try #require(faces.first)
            #expect(face.triangles.count == 12)
            #expect(abs(area(face) - 82.5) < 0.01)
        }
    }

    @Test func gableWallWithCollinearBaseVerticesFills() throws {
        // A wall surface stepped along its base every 2 m, so several base vertices are collinear.
        let wall: [SIMD3<Float>] = [
            [0, 0, 40], [2, 0, 40], [4, 0, 40], [6, 0, 40], [6, 0, 46], [3, 0, 49], [0, 0, 46],
        ]
        let face = VectorGeometry.face(wall)
        #expect(face.triangles.count == 15)
        #expect(abs(area(face) - 45) < 0.001)
    }

    @Test func enuBecomesEastUpSouthWithLocalHeightOrigin() {
        #expect(VectorGeometry.scenePoint(SIMD3(10, 20, 30), elevation: 25) == SIMD3(10, 5, -20))
    }

    @Test func invalidFacesDoNotProduceTriangles() {
        #expect(VectorGeometry.face([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)]).triangles.isEmpty)
        #expect(VectorGeometry.face([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, .nan)]).triangles.isEmpty)
    }
}
