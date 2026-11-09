import CanopyMap
import CanopyModel
import CanopyReference
import CanopyStore
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

    @Test func aViewPullsOnlyTheTilesItDrawsInFull() {
        let park = GeoPoint(latitude: 37.7694, longitude: -122.4770)
        let close = MapViewport(center: park, radius: 200)
        #expect(AppModel.drawnTiles(in: close) == MapDetail(region: close).detailed)
        #expect(AppModel.drawnTiles(in: close).count <= MapDetail.detailedTileLimit)
        #expect(AppModel.drawnTiles(in: .goldenGatePark).isEmpty)
        #expect(AppModel.drawnTiles(in: .sanFrancisco).isEmpty)
    }

    /// A sync follows the tiles drawn in full now and the pulled tiles the player has been to; a tile pulled only because
    /// an earlier version followed the whole city is left as it is.
    @MainActor
    @Test func aSyncFollowsTheTilesDrawnInFullAndThoseVisitedBefore() async throws {
        let model = AppModel(
            store: try LocalStore.inMemory(),
            player: Player(id: PlayerID(rawValue: "T:_test"), alias: "Test", source: .gameCenter))
        try await model.store.applyShared(
            [a, b, c].map { LocalStore.SharedTileUpdate(tile: $0, sequence: 1, content: .snapshot([])) })
        model.visitedTiles = [a]
        #expect(try await model.followedTiles() == [a])
        model.mapViewport = MapViewport(center: d.center, radius: 60)
        let followed = try await model.followedTiles()
        #expect(followed.contains(a) && followed.contains(d))
        #expect(!followed.contains(b) && !followed.contains(c))
        #expect(model.visitedTiles.contains(d), "a tile drawn in full is remembered as visited")
        model.mapViewport = .sanFrancisco
        let city = try await model.followedTiles()
        #expect(!city.contains(b), "the whole city is shaded, not pulled")

        // The tiles pulled only for the whole city are forgotten; those the player has been to stay.
        try await model.forgetUnfollowed(city)
        #expect(Set(try await model.store.sharedTiles().keys) == [a])
    }

    /// The tiles this phone recorded something in stay followed whoever recorded it: work done under the local id
    /// before a Game Center sign-in, or while it is still signing in at launch, is the same player's. And they count
    /// before the model has read the store's changesets.
    @MainActor
    @Test func aSyncFollowsTheTilesThisPhoneRecordedInWhoeverWasSignedIn() async throws {
        let model = AppModel(
            store: try LocalStore.inMemory(),
            player: Player(id: PlayerID(rawValue: "T:_test"), alias: "Test", source: .gameCenter))
        let theirs = TreeCandidate(id: UUID(), location: b.center, confidence: 1, isSynthetic: false).makeTree()
        var fields = try #require(try JSONValue(encoding: theirs).objectValue)
        fields["meta"] = nil
        fields["proposedStatus"] = nil
        fields["s2_l19_token"] = .string(theirs.position.chunk.token)
        let record = SharedRecord(
            kind: .tree, id: theirs.id, version: 1, tile: b, createdBy: .aerialSurvey,
            createdAt: Date(timeIntervalSince1970: 1_761_200_000), fields: fields)
        try await model.store.applyShared([
            .init(tile: b, sequence: 1, content: .snapshot([record])),
            .init(tile: c, sequence: 1, content: .snapshot([])),
        ])
        model.visitedTiles = []
        try await model.store.record(.treeConfirmed(treeID: theirs.id), by: .local(UUID()))

        let followed = try await model.followedTiles()
        #expect(followed == [b])
        try await model.forgetUnfollowed(followed)
        #expect(Set(try await model.store.sharedTiles().keys) == [b])
        await model.refresh()
        #expect(model.ownTrees == [theirs.id], "drawn at every zoom as the player's own")
        #expect(model.tree(theirs.id)?.displayStatus == .proposed)
    }

    /// Only the tiles drawn in full lately are kept as visited, so what a sync follows (each tile kept up to date and
    /// asked about for the review queue) does not grow with every place the map has been.
    @Test func visitedTilesAreTheMostRecentFew() throws {
        let many = Array(AppModel.wholeCity.prefix(AppModel.visitedTileLimit + 40))
        var visited: [S2CellID] = []
        for tile in many { visited = AppModel.visiting([tile], after: visited) }
        #expect(visited.count == AppModel.visitedTileLimit)
        #expect(visited.last == many.last)
        #expect(!visited.contains(many[0]))
        // A tile visited again is the most recent.
        let again = visited[0]
        visited = AppModel.visiting([again], after: visited)
        #expect(visited.last == again)
        #expect(visited.count == AppModel.visitedTileLimit)
        #expect(AppModel.visiting([], after: visited) == visited)
    }
}
