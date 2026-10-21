import CanopyModel
import Foundation

/// The bundled Golden Gate Park sample data (see Fixtures/README.md).
enum ParkFixtures {
    enum LoadError: Error {
        case missing(String)
    }

    static func url(_ name: String) throws -> URL {
        guard let folder = Bundle.main.url(forResource: "ggp", withExtension: nil) else {
            throw LoadError.missing("ggp")
        }
        let url = folder.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LoadError.missing(name) }
        return url
    }

    /// The synthetic aerial tree candidates.
    static func candidates() throws -> [TreeCandidate] {
        try TreeCandidate.candidates(from: GeoJSON.decode(Data(contentsOf: url("tree-candidates.geojson"))))
    }

    /// Outer rings of the approximate park outline.
    static func boundary() throws -> [[GeoPoint]] {
        try GeoJSON.decode(Data(contentsOf: url("park-boundary.geojson"))).features
            .compactMap(\.geometry)
            .flatMap(\.polygons)
            .compactMap(\.first)
    }

    /// The sample S2 cells, as (token, corners) pairs.
    static func cells() throws -> [(token: String, corners: [GeoPoint])] {
        try GeoJSON.decode(Data(contentsOf: url("s2-cells.geojson"))).features.compactMap { feature in
            guard let token = feature.properties["token"]?.stringValue,
                let ring = feature.geometry?.polygons.first?.first
            else { return nil }
            return (token, Array(ring.dropLast()))
        }
    }
}
