import CanopyMap
import CanopyModel
import CanopyReference
import CanopyStore
import Foundation

/// The shared map: other players' trees and approvals, pulled from the Gerardus server, and the review queue.
extension AppModel {
    /// The widest view (centre to corner, in metres) whose tiles a sync pulls. Wider views would mean dozens of tiles;
    /// the tiles already pulled are kept up to date either way.
    static let pullRadiusLimit = 400.0

    /// The tiles a sync follows: every tile pulled before, plus the tiles in view when the map is close enough.
    func followedTiles() async throws -> Set<S2CellID> {
        var tiles = Set(try await store.sharedTiles().keys)
        if let viewport = mapViewport, viewport.cornerDistance <= Self.pullRadiusLimit {
            tiles.formUnion(Self.tiles(in: viewport))
        }
        return tiles
    }

    /// The L16 tiles a region touches, found by sampling it every 40 m (a tile is about 125 m across).
    nonisolated static func tiles(in viewport: MapViewport) -> Set<S2CellID> {
        let latitudeStep = 40 / 110_574.0
        let longitudeStep = 40 / (111_320 * cos(viewport.center.latitude * .pi / 180))
        let south = viewport.center.latitude - viewport.latitudeDelta / 2
        let west = viewport.center.longitude - viewport.longitudeDelta / 2
        var tiles: Set<S2CellID> = []
        for latitude in stride(from: south, through: south + viewport.latitudeDelta + latitudeStep, by: latitudeStep) {
            for longitude in stride(
                from: west, through: west + viewport.longitudeDelta + longitudeStep, by: longitudeStep)
            {
                tiles.insert(
                    GeoPoint(
                        latitude: min(latitude, south + viewport.latitudeDelta),
                        longitude: min(longitude, west + viewport.longitudeDelta)
                    ).tile)
            }
        }
        return tiles
    }

    /// Brings the followed tiles up to date: a snapshot for a tile never pulled (or one the server has reset), the ops
    /// applied since for the rest. Everything lands in one store transaction.
    func pullSharedMap(_ client: GerardusMapClient) async throws {
        let cursors = try await store.sharedTiles()
        var updates: [LocalStore.SharedTileUpdate] = []
        for tile in try await followedTiles().sorted() {
            guard let since = cursors[tile] else {
                updates.append(try await snapshot(tile, client))
                continue
            }
            let page = try await client.pullChanges(in: tile, since: since)
            if page.latestSequence < since {
                // The server's log went backwards: its database was replaced. Start the tile again.
                updates.append(try await snapshot(tile, client))
            } else if !page.changes.isEmpty {
                let changes = page.changes.map { change in
                    SharedChange(
                        op: change.op, tile: change.tile, author: change.author ?? PlayerID(rawValue: ""),
                        appliedAt: change.appliedAt)
                }
                updates.append(.init(tile: tile, sequence: page.latestSequence, content: .changes(changes)))
            }
        }
        guard !updates.isEmpty else { return }
        let stale = try await store.applyShared(updates)
        var snapshots: [LocalStore.SharedTileUpdate] = []
        for tile in stale.sorted() {
            snapshots.append(try await snapshot(tile, client))
        }
        if !snapshots.isEmpty {
            try await store.applyShared(snapshots)
        }
    }

    private func snapshot(_ tile: S2CellID, _ client: GerardusMapClient) async throws -> LocalStore.SharedTileUpdate {
        let snapshot = try await client.tile(tile)
        return .init(
            tile: tile, sequence: snapshot.latestSequence, content: .snapshot(snapshot.entities.compactMap(\.record)))
    }

    /// Other players' open changesets in the followed tiles that this player has not agreed with yet, oldest first.
    func refreshReviewQueue(_ client: GerardusMapClient) async throws {
        serverPlayer = try await client.player()
        var seen: Set<UUID> = []
        var queue: [GerardusMapClient.OpenChangeset] = []
        for tile in try await store.sharedTiles().keys.sorted() {
            for open in try await client.openChangesets(in: tile) where seen.insert(open.changeset.id).inserted {
                let changeset = open.changeset
                guard changeset.meta.playerID != player.id,
                    !changeset.approvals.contains(where: { $0.playerID == player.id })
                else { continue }
                queue.append(open)
            }
        }
        reviewQueue = queue.sorted { $0.changeset.meta.createdAt < $1.changeset.meta.createdAt }
    }

    /// Agrees with another player's change, or (trusted players) rejects it with a reason, then syncs.
    func review(_ item: GerardusMapClient.OpenChangeset, approve: Bool, reason: String = "") async {
        guard let client = mapClient else { return }
        do {
            _ = try await client.review(item.changeset.id, approve: approve, note: reason)
            reviewQueue.removeAll { $0.changeset.id == item.changeset.id }
        } catch {
            self.error = "Review failed: \(error.localizedDescription)"
            return
        }
        await sync()
    }
}
