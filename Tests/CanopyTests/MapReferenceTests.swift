import CanopyMap
import CanopyModel
import CanopyReference
import CanopyStore
import Foundation
import Testing

@testable import Canopy

@MainActor
@Suite struct MapReferenceTests {
    @Test func vectorsMapToWhatTheMapDraws() {
        #expect(AppModel.lineKind(layer: .footprints, kind: .building) == .building)
        #expect(AppModel.lineKind(layer: .boxes, kind: .building) == .wall)
        #expect(AppModel.lineKind(layer: .observed, kind: .wallPlane) == .wall)
        #expect(AppModel.lineKind(layer: .buildings, kind: .wallSurface) == .wall)
        #expect(AppModel.lineKind(layer: .buildings, kind: .buildingPart) == .building)
        #expect(AppModel.lineKind(layer: .observed, kind: .sensor) == nil)
        #expect(AppModel.lineKind(layer: .cityStreets, kind: .road) == .road)
        #expect(AppModel.lineKind(layer: .cityStreets, kind: .path) == .path)
        #expect(AppModel.lineKind(layer: .kerbs, kind: .kerb) == .kerb)
        #expect(AppModel.lineKind(layer: .streetUse, kind: .parkingSpace) == .surface)
        #expect(AppModel.lineKind(layer: .trees, kind: .tree) == nil)
        #expect(AppModel.lineKind(layer: .groundMesh, kind: .unspecified) == nil)
    }

    @Test func loadedAreasAreDrawnTogetherAndKeptAsOne() throws {
        let model = AppModel(
            store: try LocalStore.inMemory(),
            player: Player(id: PlayerID(rawValue: "T:_test"), alias: "Test", source: .gameCenter))
        #expect(model.mapReference == nil)
        let a = GeoPoint(latitude: 37.7699, longitude: -122.4757)
        let b = GeoPoint(latitude: 37.7701, longitude: -122.4750)
        model.vectorAreas["one"] = MapLayers.Reference(
            canopies: [], lines: [.init(kind: .building, points: [a, b, a], closed: true)])
        model.aerialReference = MapLayers.Reference(
            canopies: [.init(southWest: a, northEast: b, nx: 1, ny: 1, heights: [10])],
            lines: [.init(kind: .road, points: [a, b], closed: false)])
        let reference = try #require(model.mapReference)
        #expect(reference.canopies.count == 1)
        #expect(Set(reference.lines.map(\.kind)) == [.building, .road])
        // The same instance every time it is read, so the map makes its canopy images once.
        #expect(model.mapReference === reference)
    }
}
