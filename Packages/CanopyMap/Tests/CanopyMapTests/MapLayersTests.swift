import CanopyDesign
import CanopyModel
import Foundation
import Testing

@testable import CanopyMap

@Suite struct MapLayersTests {
    func tree(_ status: CountStatus, proposed: CountStatus? = nil, at point: GeoPoint) -> Tree {
        var tree = TreeCandidate(id: UUID(), location: point, confidence: 0.9, isSynthetic: true).makeTree()
        tree.countStatus = status
        tree.proposedStatus = proposed
        return tree
    }

    let a = GeoPoint(latitude: 37.7699, longitude: -122.4757)
    let b = GeoPoint(latitude: 37.7704, longitude: -122.5090)

    @Test func treesUseTheirDisplayStatusAndRemovedOnesAreHidden() {
        let detected = tree(.detected, at: a)
        let pending = tree(.detected, proposed: .confirmed, at: a)
        let verified = tree(.verified, at: b)
        let removed = tree(.removed, at: b)
        let layers = MapLayers(state: CensusState(trees: [detected, pending, verified, removed]))
        let byID = Dictionary(uniqueKeysWithValues: layers.trees.map { ($0.id, $0) })
        #expect(byID.count == 3)
        #expect(byID[detected.id]?.symbol == .faintDot)
        #expect(byID[pending.id]?.status == .proposed)
        #expect(byID[pending.id]?.symbol == .dashedRing)
        #expect(byID[verified.id]?.symbol == .solid)
        #expect(byID[removed.id] == nil)
    }

    @Test func layersCanBeHidden() {
        let trees = [tree(.detected, at: a), tree(.confirmed, at: b)]
        let tag = Tag(
            meta: RecordMeta(playerID: .aerialSurvey, chunk: b.chunk), treeID: trees[1].id,
            point: Tag.Point(position: trees[1].position, heightAboveGround: Quantity(5, uncertainty: 0.5)),
            issue: .hanger, couldHit: .path, sizeClass: .large, urgency: .immediate)
        let state = CensusState(trees: trees, tags: [tag])

        let all = MapLayers(state: state, visibility: .init(tags: true, routes: true, tiles: true))
        #expect(all.trees.count == 2)
        #expect(all.tags.map(\.id) == [tag.id])
        #expect(all.trees.first { $0.id == trees[1].id }?.hazardCount == 1)
        #expect(all.tiles.filter { $0.level == 16 }.map(\.id) == [a.tile, b.tile].sorted())
        #expect(
            all.tiles.filter { $0.level == 13 }.map(\.id)
                == Set([a.tile, b.tile].map { $0.parent(level: 13) }).sorted())
        #expect(all.tiles.allSatisfy { $0.corners.count == 4 })
        #expect(all.tiles.allSatisfy { !$0.surveyed })
        let surveyed = MapLayers(
            state: state, visibility: .init(tags: true, routes: true, tiles: true), surveyed: [a.tile])
        #expect(surveyed.tiles.first { $0.id == a.tile }?.surveyed == true)
        #expect(surveyed.tiles.first { $0.id == b.tile }?.surveyed == false)
        #expect(surveyed.trees.first { $0.id == trees[0].id }?.inSurveyedCell == true)
        #expect(surveyed.trees.first { $0.id == trees[1].id }?.inSurveyedCell == false)

