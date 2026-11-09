import CanopyCapture
import CanopyMap
import CanopyModel
import CanopyStore
import Foundation
import Testing

@testable import Canopy

/// A tree's rings saved with a scan outlive the session: a new model over the same store draws the tree in them.
@MainActor
@Suite struct ScanAlignmentModelTests {
    let player = Player(id: PlayerID(rawValue: "T:_test"), alias: "Test", source: .gameCenter)

    @Test func savedRingsAreDrawnAgainAfterARelaunch() async throws {
        let store = try LocalStore.inMemory()
        let model = AppModel(store: store, player: player)
        await model.load()
        let tree = try #require(model.census.trees.values.first)
        let mesh = AppModel.syntheticTrunkScan()
        let glb = try GLB.data(for: mesh)
        let scan = BlobStore.reference(for: glb)
        let ground = try #require(SavedScan(mesh: mesh).estimatedGroundHeight)
        #expect(abs(ground + 1.3) < 1e-6)

        let fresh = TreeProfile(form: AppModel.knownForm(tree))
        let (profile, snapped) = SavedScan(mesh: mesh).snappingTrunk(fresh, groundHeight: ground)
        // The ground and breast height at least; the crown's base too when it is low enough for the scan to reach.
        #expect(snapped >= 2)
        let older = ScanAlignment(
            scan: scan, treeID: tree.id, profile: fresh, groundHeight: ground,
            savedAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(await model.saveAlignment(older))
        let newer = ScanAlignment(scan: scan, treeID: tree.id, profile: profile, groundHeight: ground)
        #expect(await model.saveAlignment(newer))
        let key = MapLayers.censusWireframeID(tree.id)
        #expect(model.treeProfiles[key] == profile)

        let relaunched = AppModel(store: store, player: player)
        await relaunched.load()
        #expect(relaunched.treeProfiles[key] == profile)
        #expect(await relaunched.alignment(for: scan) == newer)
    }
}
