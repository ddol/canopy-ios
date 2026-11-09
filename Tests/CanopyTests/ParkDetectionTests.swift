import CanopyMap
import CanopyModel
import Foundation
import Testing

@testable import Canopy

@MainActor
@Suite struct ParkDetectionTests {
    @Test func theParksTilesAreTheOnesInsideItsBoundary() throws {
        let tiles = AppModel.parkTiles(try ParkFixtures.boundary())
        // Golden Gate Park is about 4 km² and a tile about 125 m across.
        #expect((150...450).contains(tiles.count), "\(tiles.count) tiles")
        #expect(tiles.contains(GeoPoint(latitude: 37.7694, longitude: -122.4862).tile))
        #expect(!tiles.contains(GeoPoint(latitude: 37.7800, longitude: -122.4700).tile))
    }

    @Test func aSiteIsItsTileAndTheEightRoundIt() {
        let tile = GeoPoint(latitude: 37.7694, longitude: -122.4862).tile
        let block = AppModel.block(around: tile)
        #expect(block.count == 9)
        #expect(block.contains(tile))
        let frame = LocalFrame(origin: tile.center)
        for neighbour in block {
            #expect(frame.enu(of: neighbour.center).horizontalDistance < 260)
        }
        // Each of them has the tile among its own 8.
        #expect(block.allSatisfy { AppModel.block(around: $0).contains(tile) })
    }

    @Test func aFewDozenWholeSitesCoverEveryParkTile() throws {
        let tiles = AppModel.parkTiles(try ParkFixtures.boundary())
        var remaining = tiles
        var covered: Set<S2CellID> = []
        var sites = 0
        while let next = AppModel.nextSite(for: remaining) {
            let block = AppModel.block(around: next.site)
            #expect(block.contains(next.first))
            covered.formUnion(block)
            remaining.subtract(block)
            sites += 1
        }
        #expect(tiles.isSubset(of: covered))
        // A 3 × 3 block per site: well under one site per three tiles.
        #expect(sites <= tiles.count / 3, "\(sites) sites for \(tiles.count) tiles")
    }

    @Test func aPreparedSiteWinsWhenItCoversAsMuch() {
        let tile = GeoPoint(latitude: 37.7694, longitude: -122.4862).tile
        let remaining = AppModel.block(around: tile)
        let neighbour = remaining.filter { $0 != tile }.sorted()[0]
        let prepared = [neighbour: AppModel.block(around: neighbour)]
        // Unprepared, the tile's own site covers all nine; prepared, a neighbour's site covering fewer wins only by its
        // head start when close.
        #expect(AppModel.nextSite(for: remaining)?.site == tile)
        let choice = AppModel.nextSite(for: remaining, prepared: prepared)
        #expect(choice != nil)
        #expect(choice?.first == remaining.min())
    }

    @Test func detectedTilesAreKeptAcrossLaunches() {
        let name = "canopy.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let tiles: Set<S2CellID> = [GeoPoint(latitude: 37.7694, longitude: -122.4862).tile]
        defaults.set(tiles.map(\.token), forKey: AppModel.detectedTilesKey)
        #expect(AppModel.savedDetectedTiles(defaults: defaults) == tiles)
    }
}
