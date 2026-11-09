import CanopyMap
import CanopyModel
import CanopyReference
import CanopyStore
import Foundation

/// The shared map: other players' trees and approvals, pulled from the Gerardus server, and the review queue.
extension AppModel {
    /// The tiles a sync follows: the tiles the map draws in full now (`MapDetail`: at most 16 level-16 tiles, and only
    /// when the map is close enough to draw any), and the tiles pulled before where the player has been, that is, drawn
    /// in full on the map at some time (`visitedTiles`) or recorded something in. A tile pulled for some other reason
    /// (an earlier version followed every tile in the city) is forgotten (`forgetUnfollowed`) and pulled again when the
    /// map draws it in full. Everything else the map shades from the server's summaries.
    func followedTiles() async throws -> Set<S2CellID> {
        if let viewport = mapViewport { visitedTiles.formUnion(Self.drawnTiles(in: viewport)) }
        let pulled = Set(try await store.sharedTiles().keys)
        let recorded = Set(changesets.filter { $0.meta.playerID == player.id }.flatMap(\.tiles))
        return pulled.intersection(visitedTiles.union(recorded)).union(mapViewport.map(Self.drawnTiles) ?? [])
    }

    /// Forgets the pulled tiles a sync does not follow. Earlier versions pulled every tile in the city with trees, tens
    /// of thousands of them after a park-wide detection, and a store holding them takes seconds to read at every launch
    /// and to re-derive at every change. This device's own work is in tiles it follows, and stays.
    func forgetUnfollowed(_ followed: Set<S2CellID>) async throws {
        let unfollowed = Set(try await store.sharedTiles().keys).subtracting(followed)
        guard !unfollowed.isEmpty else { return }
        try await store.forgetShared(unfollowed)
    }

    /// The tiles a view draws in full, and so pulls: none for a view too wide to draw any.
    nonisolated static func drawnTiles(in viewport: MapViewport) -> Set<S2CellID> {
        MapDetail(region: viewport).detailed ?? []
    }

    nonisolated static let visitedTilesKey = "canopy.visitedTiles"

    nonisolated static func savedVisitedTiles(defaults: UserDefaults = .standard) -> Set<S2CellID> {
        Set((defaults.stringArray(forKey: visitedTilesKey) ?? []).compactMap(S2CellID.init(token:)))
    }

    static func saveVisitedTiles(_ tiles: Set<S2CellID>, defaults: UserDefaults = .standard) {
        guard !isTesting() else { return }
        defaults.set(tiles.map(\.token).sorted(), forKey: visitedTilesKey)
    }

    /// Every level-16 tile in the city (`MapViewport.sanFrancisco`, its corners included): the children of the
    /// level-13 cells over it, some fourteen thousand, which the server answers about in four calls.
    nonisolated static let wholeCity: [S2CellID] = Set(
        MapDetail.cells(in: .sanFrancisco, level: 13, step: 400).flatMap { $0.children(atLevel: S2CellID.tileLevel) }
    ).sorted()

    /// How long the whole city's summaries are kept before they are asked for again.
    static let citySummaryAge: TimeInterval = 300

    /// When the map shows the whole city, asks the server what every tile in it holds, at most every five minutes, so
    /// the map shades every tile from the counts (and marks those detected in full) wherever it is. Only the counts: a
    /// tile's trees come to the phone when the map draws it in full (`followedTiles`), so a park-wide detection on the
    /// server is a few calls here rather than tens of thousands of trees. A server too old to answer leaves things as
    /// they were.
    func summariseCity(_ client: GerardusMapClient) async throws {
        guard showsWholeCity else { return }
        if let asked = cityAskedAt, Date().timeIntervalSince(asked) < Self.citySummaryAge { return }
        let tiles = Self.wholeCity
        guard let answer = try await Self.summaries(of: tiles, client) else { return }
        let patches = await Task.detached(priority: .utility) { Self.patches(answer) }.value
        let now = Date()
        cityAskedAt = now
        var known = serverTiles
        for tile in tiles {
            summariesAskedAt[tile] = now
            known[tile] = patches[tile]
        }
        serverTiles = known
        detectedTiles.formUnion(answer.values.filter { $0.detectedAt != nil }.map(\.tile))
    }

    /// The server's counts as the map's patches. Each works out its tile's corners and area, which for the whole city
    /// is thousands of tiles: called off the main actor.
    nonisolated static func patches(_ answer: [S2CellID: GerardusMapClient.TileCounts]) -> [S2CellID: TileSummary] {
        answer.mapValues { TileSummary(id: $0.tile, detected: $0.detected, reviewed: $0.reviewed, tags: $0.tags) }
    }

