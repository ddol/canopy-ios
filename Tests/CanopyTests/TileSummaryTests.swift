import CanopyMap
import CanopyModel
import CanopyReference
import Foundation
import Testing

@testable import Canopy

/// Pulling only the tiles the server's summaries say changed, and which tiles a wide view asks about.
@Suite struct TileSummaryTests {
    let a = GeoPoint(latitude: 37.7699, longitude: -122.4757).tile
    let b = GeoPoint(latitude: 37.7704, longitude: -122.4900).tile
    let c = GeoPoint(latitude: 37.7690, longitude: -122.5000).tile
    let d = GeoPoint(latitude: 37.7680, longitude: -122.5050).tile

    func counts(_ tile: S2CellID, latest: Int64) -> GerardusMapClient.TileCounts {
        var counts = GerardusMapClient.TileCounts(tile: tile)
        counts.detected = 3
        counts.latestSequence = latest
        return counts
    }

    @Test func onlyTilesThatChangedOrWereNeverPulledArePulled() {
        let followed = [a, b, c, d]
        // a is up to date, b moved on, c went back (the server's database was replaced), d was never pulled.
        let cursors: [S2CellID: Int64] = [a: 10, b: 10, c: 10]
        let summaries = [a: counts(a, latest: 10), b: counts(b, latest: 12), c: counts(c, latest: 4)]
        #expect(AppModel.tilesToPull(followed, cursors: cursors, summaries: summaries) == [b, c, d])
        // A tile the server holds nothing in: pulled only if this phone thinks it held something.
        #expect(AppModel.tilesToPull([a], cursors: [a: 0], summaries: [:]).isEmpty)
        #expect(AppModel.tilesToPull([a], cursors: [a: 7], summaries: [:]) == [a])
        // An older server gives no summaries: every tile, as before.
        #expect(AppModel.tilesToPull(followed, cursors: cursors, summaries: nil) == followed)
    }

    @Test func aWideViewAsksAboutTheTilesRoundItAndACloseOneAsksNothing() {
        let park = GeoPoint(latitude: 37.7694, longitude: -122.4770)
        #expect(AppModel.summaryTiles(around: MapViewport(center: park, radius: 60)).isEmpty)

        let wide = AppModel.summaryTiles(around: MapViewport(center: park, radius: 1200))
        #expect(wide.prefix(4).contains(park.tile), "nearest the centre first")
        #expect(wide.count > 100)
        #expect(Set(wide).count == wide.count)
        #expect(wide.allSatisfy { $0.level == S2CellID.tileLevel })

        // Zoomed out to level-13 cells: whole cells, at most one call's worth.
        let city = AppModel.summaryTiles(around: MapViewport(center: park, radius: 8000))
        #expect(city.count == GerardusMapClient.summaryBatch)
        #expect(city.contains(park.tile))
    }

    @Test func aMapZoomedOutPastTheCityAsksAboutTheSameTilesWithoutListingEveryTileInView() {
        // The Bay Area, the state and the whole globe: each listed every tile in view on the main thread (a million
        // for the Bay Area), which froze the map and ran the app out of memory. The nearest tiles are the city's.
        let park = GeoPoint(latitude: 37.7694, longitude: -122.4770)
        let city = AppModel.summaryTiles(around: MapViewport(center: park, radius: 8000))
        let zoomedOut = [
            MapViewport(center: park, radius: 60_000), MapViewport(center: park, radius: 600_000),
            MapViewport(center: park, latitudeDelta: 150, longitudeDelta: 360),
        ]
        for viewport in zoomedOut {
            let start = ContinuousClock.now
            let tiles = AppModel.summaryTiles(around: viewport)
            #expect(ContinuousClock.now - start < .seconds(10))
            #expect(tiles == city)
        }
    }

    @Test func theWholeCityIsEveryTileFromLandsEndToTheBayInAFewCalls() {
        let city = AppModel.wholeCity
        let landsEnd = GeoPoint(latitude: 37.7875, longitude: -122.5055).tile
        let ferryBuilding = GeoPoint(latitude: 37.7955, longitude: -122.3937).tile
        let excelsior = GeoPoint(latitude: 37.7240, longitude: -122.4260).tile
        let presidio = GeoPoint(latitude: 37.7989, longitude: -122.4662).tile
        for tile in [landsEnd, ferryBuilding, excelsior, presidio, a, d] {
            #expect(city.contains(tile))
        }
        #expect(city.count > 8000)
        #expect(city.count <= 5 * GerardusMapClient.summaryBatch)
        #expect(Set(city).count == city.count)
    }

    @Test func onlyTilesWithTreesStandingAreFollowed() {
        var removed = GerardusMapClient.TileCounts(tile: b)
        removed.removed = 4
        var proposed = GerardusMapClient.TileCounts(tile: c)
        proposed.proposed = 1
        let summaries = [a: counts(a, latest: 1), b: removed, c: proposed, d: GerardusMapClient.TileCounts(tile: d)]
        #expect(AppModel.tilesWithTrees(summaries) == [a, c])
    }
}
