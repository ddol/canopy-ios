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

        let all = MapLayers(state: state, visibility: .init(detected: true, tags: true, routes: true, tiles: true))
        #expect(all.trees.count == 2)
        #expect(all.tags.map(\.id) == [tag.id])
        #expect(all.trees.first { $0.id == trees[1].id }?.hazardCount == 1)
        #expect(all.tiles.map(\.id) == [a.tile, b.tile].sorted())
        #expect(all.tiles.allSatisfy { $0.corners.count == 4 })

        let quiet = MapLayers(
            state: state, visibility: .init(detected: false, tags: false, routes: false, tiles: false))
        #expect(quiet.trees.map(\.id) == [trees[1].id])
        #expect(quiet.tags.isEmpty)
        #expect(quiet.tiles.isEmpty)
    }

    @Test func detectedTreesAreLimitedToTheRegionNearestFirst() {
        let centre = GeoPoint(latitude: 37.7699, longitude: -122.4757)
        // 50 detected trees in a line going north, 1e-4 degrees (11 m) apart (offset half a step, so none sits on the
        // region's edge), and one far-away confirmed tree.
        let detected = (0..<50).map { k in
            tree(
                .detected,
                at: GeoPoint(latitude: centre.latitude + (Double(k) + 0.5) * 1e-4, longitude: centre.longitude))
        }
        let confirmed = tree(.confirmed, at: GeoPoint(latitude: 37.80, longitude: -122.40))
        let region = MapViewport(center: centre, latitudeDelta: 0.002, longitudeDelta: 0.002)
        let layers = MapLayers(
            state: CensusState(trees: detected + [confirmed]), region: region, detectedLimit: 5)
        let ids = Set(layers.trees.map(\.id))
        #expect(ids.count == 6)
        #expect(ids.contains(confirmed.id), "trees people acted on are always drawn")
        #expect(ids.isSuperset(of: detected.prefix(5).map(\.id)), "the nearest five")
        let unlimited = MapLayers(state: CensusState(trees: detected + [confirmed]), region: region, detectedLimit: 100)
        // Inside the region plus a 30 % margin: up to 0.0013 degrees north of the centre, so the first 13.
        #expect(unlimited.trees.count == 13 + 1)
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
}
