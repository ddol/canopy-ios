import CanopyCapture
import CanopyModel
import Foundation
import Testing

@testable import CanopyMap

/// What the map's work costs with a city's worth of trees: 40,000 detected trees over Golden Gate Park, as a phone
/// that has pulled the park holds. Timings are printed, not checked (a loaded machine runs slow); run them with
/// `TEST_RUNNER_CANOPY_MAP_COST=1 scripts/test.sh -only-testing:CanopyMapTests/MapLayersCostTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CANOPY_MAP_COST"] != nil))
struct MapLayersCostTests {
    static let park: CensusState = {
        var random = SystemRandomNumberGenerator()
        let trees = (0..<40_000).map { _ in
            TreeCandidate(
                id: UUID(),
                location: GeoPoint(
                    latitude: Double.random(in: 37.7655...37.7735, using: &random),
                    longitude: Double.random(in: -122.5100 ... -122.4550, using: &random)),
                confidence: 0.8, isSynthetic: false
            ).makeTree()
        }
        return CensusState(trees: trees)
    }()

    func time(_ label: String, runs: Int = 5, _ body: () -> Void) {
        var best = Duration.seconds(1000)
        for _ in 0..<runs {
            let start = ContinuousClock.now
            body()
            best = min(best, ContinuousClock.now - start)
        }
        print("cost: \(label): \(best)")
    }

    @Test func makingTheLayers() {
        let state = Self.park
        var tiles = CensusTiles(state)
        time("CensusTiles, 40,000 trees (off the main actor)", runs: 2) { tiles = CensusTiles(state) }
        let neighbourhood = MapViewport(center: GeoPoint(latitude: 37.7694, longitude: -122.4770), radius: 250)
        time("layers, the whole park") {
            _ = MapLayers(state: state, region: .goldenGatePark, detectedLimit: .max, censusTiles: tiles)
        }
        time("layers, a neighbourhood (16 tiles in full)") {
            _ = MapLayers(state: state, region: neighbourhood, detectedLimit: .max, censusTiles: tiles)
        }
        // MapScreen's chips read the counts made with the census by tile.
        time("status counts, every update") {
            _ = Dictionary(uniqueKeysWithValues: CountStatus.allCases.map { ($0, tiles.total[$0]) })
        }
        // The 3D map makes its trees' figures off the main actor; what is left on it is making the nodes, and for a
        // selection only the highlight.
        let markers = MapLayers(state: state, region: neighbourhood, detectedLimit: .max, censusTiles: tiles).trees
        var batches = WireframeTrees.Batches()
        time("3D tree figures, \(markers.count) trees (off the main actor)") {
            batches = WireframeTrees.batches(markers, forms: [:], profiles: [:]) { _ in .zero }
        }
        time("3D tree nodes, on the main thread") {
            _ = batches.meshes.values.map { $0.node(color: .gray, fill: false) }
        }
        if let selected = markers.first {
            time("3D highlight of a selected tree, on the main thread") {
                let (figure, _) = WireframeTrees.figure(selected, at: .zero, forms: [:], profiles: [:], detail: 0.5)
                var mesh = VectorMesh(place: { $0 })
                mesh.add(sceneSegments: figure.all)
                _ = mesh.node(color: .gray, fill: false)
            }
        }
    }
}
