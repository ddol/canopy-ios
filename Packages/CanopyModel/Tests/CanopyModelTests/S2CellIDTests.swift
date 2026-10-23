import Foundation
import Testing

@testable import CanopyModel

@Suite struct S2CellIDTests {
    @Test(arguments: s2Vectors.map(\.name))
    func matchesReferenceImplementation(name: String) throws {
        let vector = try #require(s2Vectors.first { $0.name == name })
        let leaf = S2CellID(GeoPoint(latitude: vector.lat, longitude: vector.lng))
        #expect(leaf.rawValue == vector.leafID, "leaf id \(String(leaf.rawValue, radix: 16))")
        #expect(leaf.face == vector.face)
        #expect(leaf.level == 30)
        #expect(leaf.isLeaf)
        #expect(leaf.tile.token == vector.l16Token)
        #expect(leaf.chunk.token == vector.l19Token)
        #expect(leaf.tile.level == 16)
        #expect(leaf.chunk.level == 19)
    }

    @Test(arguments: s2Vectors.map(\.name))
    func tileGeometryMatchesReference(name: String) throws {
        let vector = try #require(s2Vectors.first { $0.name == name })
        let tile = try #require(S2CellID(token: vector.l16Token))
        let tolerance = 1e-9  // degrees, about 0.1 mm
        #expect(abs(tile.center.latitude - vector.center16.lat) < tolerance)
        #expect(angularDifference(tile.center.longitude, vector.center16.lng) < tolerance)
        #expect(tile.vertices.count == 4)
        for (vertex, expected) in zip(tile.vertices, vector.vertices16) {
            #expect(abs(vertex.latitude - expected.lat) < tolerance)
            #expect(angularDifference(vertex.longitude, expected.lng) < tolerance)
        }
    }

    @Test func tokensRoundTrip() throws {
        for vector in s2Vectors {
            let tile = try #require(S2CellID(token: vector.l16Token))
            #expect(tile.token == vector.l16Token)
            let chunk = try #require(S2CellID(token: vector.l19Token))
            #expect(tile.contains(chunk))
            #expect(!chunk.contains(tile))
            #expect(chunk.parent(level: 16) == tile)
        }
    }

    @Test(arguments: ["", "X", "zz", "80858745B", "80858745b0000000000", "f", "2"])
    func rejectsInvalidTokens(token: String) {
        // "f" is face 7 (invalid); "2" has its lowest set bit at an odd position, so it is not a cell.
        #expect(S2CellID(token: token) == nil)
    }

    @Test func faceCellsHaveShortTokens() throws {
        let face0 = try #require(S2CellID(token: "1"))
        #expect(face0.face == 0)
        #expect(face0.level == 0)
        let face4 = try #require(S2CellID(token: "9"))
        #expect(face4.face == 4)
        #expect(face4.level == 0)
    }

    @Test func codableAsToken() throws {
        let tile = try #require(S2CellID(token: "80858745b"))
        let data = try CanopyJSON.encoder.encode([tile])
        #expect(String(decoding: data, as: UTF8.self) == #"["80858745b"]"#)
        #expect(try CanopyJSON.decoder.decode([S2CellID].self, from: data) == [tile])
    }

    @Test func tileIsAboutOneHundredFiftyMetresAcrossInTheParkAndChunkAboutTwenty() throws {
        let point = GeoPoint(latitude: 37.7699, longitude: -122.4757)
        let frame = LocalFrame(origin: point.tile.center)
        let tileCorners = point.tile.vertices.map { frame.enu(of: $0) }
        let tileEdge = hypot(tileCorners[1].east - tileCorners[0].east, tileCorners[1].north - tileCorners[0].north)
        #expect((100...200).contains(tileEdge))
        let chunkCorners = point.chunk.vertices.map { frame.enu(of: $0) }
        let chunkEdge = hypot(
            chunkCorners[1].east - chunkCorners[0].east,
            chunkCorners[1].north - chunkCorners[0].north
        )
        #expect((10...25).contains(chunkEdge))
    }

    private func angularDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}
