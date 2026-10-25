import CanopyModel
import CanopySync
import Foundation
import Testing

@testable import CanopyReference

/// The map service on a real server. Opt in with `CANOPY_GERARDUS_MAP_URL` and an admin's id in
/// `CANOPY_GERARDUS_ADMIN` (the server's `serve --admin`), for example against a local server:
/// `gerardus --data-dir /tmp/g serve --listen 127.0.0.1:50071 --admin T:_canopy-admin`.
enum LiveMap {
    static let url = ProcessInfo.processInfo.environment["CANOPY_GERARDUS_MAP_URL"].flatMap(URL.init(string:))
    static var enabled: Bool { url != nil }
    static let adminID = ProcessInfo.processInfo.environment["CANOPY_GERARDUS_ADMIN"] ?? "T:_canopy-admin"

    static func client(_ player: Player) -> GerardusMapClient { GerardusMapClient(baseURL: url!, player: player) }
}

@Suite(.enabled(if: LiveMap.enabled), .serialized) struct LiveMapTests {
    let admin = Player(id: PlayerID(rawValue: LiveMap.adminID), alias: "Admin", source: .gameCenter)
    let walker = Player(
        id: PlayerID(rawValue: "T:_canopy-walker-\(UUID().uuidString.prefix(8))"), alias: "Walker",
        source: .gameCenter)

    @Test func theServerKnowsWhoIsCalling() async throws {
        let info = try await LiveMap.client(admin).player()
        #expect(info.id == admin.id.rawValue)
        #expect(info.isAdmin && info.isTrusted && info.isOSMAllowed)
        let regular = try await LiveMap.client(walker).player()
        #expect(!regular.isAdmin && !regular.isTrusted && !regular.isOSMAllowed)
        #expect(regular.alias == "Walker")
    }

    @Test func detectedTreesAreSavedOnceThenConfirmedByTwoPlayers() async throws {
        // A fresh spot each run, so earlier runs' trees do not occupy its L22 cells.
        let origin = GeoPoint(
            latitude: 37.7690 + Double.random(in: 0...0.002), longitude: -122.4850 + Double.random(in: 0...0.01))
        let frame = LocalFrame(origin: origin)
        let candidates = [(0.0, 0.0), (8, 0), (0, 8)].map { e, n in
            let location = frame.geoPoint(of: ENU(east: e, north: n, up: 0)).point
            return TreeCandidate(
                id: AerialTrees.stableID(location), location: location, height: 18, crownRadius: 3, confidence: 0.7,
                isSynthetic: false, source: "USGS 3DEP lidar point cloud (public-domain)")
        }
        let tiles = Set(candidates.map(\.location.tile))
        let walkerClient = LiveMap.client(walker)
        let first = try await walkerClient.importDetectedTrees(
            candidates, source: "USGS 3DEP lidar point cloud (public-domain)", tiles: tiles, detector: "Canopy tests")
        #expect(first.created == 3)
        let again = try await walkerClient.importDetectedTrees(
            candidates, source: "USGS 3DEP lidar point cloud (public-domain)", tiles: tiles, detector: "Canopy tests")
        #expect(again.created == 0 && again.alreadyPresent == 3)
        // Nothing found with OpenStreetMap enters the shared layer.
        await #expect(throws: GRPCStatusError.self) {
            _ = try await walkerClient.importDetectedTrees(
                candidates, source: "3DEP; buildings masked with OpenStreetMap, for checking only", tiles: tiles,
                detector: "Canopy tests")
        }

        // The walker confirms the first tree: an update the server holds until a trusted player agrees.
        let tile = candidates[0].location.tile
        let before = try await walkerClient.tile(tile)
        let tree = try #require(before.entities.first { $0.id == candidates[0].id })
        #expect(tree.version == 1)
        #expect(tree.fields["countStatus"] == "detected")
        #expect(tree.occupancy == S2CellID(candidates[0].location, level: TreeName.level))
        let changeset = Changeset(
            meta: RecordMeta(playerID: walker.id, chunk: candidates[0].location.chunk),
            ops: [
                ChangeOp(
                    op: .update, entity: .tree, id: candidates[0].id, baseVersion: 1,
                    fields: ["countStatus": "confirmed"])
            ],
            tiles: [tile])
        let submitted = try await walkerClient.submit(changeset, author: walker)
        #expect(submitted.state == .pending)
        let resubmitted = try await walkerClient.submit(changeset, author: walker)
        #expect(resubmitted.id == changeset.id && resubmitted.state == .pending)

        let approved = try await LiveMap.client(admin).review(changeset.id, approve: true)
        #expect(approved.state == .applied)
        #expect(approved.approvals.map(\.playerID) == [admin.id])
        #expect(try await walkerClient.changesets([changeset.id]).map(\.state) == [.applied])

        let pulled = try await walkerClient.pullChanges(in: tile, since: before.latestSequence)
        #expect(pulled.changes.map(\.changesetID) == [changeset.id])
        #expect(pulled.changes.first?.op.fields["countStatus"] == "confirmed")
        let after = try await walkerClient.tile(tile)
        let confirmed = try #require(after.entities.first { $0.id == candidates[0].id })
        #expect(confirmed.version == 2)
        #expect(confirmed.fields["countStatus"] == "confirmed")
    }

    @Test func openStreetMapGoesOnlyToAdmins() async throws {
        let stowLake = try #require(S2CellID(token: Live.stowLake))
        let osm = StreamReferenceRequest(l16Token: stowLake.token, layers: [.osm])
        let error = await #expect(throws: GRPCStatusError.self) {
            for try await _ in AlignClient(baseURL: LiveMap.url!, player: walker).reference(osm) {}
        }
        #expect(error?.code == GRPCStatusError.permissionDenied)
    }
}
