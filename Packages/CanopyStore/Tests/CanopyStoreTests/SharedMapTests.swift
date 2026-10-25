import CanopyModel
import Foundation
import Testing

@testable import CanopyStore

@Suite struct SharedMapTests {
    let candidate = TreeCandidate(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
        location: GeoPoint(latitude: 37.7699, longitude: -122.4757), height: 20, crownRadius: 5, confidence: 0.9,
        isSynthetic: false)
    var tile: S2CellID { candidate.location.tile }

    func record(_ tree: Tree, version: Int = 1, by player: PlayerID = .aerialSurvey) throws -> SharedRecord {
        var fields = try #require(try JSONValue(encoding: tree).objectValue)
        fields["meta"] = nil
        fields["proposedStatus"] = nil
        fields["s2_l19_token"] = .string(tree.position.chunk.token)
        return SharedRecord(
            kind: .tree, id: tree.id, version: version, tile: tree.position.tile, createdBy: player,
            createdAt: Date(timeIntervalSince1970: 1_761_200_000), fields: fields)
    }

    @Test func aSnapshotThenChangesBringOtherPlayersWork() async throws {
        let store = try LocalStore.inMemory()
        try await store.importCandidates([candidate])
        let elsewhere = GeoPoint(latitude: 37.76995, longitude: -122.47575)
        var theirs = TreeCandidate(id: UUID(), location: elsewhere, confidence: 1, isSynthetic: false).makeTree()
        theirs.countStatus = .confirmed
        try await store.applyShared([
            .init(tile: tile, sequence: 10, content: .snapshot([try record(candidate.makeTree()), try record(theirs)]))
        ])
        #expect(try await store.sharedTiles() == [tile: 10])
        var state = await store.state()
        #expect(state.trees.count == 2)
        #expect(state.trees[theirs.id]?.countStatus == .confirmed)

        // Someone confirms the candidate, and the other tree is deleted.
        let changes = [
            SharedChange(
                op: ChangeOp(
                    op: .update, entity: .tree, id: candidate.id, baseVersion: 1, fields: ["countStatus": "confirmed"]),
                tile: tile, author: PlayerID(rawValue: "T:_a"), appliedAt: .now),
            SharedChange(
                op: ChangeOp(op: .delete, entity: .tree, id: theirs.id, baseVersion: 1, fields: [:]), tile: tile,
                author: PlayerID(rawValue: "T:_b"), appliedAt: .now),
        ]
        let stale = try await store.applyShared([.init(tile: tile, sequence: 12, content: .changes(changes))])
        #expect(stale.isEmpty)
        #expect(try await store.sharedTiles() == [tile: 12])
        state = await store.state()
        #expect(state.trees[candidate.id]?.countStatus == .confirmed)
        #expect(state.trees[candidate.id]?.meta.version == 2)
        #expect(state.trees[theirs.id] == nil)
        #expect(await store.summary().confirmed == 1)
    }

    @Test func aChangeToAnUnknownTreeAsksForASnapshot() async throws {
        let store = try LocalStore.inMemory()
        let change = SharedChange(
            op: ChangeOp(op: .update, entity: .tree, id: UUID(), baseVersion: 3, fields: ["countStatus": "removed"]),
            tile: tile, author: PlayerID(rawValue: "T:_a"), appliedAt: .now)
        let stale = try await store.applyShared([.init(tile: tile, sequence: 5, content: .changes([change]))])
        #expect(stale == [tile])
        #expect(try await store.sharedTiles().isEmpty)  // the cursor did not move
    }

    @Test func aNewTreeArrivesAsACreate() async throws {
        let store = try LocalStore.inMemory()
        var tree = TreeCandidate(id: UUID(), location: candidate.location, confidence: 1, isSynthetic: false)
            .makeTree()
        tree.countStatus = .confirmed
        let fields = try record(tree).fields
        let change = SharedChange(
            op: ChangeOp(op: .create, entity: .tree, id: tree.id, baseVersion: 0, fields: fields), tile: tile,
            author: PlayerID(rawValue: "T:_a"), appliedAt: Date(timeIntervalSince1970: 1_761_300_000))
        try await store.applyShared([.init(tile: tile, sequence: 1, content: .changes([change]))])
        let derived = try #require(await store.state().trees[tree.id])
        #expect(derived.meta.playerID == PlayerID(rawValue: "T:_a"))
        #expect(derived.meta.version == 1)
        #expect(try await store.sharedRecords().count == 1)
    }
}
