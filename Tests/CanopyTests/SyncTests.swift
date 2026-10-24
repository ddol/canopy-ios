import CanopyMap
import CanopyModel
import CanopyPlayers
import CanopyReference
import CanopyStore
import CanopySync
import Foundation
import Testing

@testable import Canopy

/// Sync against a real Gerardus map service. Opt in by passing one to the test runner, with an admin's id (the
/// server's `serve --admin`): `TEST_RUNNER_CANOPY_GERARDUS_MAP_URL=http://127.0.0.1:50071
/// TEST_RUNNER_CANOPY_GERARDUS_ADMIN=T:_canopy-admin scripts/test.sh -only-testing:CanopyTests/SyncTests`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CANOPY_GERARDUS_MAP_URL"] != nil))
struct SyncTests {
    @Test func syncSendsChangesToTheServerAndBringsBackItsVerdict() async throws {
        let environment = ProcessInfo.processInfo.environment
        let address = try #require(environment["CANOPY_GERARDUS_MAP_URL"])
        let endpoint = try #require(GerardusEndpoint(address))
        let admin = Player(
            id: PlayerID(rawValue: environment["CANOPY_GERARDUS_ADMIN"] ?? "T:_canopy-admin"), alias: "Admin",
            source: .gameCenter)
        let settings = ServerSettings.volatile()
        settings.save(endpoint)
        let player = Player(
            id: PlayerID(rawValue: "T:_canopy-app-\(UUID().uuidString.prefix(8))"), alias: "App test",
            source: .gameCenter)
        let model = AppModel(
            store: try LocalStore.inMemory(), players: PlayerService(local: player), serverSettings: settings)
        await model.load()

        // A real candidate (its id comes from its position), at a fresh spot each run, saved as a load would.
        let location = GeoPoint(
            latitude: 37.7690 + Double.random(in: 0...0.002), longitude: -122.4850 + Double.random(in: 0...0.01))
        let candidate = TreeCandidate(
            id: AerialTrees.stableID(location), location: location, height: 20, crownRadius: 4, confidence: 0.8,
            isSynthetic: false, source: "USGS 3DEP lidar point cloud (public-domain)")
        try await model.store.replaceCandidates(where: { _ in false }, with: [candidate])
        await model.refresh()
        let result = AerialTrees.SiteResult(
            site: try Site(fields: []), candidates: [candidate], tiles: [location.tile], attribution: [], pointCount: 0)
        #expect(await model.saveDetectedTrees(result) == "Saved 1 new tree to the server.")
        #expect(await model.saveDetectedTrees(result) == "The server already has them.")

        await model.confirm(try #require(model.tree(candidate.id)))
        await model.sync()
        #expect(model.error == nil)
        let changeset = try #require(model.changesets.first { $0.ops.contains { $0.id == candidate.id } })
        #expect(model.lastSync?.submitted == 1)
        #expect(changeset.state == .pending)

        // A trusted player agrees on the server; the next sync brings that back.
        let approved = try await GerardusMapClient(baseURL: endpoint.url, player: admin).review(
            changeset.id, approve: true)
        #expect(approved.state == .applied)
        await model.sync()
        #expect(model.error == nil)
        #expect(model.changesets.first { $0.id == changeset.id }?.state == .applied)
        #expect(model.tree(candidate.id)?.countStatus == .confirmed)
    }

    @Test func otherPlayersChangesShowUpAndCanBeReviewed() async throws {
        let environment = ProcessInfo.processInfo.environment
        let address = try #require(environment["CANOPY_GERARDUS_MAP_URL"])
        let endpoint = try #require(GerardusEndpoint(address))
        func phone(_ player: Player) throws -> AppModel {
            let settings = ServerSettings.volatile()
            settings.save(endpoint)
            return AppModel(
                store: try LocalStore.inMemory(), players: PlayerService(local: player), serverSettings: settings)
        }
        let walker = Player(
            id: PlayerID(rawValue: "T:_canopy-walker-\(UUID().uuidString.prefix(8))"), alias: "Walker",
            source: .gameCenter)
        let admin = Player(
            id: PlayerID(rawValue: environment["CANOPY_GERARDUS_ADMIN"] ?? "T:_canopy-admin"), alias: "Ranger",
            source: .gameCenter)
        let a = try phone(walker)
        let b = try phone(admin)
        await a.load()
        await b.load()

        // The walker loads a tree and confirms it.
        let location = GeoPoint(
            latitude: 37.7690 + Double.random(in: 0...0.002), longitude: -122.4850 + Double.random(in: 0...0.01))
        let candidate = TreeCandidate(
            id: AerialTrees.stableID(location), location: location, height: 20, crownRadius: 4, confidence: 0.8,
            isSynthetic: false, source: "USGS 3DEP lidar point cloud (public-domain)")
        try await a.store.replaceCandidates(where: { _ in false }, with: [candidate])
        await a.refresh()
        _ = await a.saveDetectedTrees(
            AerialTrees.SiteResult(
                site: try Site(fields: []), candidates: [candidate], tiles: [location.tile], attribution: [],
                pointCount: 0))
        await a.confirm(try #require(a.tree(candidate.id)))
        await a.sync()
        let proposal = try #require(a.changesets.first { $0.ops.contains { $0.id == candidate.id } })
        #expect(proposal.state == .pending)

        // The ranger looks at that spot and syncs: the tree arrives from the shared map, and the walker's change waits
        // for review.
        let view = MapViewport(center: location, latitudeDelta: 0.002, longitudeDelta: 0.002)
        b.mapViewport = view
        #expect(b.tree(candidate.id) == nil)
        await b.sync()
        #expect(b.error == nil)
        #expect(b.tree(candidate.id)?.countStatus == .detected)
        #expect(b.serverPlayer?.isTrusted == true)
        let item = try #require(b.reviewQueue.first { $0.changeset.id == proposal.id })
        #expect(item.authorAlias == "Walker")

        await b.review(item, approve: true)
        #expect(b.error == nil)
        #expect(!b.reviewQueue.contains { $0.changeset.id == proposal.id })
        #expect(b.tree(candidate.id)?.countStatus == .confirmed)

        // The walker syncs: applied, and the shared map agrees.
        a.mapViewport = view
        await a.sync()
        #expect(a.changesets.first { $0.id == proposal.id }?.state == .applied)
        let confirmed = try #require(a.tree(candidate.id))
        #expect(confirmed.countStatus == .confirmed && confirmed.proposedStatus == nil)
        #expect(confirmed.meta.version == 2)
    }
}
