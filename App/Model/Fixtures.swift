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

    /// The sample S2 cells (L16 tiles and an L19 chunk), with their corners. Each feature carries its canonical
    /// token under a level-named property, `s2_l16_token` or `s2_l19_token`.
    static func cells() throws -> [(cell: S2CellID, corners: [GeoPoint])] {
        try GeoJSON.decode(Data(contentsOf: url("s2-cells.geojson"))).features.compactMap { feature in
            let token = (feature.properties["s2_l16_token"] ?? feature.properties["s2_l19_token"])?.stringValue
            guard let cell = token.flatMap(S2CellID.init(token:)), let ring = feature.geometry?.polygons.first?.first
            else { return nil }
            return (cell, Array(ring.dropLast()))
        }
    }
}
