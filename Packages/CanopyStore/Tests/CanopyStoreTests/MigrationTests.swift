import CanopyModel
import Foundation
import Testing

@testable import CanopyStore

@Suite struct MigrationTests {
    let player = PlayerID(rawValue: "T:_tester")
    let candidate = TreeCandidate(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
        location: GeoPoint(latitude: 37.7720, longitude: -122.4602), confidence: 0.9, isSynthetic: true)

    /// Writes a schema v1 database, with v1 column names and payloads that use the old `cell` / `cells` keys.
    func writeVersion1(at directory: URL) throws -> (observation: FieldObservation, changeset: Changeset) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: directory.appending(path: "canopy.sqlite").path)
        try db.execute(Schema.migrations[0])
        try db.execute("PRAGMA user_version = 1")

        let tree = candidate.makeTree()
        let observation = FieldObservation(
            meta: RecordMeta(playerID: player, chunk: tree.position.chunk), changesetID: UUID(),
            kind: .treeConfirmed(treeID: tree.id))
        let changeset = try ChangesetBuilder.changeset(
            for: observation, in: CensusState(trees: [tree]), author: player)
        func legacy(_ value: some Encodable) throws -> String {
            String(decoding: try CanopyJSON.encoder.encode(value), as: UTF8.self)
                .replacingOccurrences(of: "\"s2_l19_token\"", with: "\"cell\"")
                .replacingOccurrences(of: "\"s2_l16_tokens\"", with: "\"cells\"")
        }
        try db.run(
            "INSERT INTO candidates (id, payload) VALUES (?, ?)",
            [
                .text(candidate.id.uuidString),
                .text(String(decoding: try CanopyJSON.encoder.encode(candidate), as: UTF8.self)),
            ])
        try db.run(
            """
            INSERT INTO observations (id, created_at, player_id, cell, version, kind, subject_id, changeset_id, payload)
            VALUES (?, 0, ?, ?, 1, 'treeConfirmed', ?, ?, ?)
            """,
            [
                .text(observation.id.uuidString), .text(player.rawValue), .text(tree.position.chunk.token),
                .text(tree.id.uuidString), .text(changeset.id.uuidString), .text(try legacy(observation)),
            ])
        try db.run(
            """
            INSERT INTO changesets (id, created_at, player_id, cell, state, cells, payload, updated_at)
            VALUES (?, 0, ?, ?, 'pending', ?, ?, 0)
            """,
            [
                .text(changeset.id.uuidString), .text(player.rawValue), .text(tree.position.chunk.token),
                .text(tree.position.tile.token), .text(try legacy(changeset)),
            ])
        return (observation, changeset)
    }

    @Test func version1DatabasesMigrateAndKeepTheirData() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "canopy-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (observation, changeset) = try writeVersion1(at: directory)

        let store = try LocalStore(directory: directory)
        #expect(try await store.observations() == [observation])
        #expect(try await store.changesets() == [changeset])
        let tree = try #require(await store.state().trees[candidate.id])
        #expect(tree.proposedStatus == .confirmed)

        let columns = try await store.columns(of: "trees")
        #expect(columns.contains("s2_l16_token"))
        #expect(columns.contains("s2_l19_token"))
        #expect(!columns.contains("cell") && !columns.contains("tile"))
        #expect(try await store.columns(of: "changesets").contains("s2_l16_tokens"))
        #expect(try await store.schemaVersion() == Schema.migrations.count)

        // New writes use the new names and still sit beside the migrated rows.
        _ = try await store.record(.treeRejected(treeID: candidate.id), by: player)
        #expect(try await store.observations().count == 2)
    }
}

extension LocalStore {
    func columns(of table: String) throws -> [String] {
        try databaseForTesting.query("SELECT name FROM pragma_table_info('\(table)')") { $0.string(0) }
    }

    func schemaVersion() throws -> Int {
        try databaseForTesting.userVersion
    }
}
