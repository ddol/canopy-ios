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
    /// applied since for the rest. Everything lands in one store transaction. Each tile is a question of its own, so
    /// they are asked a few at a time rather than one round trip after another.
    func pullSharedMap(_ client: GerardusMapClient) async throws {
        let cursors = try await store.sharedTiles()
        let updates = try await Self.concurrently(try await followedTiles().sorted()) {
            tile -> LocalStore.SharedTileUpdate? in
            guard let since = cursors[tile] else { return try await Self.snapshot(tile, client) }
            let page = try await client.pullChanges(in: tile, since: since)
            if page.latestSequence < since {
                // The server's log went backwards: its database was replaced. Start the tile again.
                return try await Self.snapshot(tile, client)
            }
            guard !page.changes.isEmpty else { return nil }
            let changes = page.changes.map { change in
                SharedChange(
                    op: change.op, tile: change.tile, author: change.author ?? PlayerID(rawValue: ""),
                    appliedAt: change.appliedAt)
            }
            return .init(tile: tile, sequence: page.latestSequence, content: .changes(changes))
        }
        .compactMap { $0 }
        guard !updates.isEmpty else { return }
        let stale = try await store.applyShared(updates)
        let snapshots = try await Self.concurrently(stale.sorted()) { try await Self.snapshot($0, client) }
        if !snapshots.isEmpty {
            try await store.applyShared(snapshots)
        }
    }

    nonisolated private static func snapshot(
        _ tile: S2CellID, _ client: GerardusMapClient
    ) async throws -> LocalStore.SharedTileUpdate {
        let snapshot = try await client.tile(tile)
        return .init(
            tile: tile, sequence: snapshot.latestSequence, content: .snapshot(snapshot.entities.compactMap(\.record)))
    }

    /// Other players' open changesets in the followed tiles that this player has not agreed with yet, oldest first.
    func refreshReviewQueue(_ client: GerardusMapClient) async throws {
        async let asked = client.player()
        let tiles = try await store.sharedTiles().keys.sorted()
        let open = try await Self.concurrently(tiles) { try await client.openChangesets(in: $0) }
        serverPlayer = try await asked
        var seen: Set<UUID> = []
        var queue: [GerardusMapClient.OpenChangeset] = []
        for open in open.joined() where seen.insert(open.changeset.id).inserted {
            let changeset = open.changeset
            guard changeset.meta.playerID != player.id,
                !changeset.approvals.contains(where: { $0.playerID == player.id })
            else { continue }
            queue.append(open)
        }
        reviewQueue = queue.sorted { $0.changeset.meta.createdAt < $1.changeset.meta.createdAt }
    }

    /// `body` for each item, at most `width` at once (URLSession opens four connections to a server on iOS, and a call
    /// waiting for one would spend its time limit waiting), with the results in the items' order.
    nonisolated static func concurrently<Item: Sendable, Result: Sendable>(
        _ items: [Item], width: Int = 4, _ body: @escaping @Sendable (Item) async throws -> Result
    ) async throws -> [Result] {
        try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            var results = [Result?](repeating: nil, count: items.count)
            var next = 0
            while next < min(width, items.count) {
                let k = next
                group.addTask { (k, try await body(items[k])) }
                next += 1
            }
            while let (k, result) = try await group.next() {
                results[k] = result
                if next < items.count {
                    let k = next
                    group.addTask { (k, try await body(items[k])) }
                    next += 1
                }
            }
            return results.map { $0! }
        }
    }

    // MARK: Syncing on its own

    /// Syncs in a moment, when a Gerardus server is set: after a change, when the map settles on tiles not pulled yet,
    /// after a load, and when the app comes to the front. Requests in a row become one sync. Off under tests, which
    /// sync when they say.
    func syncSoon(after delay: Duration = .seconds(2)) {
        guard mapClient != nil, phase == .ready, !Self.isTesting() else { return }
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await sync()
        }
    }

    /// The map stopped moving: remember where, and pull its tiles if any are new and the view is close enough.
    func mapDidSettle(_ viewport: MapViewport) {
        mapViewport = viewport
        guard viewport.cornerDistance <= Self.pullRadiusLimit, !Self.tiles(in: viewport).isSubset(of: followedTiles)
        else { return }
        syncSoon(after: .seconds(3))
    }

    // MARK: Evidence

    /// The evidence mesh's GLB file on this device, downloading it from the server when another device recorded it.
    func evidenceFile(_ ref: BlobRef) async throws -> URL {
        let blobs = store.blobs
        if blobs.contains(ref) { return blobs.url(for: ref) }
        guard let client = mapClient else { throw NoServerSet() }
        try blobs.put(try await client.blob(ref), expecting: ref)
        return blobs.url(for: ref)
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
