import CanopyModel
import Foundation
import Testing

@testable import CanopyStore

/// What opening a store costs when it holds a city's worth of pulled trees (40,000 over Golden Gate Park), as a phone
/// that followed the whole city does. Before, opening it read and derived everything on the caller's thread (the main
/// thread, at launch); now opening only opens the database and `prepare` does the rest on the store's executor.
/// Timings are printed, not checked; run with `CANOPY_STORE_COST=1 swift test --filter StoreCostTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CANOPY_STORE_COST"] != nil))
struct StoreCostTests {
    @Test func openingAStoreWithACityOfSharedTrees() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "store-cost-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var random = SystemRandomNumberGenerator()
        var byTile: [S2CellID: [SharedRecord]] = [:]
        for _ in 0..<40_000 {
            let point = GeoPoint(
                latitude: Double.random(in: 37.7655...37.7735, using: &random),
                longitude: Double.random(in: -122.5100 ... -122.4550, using: &random))
            let tree = TreeCandidate(id: UUID(), location: point, confidence: 0.8, isSynthetic: false).makeTree()
            var fields = try #require(try JSONValue(encoding: tree).objectValue)
            fields["meta"] = nil
            fields["proposedStatus"] = nil
            fields["s2_l19_token"] = .string(tree.position.chunk.token)
            byTile[point.tile, default: []].append(
                SharedRecord(
                    kind: .tree, id: tree.id, version: 1, tile: point.tile, createdBy: .aerialSurvey,
                    createdAt: Date(timeIntervalSince1970: 1_790_000_000), fields: fields))
        }
        let store = try LocalStore(directory: folder)
        try await store.applyShared(
            byTile.map { LocalStore.SharedTileUpdate(tile: $0.key, sequence: 1, content: .snapshot($0.value)) })
        #expect(await store.state().trees.count == 40_000)

        let opening = ContinuousClock.now
        let reopened = try LocalStore(directory: folder)
        let opened = ContinuousClock.now
        try await reopened.prepare()
        let prepared = ContinuousClock.now
        #expect(await reopened.state().trees.count == 40_000)
        print("cost: open a store with 40,000 shared trees (\(byTile.count) tiles), on the caller: \(opened - opening)")
        print("cost: prepare it, on the store's executor: \(prepared - opened)")
    }
}
