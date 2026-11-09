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

    /// Writes a database at schema `version` holding two records of one scan saved a millisecond apart (the later one
    /// inserted first), a third saved in the same millisecond as the earlier, and one record of another scan.
    func writeDuplicateScans(at directory: URL, version: Int) throws -> (kept: Evidence, other: Evidence) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: directory.appending(path: "canopy.sqlite").path)
        for migration in Schema.migrations.prefix(version) {
            try db.execute(migration)
        }
        try db.execute("PRAGMA user_version = \(version)")

        let start = Date(timeIntervalSince1970: 1_761_200_000)
        func scan(_ bytes: String, at date: Date, about subject: UUID = UUID()) -> Evidence {
            Evidence(
                meta: RecordMeta(createdAt: date, playerID: player, chunk: candidate.location.chunk),
                blob: BlobStore.reference(for: Data(bytes.utf8)), byteCount: bytes.utf8.count, kind: .trunkScan,
                subjectID: subject, cropRadius: 1.5, vertexCount: 3, triangleCount: 1)
        }
        let kept = scan("trunk", at: start, about: candidate.id)
        let other = scan("another trunk", at: start.addingTimeInterval(5))
        let column = version == 1 ? "cell" : "s2_l19_token"
        for evidence in [scan("trunk", at: start.addingTimeInterval(0.001)), kept, scan("trunk", at: start), other] {
            var payload = String(decoding: try CanopyJSON.encoder.encode(evidence), as: UTF8.self)
            if version == 1 { payload = payload.replacingOccurrences(of: "\"s2_l19_token\"", with: "\"cell\"") }
            try db.run(
                """
                INSERT INTO evidence (id, created_at, player_id, \(column), blob, subject_id, kind, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(evidence.id.uuidString),
                    .integer(Int64((evidence.meta.createdAt.timeIntervalSince1970 * 1000).rounded())),
                    .text(player.rawValue), .text(evidence.meta.chunk.token), .text(evidence.blob.rawValue),
                    .text(evidence.subjectID.uuidString), .text(evidence.kind.rawValue), .text(payload),
                ])
        }
        return (kept, other)
    }

    @Test(arguments: 1...5) func aStoreFromEachEarlierVersionKeepsTheFirstRecordOfEachScan(version: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "canopy-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (kept, other) = try writeDuplicateScans(at: directory, version: version)

        let store = try LocalStore(directory: directory)
        #expect(try await store.schemaVersion() == Schema.migrations.count)
        #expect(try await store.allEvidence() == [other, kept])
        await #expect(throws: SQLiteError.self) {
            try await store.execute(
                "INSERT INTO evidence SELECT 'another', created_at, player_id, s2_l19_token, blob, subject_id, kind, "
                    + "payload FROM evidence LIMIT 1")
        }
        await #expect(throws: SQLiteError.self) { try await store.execute("DELETE FROM evidence") }
    }

    /// A store from before the scan alignments opens with them: from v5, merging its duplicate scans on the way (v6),
    /// and from v6, without running v6 again.
    @Test(arguments: [5, 6]) func aStoreFromBeforeTheAlignmentsOpensWithThem(version: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "canopy-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var evidence: [Evidence] = []
        if version == 5 {
            let (kept, other) = try writeDuplicateScans(at: directory, version: version)
            evidence = [other, kept]
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let db = try SQLiteDatabase(path: directory.appending(path: "canopy.sqlite").path)
            for migration in Schema.migrations.prefix(version) {
                try db.execute(migration)
            }
            try db.execute("PRAGMA user_version = \(version)")
        }

        let store = try LocalStore(directory: directory)
        #expect(try await store.schemaVersion() == Schema.migrations.count)
        #expect(try await store.allEvidence() == evidence)
        let scan = BlobStore.reference(for: Data("trunk".utf8))
        let tree = UUID()
        try await store.saveScanAlignment(["radius": 0.3], scan: scan, subject: tree)
        #expect(try await store.scanAlignment([String: Double].self, scan: scan, subject: tree) == ["radius": 0.3])
        #expect(try await store.scanAlignments([String: Double].self) == [["radius": 0.3]])
    }

    @Test func aMergeThatFailsLeavesTheStoreAsItWas() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "canopy-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeDuplicateScans(at: directory, version: 5)
        let path = directory.appending(path: "canopy.sqlite").path
        // An index already named evidence_blob makes v6's last statement fail, after the delete.
        try SQLiteDatabase(path: path).execute("CREATE INDEX evidence_blob ON candidates (payload)")

        #expect(throws: SQLiteError.self) { try LocalStore(directory: directory) }
        let db = try SQLiteDatabase(path: path)
        #expect(try db.userVersion == 5)
        #expect(try db.query("SELECT count(*) FROM evidence") { $0.int(0) } == [4])
        #expect(throws: SQLiteError.self) { try db.execute("DELETE FROM evidence") }
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