    /// Brings the followed tiles up to date: a snapshot for a tile never pulled (or one the server has reset), the ops
    /// applied since for the rest. Everything lands in one store transaction. Each tile is a question of its own, so
    /// they are asked a few at a time rather than one round trip after another.
    func pullSharedMap(_ client: GerardusMapClient, tiles: Set<S2CellID>? = nil) async throws {
        let cursors = try await store.sharedTiles()
        let followed: [S2CellID]
        if let tiles { followed = tiles.sorted() } else { followed = try await followedTiles().sorted() }
        // One question for every tile pulled before, rather than one each: only the tiles that changed are pulled.
        let summaries = try await Self.summaries(of: followed.filter { cursors[$0] != nil }, client)
        let tiles = Self.tilesToPull(followed, cursors: cursors, summaries: summaries)
        let updates = try await Self.concurrently(tiles) {
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

    /// Which followed tiles to pull, given the server's summaries of the ones pulled before: a tile never pulled, and a
    /// tile whose latest sequence is not the one this phone holds (the server moved on, or its database was replaced).
    /// Without summaries, from a server too old to give them, every tile.
    nonisolated static func tilesToPull(
        _ followed: [S2CellID], cursors: [S2CellID: Int64], summaries: [S2CellID: GerardusMapClient.TileCounts]?
    ) -> [S2CellID] {
        guard let summaries else { return followed }
        return followed.filter { tile in
            guard let since = cursors[tile] else { return true }
            return (summaries[tile]?.latestSequence ?? 0) != since
        }
    }

    /// The server's summaries of some tiles, or nil from a server too old to give them (it answers UNIMPLEMENTED).
    nonisolated static func summaries(
        of tiles: [S2CellID], _ client: GerardusMapClient
    ) async throws -> [S2CellID: GerardusMapClient.TileCounts]? {
        guard !tiles.isEmpty else { return [:] }
        do {
            return try await client.tileSummaries(tiles)
        } catch let error as GRPCStatusError where error.code == GRPCStatusError.unimplemented {
            return nil
        }
    }

    /// The level-16 tiles a view could shade from the server's summaries, nearest the centre first and at most one
    /// call's worth: every tile round it (with the map's margin), or every tile in the level-13 cells round it when it
    /// is zoomed out that far. None for a view close enough to draw every tile in full.
    nonisolated static func summaryTiles(around viewport: MapViewport) -> [S2CellID] {
        let detail = MapDetail(region: viewport)
        guard detail.tilesInView > MapDetail.detailedTileLimit else { return [] }
        let padded = MapViewport(
            center: viewport.center, latitudeDelta: viewport.latitudeDelta * 1.3,
            longitudeDelta: viewport.longitudeDelta * 1.3)
        let tiles: Set<S2CellID> =
            detail.summaryLevel < S2CellID.tileLevel
            ? Set(
                MapDetail.cells(in: padded, level: detail.summaryLevel, step: 400)
                    .flatMap { $0.children(atLevel: S2CellID.tileLevel) })
            : MapDetail.cells(in: padded, level: S2CellID.tileLevel, step: 40)
        let frame = LocalFrame(origin: viewport.center)
        let distances: [(tile: S2CellID, metres: Double)] = tiles.map { tile in
            (tile, frame.enu(of: tile.center).horizontalDistance)
        }
        let nearest = distances.sorted { a, b in
            a.metres != b.metres ? a.metres < b.metres : a.tile < b.tile
        }
        return nearest.prefix(GerardusMapClient.summaryBatch).map(\.tile)
    }

    /// Asks the server, a moment after the map settles, what the tiles round it hold, so a wide view shades tiles this
    /// phone never pulled. Tiles asked about in the last two minutes are not asked again. A server too old to answer,
    /// or no answer at all, leaves the map shading what the phone holds. It needs nothing from the store, so it runs
    /// while the store is still being read at launch.
    func summariseSoon(_ viewport: MapViewport) {
        guard let client = mapClient, !Self.isTesting() else { return }
        let now = Date()
        let tiles = Self.summaryTiles(around: viewport).filter {
            summariesAskedAt[$0].map { now.timeIntervalSince($0) > 120 } ?? true
        }
        guard !tiles.isEmpty else { return }
        pendingSummaries?.cancel()
        pendingSummaries = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self,
                let answer = try? await Self.summaries(of: tiles, client), !Task.isCancelled
            else { return }
            let patches = await Task.detached(priority: .utility) { Self.patches(answer) }.value
            var known = serverTiles
            for tile in tiles {
                summariesAskedAt[tile] = now
                known[tile] = patches[tile]
            }
            serverTiles = known
            detectedTiles.formUnion(answer.values.filter { $0.detectedAt != nil }.map(\.tile))
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
    /// One call per tile, so only the followed tiles, not every tile ever pulled.
    func refreshReviewQueue(_ client: GerardusMapClient, tiles followed: Set<S2CellID>? = nil) async throws {
        async let asked = client.player()
        let tiles: [S2CellID]
        if let followed { tiles = followed.sorted() } else { tiles = try await followedTiles().sorted() }
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

    /// The map stopped moving: remember where, and pull the tiles it draws in full if any are new.
    func mapDidSettle(_ viewport: MapViewport) {
        mapViewport = viewport
        summariseSoon(viewport)
        let drawn = Self.drawnTiles(in: viewport)
        guard !drawn.isEmpty, !drawn.isSubset(of: followedTiles) else { return }
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
