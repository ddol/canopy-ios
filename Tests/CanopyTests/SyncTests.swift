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
}
