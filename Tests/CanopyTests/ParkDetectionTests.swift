import CanopyMap
import CanopyModel
import CanopyReference
import CanopyStore
import CanopySync
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

    @Test func aPreparedSiteWinsANearTieAndOnlyThat() throws {
        let tile = GeoPoint(latitude: 37.7694, longitude: -122.4862).tile
        let remaining = AppModel.block(around: tile)
        let first = try #require(remaining.min())
        let rival = try #require(AppModel.block(around: first).filter { $0 != tile }.sorted().first)
        // The server's own site round a tile by the first covers eight of the nine: its head start wins.
        var eight = remaining
        eight.remove(try #require(remaining.filter { $0 != first }.sorted().first))
        #expect(AppModel.nextSite(for: remaining, prepared: [rival: eight])?.site == rival)
        // Seven of them is too few.
        var seven = eight
        seven.remove(try #require(eight.filter { $0 != first }.sorted().first))
        #expect(AppModel.nextSite(for: remaining, prepared: [rival: seven])?.site == tile)
    }

    @Test func aSiteThatFailsIsSkippedWithItsTilesNotPickedAgain() throws {
        // Every site fails, as when the server stops answering: each is tried once, and the run still ends.
        let tiles = AppModel.parkTiles(try ParkFixtures.boundary())
        var remaining = tiles
        var prepared: [S2CellID: Set<S2CellID>] = [:]
        for (index, tile) in tiles.sorted().enumerated() where index % 3 == 0 {
            prepared[tile] = AppModel.block(around: tile)
        }
        var tried: Set<S2CellID> = []
        while let next = AppModel.nextSite(for: remaining, prepared: prepared) {
            #expect(!tried.contains(next.site), "\(next.site.familyDisplay) picked again after it failed")
            tried.insert(next.site)
            AppModel.skip(next.site, remaining: &remaining, prepared: &prepared)
            remaining.remove(next.first)
            if tried.count > tiles.count { break }
        }
        #expect(remaining.isEmpty)
        #expect(tried.count <= tiles.count / 3, "\(tried.count) sites for \(tiles.count) tiles")
    }

    @Test func aLoadsTilesCountAsDetectedOnlyOnceTheServerHasItsTrees() async throws {
        let model = AppModel(
            store: try LocalStore.inMemory(),
            player: Player(id: PlayerID(rawValue: "T:_test"), alias: "Test", source: .gameCenter))
        // Nothing answers here, so the trees cannot be saved.
        model.serverSettings.save(GerardusEndpoint("127.0.0.1:9"))
        let location = GeoPoint(latitude: 51.5007, longitude: -0.1246)
        let candidate = TreeCandidate(
            id: AerialTrees.stableID(location), location: location, height: 20, crownRadius: 4, confidence: 0.8,
            isSynthetic: false, source: "USGS 3DEP lidar point cloud (public-domain)")
        let result = AerialTrees.SiteResult(
            site: try Site(fields: []), candidates: [candidate], tiles: [location.tile], attribution: [], pointCount: 0)
        let saved = await model.saveDetectedTrees(result)
        #expect(saved?.hasPrefix("Not saved to the server") == true, "\(saved ?? "nil")")
        #expect(!model.detectedTiles.contains(location.tile))
        // A site with no trees has nothing for the server to take: done all the same.
        var empty = result
        empty.candidates = []
        #expect(await model.saveDetectedTrees(empty) == nil)
        #expect(model.detectedTiles.contains(location.tile))
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
