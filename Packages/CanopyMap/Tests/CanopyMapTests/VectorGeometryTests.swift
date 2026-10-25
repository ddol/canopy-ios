import CanopyReference
import Foundation
import Testing

@testable import CanopyMap

@Suite struct VectorGeometryTests {
    private func line(_ points: [Float], kind: FeatureKind = .building, height: Float = 8) throws -> LineFeature {
        var wire = ProtoWriter()
        wire.enumValue(2, kind.rawValue)
        wire.packedFloats(3, points)
        wire.bool(4, true)
        wire.float(5, height)
        return try LineFeature(fields: ProtoReader.fields(ArraySlice([UInt8](wire.data))))
    }

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

    @Test func enuBecomesEastUpSouthWithLocalHeightOrigin() {
        #expect(VectorGeometry.scenePoint(SIMD3(10, 20, 30), elevation: 25) == SIMD3(10, 5, -20))
    }

    @Test func invalidFacesDoNotProduceTriangles() {
        #expect(VectorGeometry.face([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)]).triangles.isEmpty)
        #expect(VectorGeometry.face([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, .nan)]).triangles.isEmpty)
    }
}
