import CanopyMap
import CanopyModel
import CanopyStore
import Foundation
import Testing

@testable import Canopy

/// The trees round the player, which the AR view asks for several times an update: only the trees in the tiles round
/// it, or inside a box of latitude and longitude round it, are placed in metres, and the answer is the same as placing
/// every tree.
@Suite struct NearbyTreesTests {
    static let park = GeoPoint(latitude: 37.7694, longitude: -122.4770)
    let here = Self.park

    /// Where the trees are looked for: the park; a corner of one of its tiles, where a circle takes in four; beside the
    /// antimeridian on Taveuni, Fiji (43 m from it), where the nearest trees are either side of it; far enough north
    /// that the box is still used (88.98°) and too far (89.5°); and 55 m from the South Pole, with trees all round it.
    static let places = [
        park, park.tile.vertices[0], GeoPoint(latitude: -16.8, longitude: 179.9996),
        GeoPoint(latitude: 88.98, longitude: -60), GeoPoint(latitude: 89.5, longitude: 0),
        GeoPoint(latitude: -89.9995, longitude: 120),
    ]

    func tree(east: Double, north: Double, status: CountStatus = .detected, from place: GeoPoint) -> Tree {
        let point = LocalFrame(origin: place).geoPoint(of: ENU(east: east, north: north, up: 0)).point
        var tree = TreeCandidate(id: UUID(), location: point, confidence: 0.9, isSynthetic: true).makeTree()
        tree.countStatus = status
        return tree
    }

    /// The nearest trees found by placing every tree in metres, as the query did before.
    func placingEveryTree(_ state: CensusState, from here: GeoPoint, within radius: Double, limit: Int) -> [UUID] {
        let frame = LocalFrame(origin: here)
        return state.trees.values.filter { $0.effectiveStatus != .removed }
            .map { ($0.id, frame.enu(of: $0.position.geo).horizontalDistance) }
            .filter { $0.1 <= radius }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    @Test(arguments: places) func theNearestTreesAreThoseFoundByPlacingEveryTree(_ here: GeoPoint) {
        // A spiral out to 300 m, every tree at its own distance, plus trees either side of 60 m on the diagonals,
        // where a box round the circle reaches furthest past it, and a removed tree close by.
        var trees = (1...2000).map { k -> Tree in
            let angle = Double(k) * 2.399963
            let distance = Double(k) * 0.15
            return tree(east: distance * sin(angle), north: distance * cos(angle), from: here)
        }
        for (east, north) in [(42.3, 42.3), (-42.5, -42.5), (42.5, -42.6), (-42.2, 42.2)] {
            trees.append(tree(east: east, north: north, from: here))
        }
        trees.append(tree(east: 1, north: 1, status: .removed, from: here))
        let state = CensusState(trees: trees)
        let tiles = CensusTiles(state)
        #expect(tiles.trees.count > 4, "the trees span several tiles")
        if abs(here.longitude) > 179.99 {
            let near = placingEveryTree(state, from: here, within: 60, limit: 2000)
            let sides = Set(near.compactMap { state.trees[$0]?.position.geo.longitude.sign })
            #expect(sides.count == 2, "trees within 60 m on both sides of the antimeridian")
        }
        for (radius, limit) in [(60.0, 8), (60.0, 2000), (120.0, 400), (250.0, 2000), (.infinity, 20)] {
            let expected = placingEveryTree(state, from: here, within: radius, limit: limit)
            for found in [
                state.trees(near: here, within: radius, limit: limit),
                state.trees(near: here, within: radius, limit: limit, tiles: tiles),
            ] {
                #expect(found.map(\.0.id) == expected)
                #expect(found.allSatisfy { $0.1 <= radius })
            }
        }
    }

    @Test func theBoxRoundACircleHoldsAllOfItAndNotMuchMore() throws {
        let frame = LocalFrame(origin: here)
        let box = try #require(CensusState.box(around: here, radius: 60))
        for degrees in stride(from: 0.0, to: 360, by: 15) {
            let bearing = degrees * .pi / 180
            let edge = frame.geoPoint(of: ENU(east: 60 * sin(bearing), north: 60 * cos(bearing), up: 0)).point
            let far = frame.geoPoint(of: ENU(east: 200 * sin(bearing), north: 200 * cos(bearing), up: 0)).point
            #expect(box.contains(edge))
            #expect(!box.contains(far))
        }
        #expect(CensusState.box(around: here, radius: .infinity) == nil)
    }
}

/// The cell the player stands in, which the AR view counts twice an update: from the census by tile, the same counts
/// as going through every tree.
@MainActor
@Suite struct CellCensusTests {
    @Test func aCellsCountsAreThoseOfTheTreesInIt() async throws {
        let model = AppModel(
            store: try LocalStore.inMemory(),
            player: Player(id: PlayerID(rawValue: "T:_test"), alias: "Test", source: .gameCenter))
        await model.load()
        let first = try #require(model.census.trees.values.first)
        await model.confirm(first)
        let cells = Set(model.census.trees.values.map(\.position.tile))
        #expect(cells.count > 1)
        for cell in cells {
            let trees = model.census.trees.values.filter { $0.position.tile == cell }
            let counts = model.cellCensus(cell)
            #expect(counts.detected == trees.filter { $0.effectiveStatus == .detected }.count)
            #expect(
                counts.confirmed
                    == trees.filter { [.proposed, .confirmed, .verified].contains($0.effectiveStatus) }.count)
            #expect(counts.rejected == trees.filter { $0.effectiveStatus == .removed }.count)
        }
        #expect(model.cellCensus(first.position.tile).confirmed >= 1)
        let spot = GeoPoint(latitude: 37.80, longitude: -122.40)
        let empty = spot.tile
        #expect(model.cellCensus(empty).detected == 0)
        #expect(model.cellCensus(empty).confirmed == 0)

        // A tree added there is in the census by tile as soon as it is saved: counted in its cell, and found nearby.
        await model.addTree(at: Position(geo: spot, covariance: .isotropic(horizontal: 3, vertical: 3)))
        #expect(model.cellCensus(empty).confirmed == 1)
        let found = model.census.trees(near: spot, within: 60, limit: 8, tiles: model.censusTiles)
        #expect(found.first?.0.position.geo == spot)
    }
}
