import CanopyCapture
import CanopyMap
import CanopyModel
import CanopyStore
import Foundation
import SceneKit
import Testing
import simd

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
        let (profile, snapped, _) = SavedScan(mesh: mesh).snappingTrunk(fresh, groundHeight: ground)
        // The rings at the ground and a metre up at least, and those above that the scan reaches.
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
        #expect(await relaunched.alignment(for: scan, tree: tree.id) == newer)
    }

    /// A scan saved twice as a new tree is listed by both trees; each tree's rings against it are its own.
    @Test func twoTreesListingOneScanKeepTheirOwnRings() async throws {
        let model = AppModel(store: try LocalStore.inMemory(), player: player)
        await model.load()
        let trees = Array(model.census.trees.values.prefix(2))
        try #require(trees.count == 2)
        let scan = BlobStore.reference(for: try GLB.data(for: AppModel.syntheticTrunkScan()))
        let thin = TreeProfile(form: TreeForm(trunkDiameter: 0.3, height: 8, crownHeight: 5, crownWidth: 5))
        let thick = TreeProfile(form: TreeForm(trunkDiameter: 0.9, height: 20, crownHeight: 12, crownWidth: 14))
        #expect(
            await model.saveAlignment(
                ScanAlignment(scan: scan, treeID: trees[0].id, profile: thin, groundHeight: -1.3)))
        #expect(
            await model.saveAlignment(
                ScanAlignment(scan: scan, treeID: trees[1].id, profile: thick, groundHeight: -1.3)))
        #expect(await model.alignment(for: scan, tree: trees[0].id)?.profile == thin)
        #expect(await model.alignment(for: scan, tree: trees[1].id)?.profile == thick)

        let relaunched = AppModel(store: model.store, player: player)
        await relaunched.load()
        #expect(relaunched.treeProfiles[MapLayers.censusWireframeID(trees[0].id)] == thin)
        #expect(relaunched.treeProfiles[MapLayers.censusWireframeID(trees[1].id)] == thick)
    }

    /// Restoring the rings never puts back older ones over what is drawn (a second window's `load`, say), and
    /// resetting the local data takes the restored rings down with the table they came from.
    @Test func restoredRingsLeaveNewerOnesAndGoOnReset() async throws {
        let store = try LocalStore.inMemory()
        let model = AppModel(store: store, player: player)
        await model.load()
        let tree = try #require(model.census.trees.values.first)
        let key = MapLayers.censusWireframeID(tree.id)
        let scan = BlobStore.reference(for: try GLB.data(for: AppModel.syntheticTrunkScan()))
        let older = TreeProfile(form: TreeForm(trunkDiameter: 0.3, height: 8, crownHeight: 5, crownWidth: 5))
        let newer = TreeProfile(form: TreeForm(trunkDiameter: 0.4, height: 9, crownHeight: 6, crownWidth: 6))
        try await store.saveScanAlignment(
            ScanAlignment(scan: scan, treeID: tree.id, profile: older, groundHeight: -1.3), scan: scan,
            subject: tree.id)
        model.treeProfiles[key] = newer
        await model.loadAlignments()
        #expect(model.treeProfiles[key] == newer)

        await model.reset()
        #expect(model.treeProfiles.isEmpty)
    }

    /// The nudge arrows move things the way they point on screen, the view looking straight down too.
    @Test func theArrowsFollowTheView() {
        // From the south, looking north across the ground: right is east, away is north (scene −z).
        let level = ScanAlignmentCamera.groundAxes(right: SIMD3(1, 0, 0), front: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
        #expect(simd_distance(level.right, SIMD2(1, 0)) < 1e-5 && simd_distance(level.away, SIMD2(0, -1)) < 1e-5)
        // From the west, looking east and a little down.
        let west = ScanAlignmentCamera.groundAxes(
            right: SIMD3(0, 0, 1), front: simd_normalize(SIMD3(1, -0.3, 0)), up: simd_normalize(SIMD3(0.3, 1, 0)))
        #expect(simd_distance(west.right, SIMD2(0, 1)) < 1e-5 && simd_distance(west.away, SIMD2(1, 0)) < 1e-5)
        // Straight down with east to the right: the top of the screen, and so away, is north.
        let down = ScanAlignmentCamera.groundAxes(right: SIMD3(1, 0, 0), front: SIMD3(0, -1, 0), up: SIMD3(0, 0, -1))
        #expect(simd_distance(down.right, SIMD2(1, 0)) < 1e-5 && simd_distance(down.away, SIMD2(0, -1)) < 1e-5)
    }

    /// The view opens 3.2 m south of the trunk and 0.8 m above the point it turns about, looking at it.
    @Test func theViewOpensSouthOfTheTrunk() {
        let pole = SIMD3<Float>(0, 1.37, 0)
        let node = SCNNode()
        node.simdTransform = ScanOrbit.home(pole).transform
        #expect(simd_distance(node.simdPosition, pole + SIMD3(0, 0.8, 3.2)) < 1e-4)
        #expect(simd_distance(node.simdWorldFront, simd_normalize(pole - node.simdPosition)) < 1e-4)
        #expect(abs(node.simdWorldRight.y) < 1e-6 && node.simdWorldUp.y > 0)
    }

    /// However the fingers drag, twist, pinch and slide, the camera never rolls: its right stays level and its up
    /// toward the sky, so the ground stays down. A clockwise twist turns the scene clockwise seen from above.
    @Test func noGestureTurnsTheGroundOver() {
        let pole = SIMD3<Float>(0, 1.37, 0)
        var orbit = ScanOrbit.home(pole)
        let node = SCNNode()
        // A quarter turn clockwise: from the south, looking north, to the east, looking west.
        node.simdTransform = orbit.twisting(by: .pi / 2).transform
        #expect(simd_distance(node.simdPosition, pole + SIMD3(3.2, 0.8, 0)) < 1e-4)
        #expect(simd_distance(simd_normalize(SIMD2(node.simdWorldFront.x, node.simdWorldFront.z)), SIMD2(-1, 0)) < 1e-3)
        for step in 0..<40 {
            let k = CGFloat(step)
            orbit = orbit.orbiting(by: CGPoint(x: 37 * sin(k), y: 90 * cos(k * 1.3)))
                .twisting(by: Float(sin(k * 0.7)) * 2)
                .pinching(by: 1 + 0.3 * sin(k))
                .sliding(by: CGPoint(x: 20 * cos(k), y: 15 * sin(k)), height: 800, fieldOfView: 50)
            node.simdTransform = orbit.transform
            #expect(abs(node.simdWorldRight.y) < 1e-5)
            #expect(node.simdWorldUp.y > 0)
            #expect(ScanOrbit.elevations.contains(orbit.elevation))
            #expect(abs(simd_distance(node.simdPosition, orbit.target) - orbit.distance) < 1e-3 * orbit.distance)
            #expect(simd_distance(node.simdWorldFront, simd_normalize(orbit.target - node.simdPosition)) < 1e-3)
        }
    }

    /// Dragging one finger down looks down on the trunk; two fingers dragged down slide the scan down the screen, so
    /// the view rises up the trunk.
    @Test func dragsMoveTheViewAsTheyLook() {
        let pole = SIMD3<Float>(0, 1.37, 0)
        let home = ScanOrbit.home(pole)
        #expect(home.orbiting(by: CGPoint(x: 0, y: 50)).elevation > home.elevation)
        #expect(home.orbiting(by: CGPoint(x: 0, y: 5000)).elevation == ScanOrbit.elevations.upperBound)
        #expect(home.sliding(by: CGPoint(x: 0, y: 100), height: 800, fieldOfView: 50).target.y > pole.y)
        // Sliding right moves the scan right, so the view moves left: west, seen from the south.
        #expect(home.sliding(by: CGPoint(x: 100, y: 0), height: 800, fieldOfView: 50).target.x < 0)
        #expect(home.pinching(by: 2).distance < home.distance)
    }

    /// The scan is readied to draw off the main thread: a unit normal at every vertex and each edge once.
    @Test func aScanIsReadiedToDrawWithEachEdgeOnce() {
        let square = Mesh(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 1), SIMD3(0, 0, 1), SIMD3(5, 5, 5)],
            indices: [0, 2, 1, 0, 3, 2])
        let surface = ScanSurface(square)
        #expect(surface.triangles == square.indices)
        // Four sides and the diagonal they share.
        #expect(surface.edges.count == 2 * 5)
        let pairs = Set(
            stride(from: 0, to: surface.edges.count, by: 2).map {
                [min(surface.edges[$0], surface.edges[$0 + 1]), max(surface.edges[$0], surface.edges[$0 + 1])]
            })
        #expect(pairs == [[0, 2], [1, 2], [0, 1], [0, 3], [2, 3]])
        #expect(surface.normals[0..<4].allSatisfy { simd_distance($0, SIMD3(0, 1, 0)) < 1e-6 })
        // A vertex no triangle uses still has a normal.
        #expect(surface.normals[4] == SIMD3(0, 1, 0))
        #expect(ScanSurface(AppModel.syntheticTrunkScan()).normals.allSatisfy { abs(simd_length($0) - 1) < 1e-4 })
    }
}
