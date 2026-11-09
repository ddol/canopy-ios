import CanopyHarness
import CanopyModel
import CanopyReference
import CanopyStore
import Foundation
import Testing

/// What a whole-city sync costs against a shared map holding 40,000 detected trees over Golden Gate Park
/// (`SharedCity`), the way the live server is after a park-wide detection, over the `lan` profile. Before, a sync asked
/// for every city tile's counts and then pulled every tile with trees into the store; now it asks only for the counts.
/// Also how long the store it left behind takes to open and prepare. Timings are printed, not checked; run with
/// `CANOPY_CITY_COST=1 swift test --filter CitySyncCostTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CANOPY_CITY_COST"] != nil))
struct CitySyncCostTests {
    /// The level-16 tiles over San Francisco, as the app asks about them (about fourteen thousand).
    static let wholeCity: [S2CellID] = {
        var tiles: Set<S2CellID> = []
        let step = 60.0
        let latitudeStep = step / 110_574
        let longitudeStep = step / (111_320 * cos(37.768 * .pi / 180))
        var latitude = 37.703
        while latitude <= 37.833 {
            var longitude = -122.516
            while longitude <= -122.354 {
                tiles.insert(GeoPoint(latitude: latitude, longitude: longitude).tile)
                longitude += longitudeStep
            }
            latitude += latitudeStep
        }
        return tiles.sorted()
    }()

    @Test func aWholeCitySyncPullingEveryTileOrOnlyTheCounts() async throws {
        let city = SharedCity(count: 40_000)
        let server = StandInServer(align: StandInAlign(site: Shared.site), map: StandInMap(city: city), profile: .lan)
        try await server.start()
        defer { server.stop() }
        let client = GerardusMapClient(
            baseURL: server.url,
            player: Player(id: PlayerID(rawValue: "T:_cost"), alias: "Cost", source: .gameCenter))
        // The stand-in makes a tile's trees the first time it is asked; make them all first, so only the sync is timed.
        for tile in city.tiles { _ = city.trees(in: tile) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "city-cost-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        // Now: the counts for every city tile, and nothing else.
        server.resetStats()
        var start = ContinuousClock.now
        let counts = try await client.tileSummaries(Self.wholeCity)
        let summarised = ContinuousClock.now - start
        let summaryStats = server.stats
        #expect(Set(counts.keys) == city.tiles.intersection(Self.wholeCity))
        print(
            "cost: counts for \(Self.wholeCity.count) city tiles: \(summarised), \(summaryStats.totalCalls) calls, "
                + "\(summaryStats.totalBytes / 1000) kB")

        // Before: then every tile with trees pulled, four at a time, into the store.
        server.resetStats()
        start = ContinuousClock.now
        let withTrees = counts.keys.sorted()
        var updates: [LocalStore.SharedTileUpdate] = []
        for batch in stride(from: 0, to: withTrees.count, by: 4).map({
            Array(withTrees[$0..<min($0 + 4, withTrees.count)])
        }) {
            try await withThrowingTaskGroup(of: LocalStore.SharedTileUpdate.self) { group in
                for tile in batch {
                    group.addTask {
                        let snapshot = try await client.tile(tile)
                        return .init(
                            tile: tile, sequence: snapshot.latestSequence,
                            content: .snapshot(snapshot.entities.compactMap(\.record)))
                    }
                }
                for try await update in group { updates.append(update) }
            }
        }
        let downloaded = ContinuousClock.now - start
        let pullStats = server.stats
        start = ContinuousClock.now
        let store = try LocalStore(directory: folder)
        try await store.applyShared(updates)
        let stored = ContinuousClock.now - start
        let trees = await store.state().trees.count
        #expect(trees == city.count)
        print(
            "cost: pulling the \(withTrees.count) tiles with trees: \(downloaded), \(pullStats.totalCalls) calls, "
                + "\(pullStats.totalBytes / 1_000_000) MB; storing \(trees) trees: \(stored)")

        // And the store a phone that pulled the city opens at every launch.
        start = ContinuousClock.now
        let reopened = try LocalStore(directory: folder)
        let opened = ContinuousClock.now - start
        start = ContinuousClock.now
        try await reopened.prepare()
        let prepared = ContinuousClock.now - start
        print("cost: opening that store: \(opened) on the caller, then preparing it: \(prepared)")
    }
}
