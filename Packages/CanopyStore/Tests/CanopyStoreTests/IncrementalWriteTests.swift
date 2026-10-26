import CanopyModel
import Foundation
import Testing

@testable import CanopyStore

/// Writes keep what derivation reads in memory and write only the rows that changed. Whatever happens, the result has
/// to be what a store opened afresh on the same file derives, row for row.
@Suite struct IncrementalWriteTests {
    let player = PlayerID(rawValue: "T:_tester")
    let other = PlayerID(rawValue: "T:_other")

    /// Candidates on a grid near Stow Lake, about 11 m apart.
    func candidates(_ range: Range<Int>, height: Double = 20) -> [TreeCandidate] {
        range.map { k in
            let location = GeoPoint(
                latitude: 37.7690 + Double(k / 20) * 1e-4, longitude: -122.4770 + Double(k % 20) * 1e-4)
            return TreeCandidate(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", k))!, location: location,
                height: height, crownRadius: 4, confidence: 0.8, isSynthetic: false, source: "test \(k % 3)")
        }
    }

    func rows(_ store: LocalStore, _ table: String) async throws -> [String] {
        try await store.rows(table)
    }

    @Test func manyWritesEndWhereAFreshDerivationDoes() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "incremental-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LocalStore(directory: folder)
        try await store.importCandidates(candidates(0..<120))

        // A player confirms, rejects and measures; some changesets are applied, one rejected.
        let ids = candidates(0..<120).map(\.id)
        _ = try await store.record(.treeConfirmed(treeID: ids[3]), by: player)
        _ = try await store.record(.treeRejected(treeID: ids[4]), by: player)
        let (_, measured) = try await store.record(
            .trunkMeasured(
                treeID: ids[5], dbh: DBH(diameter: Quantity(0.5, uncertainty: 0.01), method: .lidarCircleFit),
                lean: nil, evidence: BlobStore.reference(for: Data("mesh".utf8))), by: player)
        let added = Tree(
            meta: RecordMeta(playerID: player, chunk: candidates(200..<201)[0].location.chunk),
            position: Position(
                geo: candidates(200..<201)[0].location, covariance: .isotropic(horizontal: 3, vertical: 3)),
            countStatus: .proposed)
        _ = try await store.record(.treeAdded(added), by: player)
        var changesets = try await store.changesets()
        changesets[0].state = .applied
        try await store.updateChangeset(changesets[0])
        var rejected = measured
        rejected.state = .rejected
        try await store.updateChangeset(rejected)

        // Loading an area again: some candidates go, some change, new ones come; observed ones stay.
        let next = candidates(60..<180, height: 22)
        let removed = try await store.replaceCandidates(
            where: { $0.latitude < 37.7696 }, with: next.filter { $0.location.latitude < 37.7696 })
        #expect(removed.replaced > 0)

        // Another player's tree arrives from the shared map.
        var theirs = candidates(300..<301)[0].makeTree()
        theirs.countStatus = .confirmed
        var fields = try #require(try JSONValue(encoding: theirs).objectValue)
        fields["meta"] = nil
        fields["proposedStatus"] = nil
        fields["s2_l19_token"] = .string(theirs.position.chunk.token)
        try await store.applyShared([
            .init(
                tile: theirs.position.tile, sequence: 4,
                content: .snapshot([
                    SharedRecord(
                        kind: .tree, id: theirs.id, version: 2, tile: theirs.position.tile, createdBy: other,
                        createdAt: Date(timeIntervalSince1970: 1_761_200_000), fields: fields)
                ]))
        ])
        _ = try await store.record(.treeRejected(treeID: theirs.id), by: player)

        let incremental = await store.state()
        let treeRows = try await rows(store, "trees")
        let tagRows = try await rows(store, "tags")
        let candidateRows = try await rows(store, "candidates")
        let sources = await store.candidateSources()
        let listed = try await store.candidates()
        let changesetsAfter = try await store.changesets()

        // A store opened afresh derives the same from the file alone.
        let reopened = try LocalStore(directory: folder)
        #expect(await reopened.state() == incremental)
        #expect(try await rows(reopened, "trees") == treeRows)
        #expect(try await rows(reopened, "tags") == tagRows)
        #expect(try await rows(reopened, "candidates") == candidateRows)
        #expect(await reopened.candidateSources() == sources)
        #expect(try await reopened.candidates() == listed)
        #expect(try await reopened.changesets() == changesetsAfter)
        // And rebuilding in place rewrites the same rows.
        #expect(try await store.rebuild() == incremental)
        #expect(try await rows(store, "trees") == treeRows)
        #expect(listed.map(\.id.uuidString) == listed.map(\.id.uuidString).sorted())
    }

    @Test func aFailedWriteChangesNothing() async throws {
        let store = try LocalStore.inMemory()
        try await store.importCandidates(candidates(0..<10))
        let before = await store.state()
        // Two candidates with one id: refused, and the store is as it was.
        var twins = candidates(0..<10)
        twins.append(twins[0])
        await #expect(throws: SQLiteError.self) { try await store.importCandidates(twins) }
        #expect(await store.state() == before)
        #expect(try await store.candidateCount() == 10)
        // An observation about a tree the store does not have.
        await #expect(throws: LocalStoreError.self) {
            try await store.record(.treeConfirmed(treeID: UUID()), by: player)
        }
        #expect(await store.state() == before)
        #expect(try await store.observations().isEmpty)
    }

    @Test func aTapWritesOneTree() async throws {
        let store = try LocalStore.inMemory()
        try await store.importCandidates(candidates(0..<300))
        try await store.execute("CREATE TEMP TABLE writes (n INTEGER)")
        try await store.execute(
            "CREATE TEMP TRIGGER count_tree_writes AFTER INSERT ON main.trees BEGIN INSERT INTO writes VALUES (1); END")
        _ = try await store.record(.treeConfirmed(treeID: candidates(7..<8)[0].id), by: player)
        #expect(try await store.tableCount("temp.writes") == 1)
    }
}

extension LocalStore {
    /// Every row of a table as text, by id.
    func rows(_ table: String) throws -> [String] {
        try databaseForTesting.query("SELECT * FROM \(table) ORDER BY id") { row in
            (0..<row.columnCount).map { row.text(Int32($0)) ?? "NULL" }.joined(separator: "|")
        }
    }
}
