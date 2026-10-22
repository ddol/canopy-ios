import Foundation
import Testing

@testable import CanopyModel

@Suite struct GeoJSONTests {
    let sample = """
        {
          "type": "FeatureCollection",
          "name": "sample",
          "features": [
            {
              "type": "Feature",
              "id": "17174592-bb4c-47d2-b2b8-fe45cff2dfb5",
              "geometry": { "type": "Point", "coordinates": [-122.4830626, 37.7707515] },
              "properties": { "height_m": 33.9, "crown_radius_m": 9.3, "confidence": 0.61, "synthetic": true }
            },
            {
              "type": "Feature",
              "id": 7,
              "geometry": {
                "type": "Polygon",
                "coordinates": [[[-122.51, 37.772], [-122.5, 37.764], [-122.45, 37.766], [-122.51, 37.772]]]
              },
              "properties": null
            },
            {
              "type": "Feature",
              "geometry": { "type": "LineString", "coordinates": [[-122.47, 37.77], [-122.46, 37.771]] }
            }
          ]
        }
        """

    @Test func decodesPointsPolygonsAndLines() throws {
        let collection = try GeoJSON.decode(Data(sample.utf8))
        #expect(collection.name == "sample")
        #expect(collection.features.count == 3)
        #expect(collection.features[0].geometry == .point(GeoPoint(latitude: 37.7707515, longitude: -122.4830626)))
        #expect(collection.features[1].id == "7")
        #expect(collection.features[1].properties.isEmpty)
        #expect(collection.features[1].geometry?.polygons.first?.first?.count == 4)
        #expect(collection.features[2].id == nil)
        #expect(
            collection.features[2].geometry
                == .lineString([
                    GeoPoint(latitude: 37.77, longitude: -122.47), GeoPoint(latitude: 37.771, longitude: -122.46),
                ]))
    }

    @Test func readsCandidates() throws {
        var collection = try GeoJSON.decode(Data(sample.utf8))
        collection.features = [collection.features[0]]
        let candidates = try TreeCandidate.candidates(from: collection)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.id == UUID(uuidString: "17174592-bb4c-47d2-b2b8-fe45cff2dfb5"))
        #expect(candidate.height == 33.9)
        #expect(candidate.crownRadius == 9.3)
        #expect(candidate.confidence == 0.61)
        #expect(candidate.isSynthetic)
        let tree = candidate.makeTree()
        #expect(tree.countStatus == .detected)
        #expect(tree.meta.playerID == .aerialSurvey)
        #expect(tree.height?.source == .aerialLidar)
    }

    @Test func rejectsCandidatesWithoutUUIDOrPoint() throws {
        let collection = try GeoJSON.decode(Data(sample.utf8))
        #expect(throws: GeoJSONImportError.badCandidate(index: 1, reason: "id is not a UUID")) {
            try TreeCandidate.candidates(from: collection)
        }
    }

    @Test func rejectsOutOfRangeCoordinates() {
        let bad =
            #"{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[37.7,-122.4]}}]}"#
        #expect(throws: DecodingError.self) {
            try GeoJSON.decode(Data(bad.utf8))
        }
    }
}
