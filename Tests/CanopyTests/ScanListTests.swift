import CanopyCapture
import CanopyMap
import CanopyModel
import CanopyPlayers
import CanopyStore
import Foundation
import Testing

@testable import Canopy

/// Your scans: a picture of each scan, drawn once from its mesh, and Show on map.
@MainActor
@Suite struct ScanListTests {
    /// Small pictures: the tests draw in the simulator, on the Mac's small shared GPU.
    func makeModel() throws -> AppModel {
        AppModel(
            store: try LocalStore.inMemory(),
            players: PlayerService(
                local: Player(id: PlayerID(rawValue: "T:_test"), alias: "Test", source: .gameCenter)),
            scanPreviews: .temporary(pixels: 48))
    }

    @Test func aScanIsDrawnOnceItsMeshIsOnThisDeviceAndKeptByItsHash() async throws {
        let model = try makeModel()
        await model.load()
        let glb = try GLB.data(for: AppModel.sampleTrunk())
        let ref = BlobStore.reference(for: glb)

        // Recorded on another device: nothing to draw until the mesh is downloaded.
        #expect(try await model.scanPreview(ref) == nil)
        #expect(model.scanPreviews.cached(ref) == nil)

        try model.store.blobs.put(glb, expecting: ref)
        let url = try #require(try await model.scanPreview(ref))
        #expect(url == model.scanPreviews.url(for: ref))
        #expect(url.lastPathComponent == ref.rawValue + ".png")
        #expect(try Data(contentsOf: url).starts(with: [0x89, 0x50, 0x4E, 0x47]))

        // Kept: asked again, it comes from the cache, even without the mesh to draw it from.
        try FileManager.default.removeItem(at: model.store.blobs.url(for: ref))
        #expect(try await model.scanPreview(ref) == url)

        // Resetting the app's data deletes the pictures too.
        await model.reset()
        #expect(model.scanPreviews.cached(ref) == nil)
    }

    @Test func aRecordedScanHasAPicture() async throws {
        let model = try makeModel()
        await model.load()
        await model.addSampleScan()
        let scan = try #require(try await model.store.allEvidence().first)
        #expect(model.scanCount == 1)
        #expect(model.tree(scan.subjectID)?.evidenceRefs == [scan.blob])
        #expect(try await model.scanPreview(scan.blob) != nil)
    }

    @Test func showOnMapGoesToTheMapTabWithTheTree() async throws {
        let model = try makeModel()
        await model.load()
        model.section = .me
        let tree = try #require(model.census.trees.values.first)
        model.showOnMap(tree)
        #expect(model.section == .map)
        #expect(model.mapTarget == tree.id)
    }

    @Test func theMapComesCloseEnoughToDrawTheTreeInFullAboveTheSheet() {
        let tree = GeoPoint(latitude: 37.77075, longitude: -122.48306)
        let region = MapViewport.showing(tree)
        #expect(region.contains(tree))
        // Above the middle, so the tree sheet opening at half height leaves it in view.
        #expect(region.center.latitude < tree.latitude)
        #expect(abs(region.center.longitude - tree.longitude) < 1e-9)
        #expect(abs(LocalFrame(origin: region.center).enu(of: tree).north - MapViewport.treeOffset) < 0.01)
        #expect(MapViewport.treeOffset < MapViewport.treeRadius)
        #expect(MapDetail(region: region).isDetailed(tree.tile))
    }
}