        let quiet = MapLayers(
            state: state, visibility: .init(statuses: [.confirmed], tags: false, routes: false, tiles: false))
        #expect(quiet.trees.map(\.id) == [trees[1].id])
        #expect(quiet.tags.isEmpty)
        #expect(quiet.tiles.isEmpty)
    }

    @Test func treesCanBeFilteredByStatus() {
        let trees = [
            tree(.detected, at: a), tree(.proposed, at: b), tree(.confirmed, at: a), tree(.verified, at: b),
            tree(.removed, at: a),
        ]
        let state = CensusState(trees: trees)
        let statuses = { (shown: Set<CountStatus>) in
            Set(MapLayers(state: state, visibility: .init(statuses: shown)).trees.map(\.status))
        }
        #expect(statuses(Set(MapLayers.Visibility.treeStatuses)) == [.detected, .proposed, .confirmed, .verified])
        #expect(statuses([.proposed, .verified]) == [.proposed, .verified])
        #expect(statuses([]).isEmpty)
        #expect(statuses([.removed]).isEmpty)  // removed trees are never drawn
    }

    @Test func detectedTreesAreLimitedNearestFirstAndFarTreesAreNotDrawn() throws {
        let centre = GeoPoint(latitude: 37.7699, longitude: -122.4757)
        // 50 detected trees in a line going north, 1e-4 degrees (11 m) apart, and one confirmed tree kilometres away.
        let detected = (0..<50).map { k in
            tree(
                .detected,
                at: GeoPoint(latitude: centre.latitude + (Double(k) + 0.5) * 1e-4, longitude: centre.longitude))
        }
        let confirmed = tree(.confirmed, at: GeoPoint(latitude: 37.80, longitude: -122.40))
        let region = MapViewport(center: centre, latitudeDelta: 0.002, longitudeDelta: 0.002)
        let state = CensusState(trees: detected + [confirmed])
        let layers = MapLayers(state: state, region: region, detectedLimit: 5)
        #expect(Set(layers.trees.map(\.id)) == Set(detected.prefix(5).map(\.id)), "the nearest five")

        let unlimited = MapLayers(state: state, region: region, detectedLimit: 100)
        let detailed = try #require(unlimited.detail.detailed)
        // Only trees in the tiles drawn in full, from the centre outward.
        #expect(unlimited.trees.allSatisfy { detailed.contains($0.location.tile) })
        #expect(Set(unlimited.trees.map(\.id)) == Set(detected.prefix(unlimited.trees.count).map(\.id)))
        #expect(!unlimited.trees.contains { $0.id == confirmed.id }, "far from the region, not drawn at all")
        #expect(!unlimited.summaries.contains { $0.id == confirmed.position.tile })
    }

    /// A square region `halfWidth` level-16 tile edges either side of the centre.
    func region(tiles halfWidth: Double, at centre: GeoPoint) -> MapViewport {
        MapViewport(center: centre, radius: halfWidth * MapDetail.tileEdge(at: centre))
    }

    let park = GeoPoint(latitude: 37.7694, longitude: -122.4770)

    /// The centre of a tile near a neighbourhood view of the park that is not drawn in full: in view, but not among the
    /// sixteen nearest the centre.
    func shadedTileCentre() throws -> GeoPoint {
        let view = region(tiles: 2, at: park)
        let detail = MapDetail(region: view)
        let padded = MapViewport(
            center: view.center, latitudeDelta: view.latitudeDelta * 1.3, longitudeDelta: view.longitudeDelta * 1.3)
        let tiles = MapDetail.tiles(in: view, step: MapDetail.tileEdge(at: park) / 3)
        let shaded = tiles.filter { !detail.isDetailed($0) && padded.contains($0.center) }.sorted()
        return try #require(shaded.first).center
    }

    @Test func aCloseViewDrawsEveryTileInViewInFull() throws {
        let detail = MapDetail(region: region(tiles: 0.8, at: park))
        let detailed = try #require(detail.detailed)
        #expect(detail.tilesInView <= MapDetail.detailedTileLimit)
        #expect(detailed.count == detail.tilesInView)
        #expect(detailed.contains(park.tile))
        #expect(detail.summaryLevel == 16)
    }

    @Test func aNeighbourhoodViewDrawsTheSixteenNearestTilesInFull() throws {
        let detail = MapDetail(region: region(tiles: 2, at: park))
        #expect(detail.tilesInView > MapDetail.detailedTileLimit)
        #expect(detail.tilesInView <= MapDetail.tilesInViewLimit)
        let detailed = try #require(detail.detailed)
        #expect(detailed.count == MapDetail.detailedTileLimit)
        #expect(detailed.contains(park.tile))
        // The nearest: no tile left out is nearer the centre than every tile drawn in full.
        let frame = LocalFrame(origin: park)
        let farthestDrawn = detailed.map { frame.enu(of: $0.center).horizontalDistance }.max() ?? 0
        let tiles = MapDetail.tiles(in: region(tiles: 2, at: park), step: MapDetail.tileEdge(at: park) / 3)
        for tile in tiles.subtracting(detailed) {
            #expect(frame.enu(of: tile.center).horizontalDistance >= farthestDrawn - 1)
        }
    }

    @Test func aWideViewShadesEveryTileAndACityViewShadesWholeCells() {
        let wide = MapDetail(region: region(tiles: 10, at: park))
        #expect(wide.detailed == [])
        #expect(!wide.drawsAnyDetail)
        #expect(wide.summaryLevel == 16)
        let city = MapDetail(region: region(tiles: 20, at: park))
        #expect(city.tilesInView > MapDetail.level16SummaryLimit)
        #expect(city.summaryLevel == 13)
        #expect(MapDetail.everything.isDetailed(park.tile))
    }

    @Test func tilesNotDrawnInFullBecomePatchesCountingTheirTreesAndTags() throws {
        let east = try shadedTileCentre()
        let far = [tree(.detected, at: east), tree(.detected, at: east), tree(.confirmed, at: east)]
        let near = tree(.detected, at: park)
        let tag = Tag(
            meta: RecordMeta(playerID: .aerialSurvey, chunk: east.chunk), treeID: far[2].id,
            point: Tag.Point(position: far[2].position, heightAboveGround: Quantity(5, uncertainty: 0.5)),
            issue: .hanger, couldHit: .path, sizeClass: .large, urgency: .immediate)
        let state = CensusState(trees: far + [near], tags: [tag])
        let layers = MapLayers(
            state: state, visibility: .init(tags: true), region: region(tiles: 2, at: park), surveyed: [east.tile],
            censusTiles: CensusTiles(state))
        #expect(layers.detail.drawsAnyDetail)
        #expect(!layers.detail.isDetailed(east.tile))
        #expect(layers.trees.map(\.id) == [near.id])
        #expect(layers.tags.isEmpty)
        let patch = try #require(layers.summaries.first { $0.id == east.tile })
        #expect(patch.detected == 2)
        #expect(patch.reviewed == 1)
        #expect(patch.tags == 1)
        #expect(patch.surveyed)
        #expect(patch.density > 0 && patch.density <= 1)
        #expect(layers.summary(at: east)?.id == east.tile)
        #expect(layers.summary(at: park) == nil, "the centre is drawn in full")

        // Zoomed far out the same trees count towards their level-13 cell.
        let city = MapLayers(state: state, region: region(tiles: 20, at: park))
        #expect(city.trees.isEmpty)
        let cell = try #require(city.summaries.first { $0.id == east.tile.parent(level: 13) })
        #expect(cell.trees >= 3)
    }

    @Test func theServersCountsShadeTilesThisPhoneHoldsNoTreesIn() throws {
        let shaded = try shadedTileCentre().tile
        let view = region(tiles: 2, at: park)
        let remote = [
            shaded: TileSummary(id: shaded, detected: 40, reviewed: 2, tags: 1),
            park.tile: TileSummary(id: park.tile, detected: 99),
        ]
        let layers = MapLayers(state: CensusState(), region: view, remoteTiles: remote)
        let patch = try #require(layers.summaries.first { $0.id == shaded })
        #expect((patch.detected, patch.reviewed, patch.tags) == (40, 2, 1))
        #expect(
            !layers.summaries.contains { $0.id == park.tile }, "the centre is drawn in full, from the phone's trees")
        // Where the phone holds trees, its own count wins.
        let local = tree(.confirmed, at: shaded.center)
        let mine = MapLayers(state: CensusState(trees: [local]), region: view, remoteTiles: remote)
        let own = try #require(mine.summaries.first { $0.id == shaded })
        #expect((own.detected, own.reviewed) == (0, 1))
        // Unless the phone has not pulled the tile: its trees there are only the base layer and its own, so the
        // server's count, which has everyone's, shades it.
        let sample = MapLayers(
            state: CensusState(trees: [local]), region: view, remoteTiles: remote, pulledTiles: [])
        let counted = try #require(sample.summaries.first { $0.id == shaded })
        #expect((counted.detected, counted.reviewed) == (40, 2))
        let pulled = MapLayers(
            state: CensusState(trees: [local]), region: view, remoteTiles: remote, pulledTiles: [shaded])
        let held = try #require(pulled.summaries.first { $0.id == shaded })
        #expect((held.detected, held.reviewed) == (0, 1))
        // Hiding detected trees hides them in the server's counts too.
        let reviewedOnly = MapLayers(
            state: CensusState(), visibility: .init(statuses: [.confirmed]), region: view, remoteTiles: remote)
        #expect(reviewedOnly.summaries.first { $0.id == shaded }?.detected == 0)
    }

    @Test func densityIsTheSameScaleForTilesAndCells() {
        let tile = park.tile
        let empty = TileSummary(id: tile)
        #expect(empty.density == 0)
        let area = empty.areaHectares
        #expect(area > 1 && area < 4, "a level-16 tile is about two hectares")
        let dense = TileSummary(id: tile, detected: Int(area * TileSummary.fullDensity) + 1)
        #expect(dense.density == 1)
        let quarter = TileSummary(id: tile, detected: Int((area * TileSummary.fullDensity / 4).rounded()))
        #expect(abs(quarter.density - 0.5) < 0.05, "square-root scale")
        let cell = TileSummary(id: tile.parent(level: 13), detected: Int((area * 64 * TileSummary.fullDensity / 4)))
        #expect(abs(cell.density - 0.5) < 0.1)
    }

    @Test func onlyTheVectorsInTilesDrawnInFullAreDrawn() throws {
        let east = try shadedTileCentre()
        let near = MapLayers.Reference.Line(kind: .road, points: [park, east], closed: false)
        let far = MapLayers.Reference.Line(kind: .road, points: [east, park], closed: false)
        let reference = MapLayers.Reference(canopies: [], lines: [near, far])
        let shown = MapLayers.Visibility(vectors: true)
        let layers = MapLayers(
            state: CensusState(), visibility: shown, region: region(tiles: 2, at: park), reference: reference)
        #expect(layers.detailedLines.map(\.tile) == [park.tile])
        let everything = MapLayers(state: CensusState(), visibility: shown, reference: reference)
        #expect(everything.detailedLines.count == 2)
    }

    @Test func gerardusVectorsAreOffUnlessThePlayerShowsThem() {
        #expect(!MapLayers.Visibility().vectors)
        let line = MapLayers.Reference.Line(kind: .road, points: [park, a], closed: false)
        let reference = MapLayers.Reference(canopies: [], lines: [line])
        let hidden = MapLayers(state: CensusState(), reference: reference)
        #expect(hidden.reference == nil, "neither the lines nor the sites reach a renderer")
        #expect(hidden.detailedLines.isEmpty && hidden.detailedSites.isEmpty)
        let shown = MapLayers(state: CensusState(), visibility: .init(vectors: true), reference: reference)
        #expect(shown.reference === reference)
        #expect(shown.detailedLines.count == 1)
    }

    @Test func zoomedOutTheMapIsOnlyPatchesShadedFromEachTilesCounts() throws {
        let east = try shadedTileCentre()
        let trees =
            (0..<30).map { _ in tree(.detected, at: east) } + [tree(.proposed, at: east), tree(.removed, at: east)]
        let state = CensusState(trees: trees)
        let tiles = CensusTiles(state)
        #expect(tiles.counts[east.tile]?.detected == 30)
        #expect(tiles.counts[east.tile]?.proposed == 1)
        #expect(tiles.total.removed == 1)
        let wide = MapLayers(state: state, region: region(tiles: 10, at: park), censusTiles: tiles)
        #expect(!wide.detail.drawsAnyDetail)
        #expect(wide.trees.isEmpty && wide.tags.isEmpty && wide.reference == nil)
        let patch = try #require(wide.summaries.first { $0.id == east.tile })
        #expect((patch.detected, patch.reviewed) == (30, 1), "removed trees are not counted")
        // The counts are what shades a patch: the trees themselves are not looked at.
        let countsOnly = MapLayers(state: CensusState(), region: region(tiles: 10, at: park), censusTiles: tiles)
        #expect(countsOnly.summaries == wide.summaries)
    }

    @Test func tilesDetectedInFullAreMarkedApart() throws {
        let east = try shadedTileCentre()
        let view = region(tiles: 10, at: park)
        let state = CensusState(trees: [tree(.detected, at: east), tree(.detected, at: park)])
        let layers = MapLayers(state: state, region: view, detectedTiles: [east.tile])
        #expect(layers.summaries.first { $0.id == east.tile }?.detectedInFull == true)
        #expect(layers.summaries.first { $0.id == park.tile }?.detectedInFull == false)
        // A tile detected in full that holds no trees still shows its outline.
        let empty = MapLayers(state: CensusState(), region: view, detectedTiles: [east.tile])
        let outline = try #require(empty.summaries.first { $0.id == east.tile })
        #expect(outline.detectedInFull && outline.trees == 0 && outline.density == 0)
        // A level-13 cell is marked only when every tile in it with trees was detected in full.
        let city = region(tiles: 20, at: park)
        let cell = east.tile.parent(level: 13)
        let partly = MapLayers(state: state, region: city, detectedTiles: [east.tile])
        let whole = MapLayers(state: state, region: city, detectedTiles: [east.tile, park.tile])
        if park.tile.parent(level: 13) == cell {
            #expect(partly.summaries.first { $0.id == cell }?.detectedInFull == false)
        }
        #expect(whole.summaries.first { $0.id == cell }?.detectedInFull == true)
    }

    @Test func thePlayersOwnTreesAreDrawnAtEveryZoomAndOtherTreesOnlyInFull() throws {
        let east = try shadedTileCentre()
        let mine = tree(.proposed, at: east)
        let theirs = tree(.confirmed, at: east)
        let far = tree(.confirmed, at: GeoPoint(latitude: 37.80, longitude: -122.40))
        let state = CensusState(trees: [mine, theirs, far])
        let own: Set<UUID> = [mine.id, far.id]
        let neighbourhood = MapLayers(state: state, region: region(tiles: 2, at: park), own: own)
        #expect(neighbourhood.trees.map(\.id) == [mine.id], "in a tile not drawn in full, only the player's own")
        let wide = MapLayers(state: state, region: region(tiles: 10, at: park), own: own)
        #expect(wide.trees.map(\.id) == [mine.id], "zoomed out too, and not when far from the view")
        let none = MapLayers(state: state, region: region(tiles: 10, at: park), own: own, ownLimit: 0)
        #expect(none.trees.isEmpty)
        // Hiding a status hides the player's trees of that status too.
        let hidden = MapLayers(
            state: state, visibility: .init(statuses: [.confirmed]), region: region(tiles: 2, at: park), own: own)
        #expect(hidden.trees.isEmpty)
    }

    @Test func everyStatusHasAWordAnIconAndATone() {
        let presentations =
            CountStatus.allCases.map(\.presentation) + Tag.Urgency.allCases.map(\.presentation)
            + Tag.Status.allCases.map(\.presentation) + Changeset.State.allCases.map(\.presentation)
        for presentation in presentations {
            #expect(!presentation.label.isEmpty)
            #expect(!presentation.systemImage.isEmpty)
        }
        #expect(Set(CountStatus.allCases.map(\.presentation.label)).count == CountStatus.allCases.count)
        #expect(Set(CountStatus.allCases.map { TreeSymbol($0) }.map { "\($0)" }).count == CountStatus.allCases.count)
    }

    @Test func parkViewportCoversTheFixtureArea() {
        let viewport = MapViewport.goldenGatePark
        #expect(viewport.contains(GeoPoint(latitude: 37.7722, longitude: -122.5112)))  // Fulton & Great Hwy
        #expect(viewport.contains(GeoPoint(latitude: 37.7735, longitude: -122.4429)))  // Fell & Baker
        #expect(viewport.contains(GeoPoint(latitude: 37.7638, longitude: -122.5098)))  // Lincoln & Great Hwy
        #expect(!viewport.contains(GeoPoint(latitude: 37.7793, longitude: -122.4193)))  // City Hall
    }

    @Test func cornerDistanceIsTheRadiusRoundTheRegion() {
        // 0.002° of latitude is 222 m; 0.002° of longitude at 37.77° N is 176 m.
        let viewport = MapViewport(
            center: GeoPoint(latitude: 37.77, longitude: -122.47), latitudeDelta: 0.002, longitudeDelta: 0.002)
        #expect(abs(viewport.cornerDistance - 141.7) < 1)
    }
}
