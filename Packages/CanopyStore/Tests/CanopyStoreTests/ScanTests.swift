import CanopyModel
import Foundation
import Testing

@testable import CanopyStore

/// A scan is identified by its hash, the SHA-256 of its GLB bytes: a store keeps one record of it however often it is
/// saved, imported or pulled back from the shared map, and merges the duplicates older versions let in.
@Suite struct ScanTests {
    let player = PlayerID(rawValue: "T:_tester")
    let other = PlayerID(rawValue: "T:_other")
    let candidates = [
        TreeCandidate(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            location: GeoPoint(latitude: 37.7699, longitude: -122.4757), height: 20, crownRadius: 5,
            confidence: 0.9, isSynthetic: true),
        TreeCandidate(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            location: GeoPoint(latitude: 37.7704, longitude: -122.5090), height: 12, crownRadius: 3,
            confidence: 0.6, isSynthetic: true),
    ]
    let dbh = DBH(diameter: Quantity(0.42, uncertainty: 0.008), method: .lidarCircleFit)
    let mesh = Data("glTF trunk mesh".utf8)
    var hash: BlobRef { BlobStore.reference(for: mesh) }
    var tree: UUID { candidates[0].id }

    func makeStore() async throws -> LocalStore {
        let store = try LocalStore.inMemory()
        try await store.importCandidates(candidates)
        return store
    }

    /// A new record of the scan, as one more tap on Save makes.
    func record(about subject: UUID, at date: Date = .now) -> Evidence {
        Evidence(
            meta: RecordMeta(createdAt: date, playerID: player, chunk: candidates[0].location.chunk), blob: hash,
            byteCount: mesh.count, kind: .trunkScan, subjectID: subject, cropRadius: 1.5, vertexCount: 3,
            triangleCount: 1)
    }

    func measurement(of tree: UUID) -> FieldObservation.Kind {
        .trunkMeasured(treeID: tree, dbh: dbh, lean: nil, evidence: hash)
    }

    @Test func savingAScanAgainAddsNothing() async throws {
        let store = try await makeStore()
        let first = record(about: tree)
        #expect(try await store.addEvidence(first, data: mesh) == first)
        let measured = try await store.record(measurement(of: tree), by: player)

        let again = record(about: tree)
        #expect(again.id != first.id)
        #expect(try await store.addEvidence(again, data: mesh) == first, "links to the record already stored")
        let remeasured = try await store.record(measurement(of: tree), by: player)
        #expect(remeasured.observation == measured.observation)
        #expect(remeasured.changeset == measured.changeset)

        #expect(try await store.allEvidence() == [first])
        #expect(try await store.evidence(hash: hash) == first)
        #expect(try await store.evidenceCount() == 1)
        #expect(try await store.observations() == [measured.observation])
        #expect(try await store.changesets() == [measured.changeset])
        #expect(await store.state().trees[tree]?.evidenceRefs == [hash])
    }

    @Test func aScanStaysWithTheTreeItWasFirstSavedFor() async throws {
        // Save as a new tree tapped twice made two trees: the scan belongs to the first.
        let store = try await makeStore()
        let second = candidates[1].id
        let first = record(about: tree)
        try await store.addEvidence(first, data: mesh)
        let measured = try await store.record(measurement(of: tree), by: player)

        #expect(try await store.addEvidence(record(about: second), data: mesh).subjectID == tree)
        #expect(try await store.record(measurement(of: second), by: player).observation == measured.observation)
        #expect(await store.state().trees[second]?.evidenceRefs == [])
        #expect(try await store.observations().count == 1)
    }

    @Test func aScanWhoseMeasurementWasRejectedCanBeRecordedAgain() async throws {
        let store = try await makeStore()
        try await store.addEvidence(record(about: tree), data: mesh)
        let measured = try await store.record(measurement(of: tree), by: player)
        var rejected = measured.changeset
        rejected.state = .rejected
        try await store.updateChangeset(rejected)
        #expect(await store.state().trees[tree]?.evidenceRefs == [])

        let retried = try await store.record(measurement(of: tree), by: player)
        #expect(retried.observation.id != measured.observation.id)
        #expect(await store.state().trees[tree]?.evidenceRefs == [hash])
        // Standing again, so one more save adds nothing.
        #expect(try await store.record(measurement(of: tree), by: player).observation == retried.observation)
        #expect(try await store.observations().count == 2)
        #expect(try await store.evidenceCount() == 1)
    }

    @Test func ourOwnScanDownloadedOrPulledBackAddsNothing() async throws {
        let store = try await makeStore()
        let first = record(about: tree)
        try await store.addEvidence(first, data: mesh)
        var changeset = try await store.record(measurement(of: tree), by: player).changeset
        changeset.state = .applied
        try await store.updateChangeset(changeset)

        // The shared map brings the tree back as the server applied it, naming the scan.
        var applied = try #require(await store.state().trees[tree])
        applied.countStatus = .verified
        applied.proposedStatus = nil
        var fields = try #require(try JSONValue(encoding: applied).objectValue)
        fields["meta"] = nil
        fields["s2_l19_token"] = .string(applied.position.chunk.token)
        try await store.applyShared([
            .init(
                tile: applied.position.tile, sequence: 2,
                content: .snapshot([
                    SharedRecord(
                        kind: .tree, id: tree, version: 2, tile: applied.position.tile, createdBy: other,
                        createdAt: Date(timeIntervalSince1970: 1_761_200_000), fields: fields)
                ]))
        ])
        #expect(await store.state().trees[tree]?.evidenceRefs == [hash])

        // Downloading the mesh again (GetBlob), then importing it with a record of its own.
        try store.blobs.put(mesh, expecting: hash)
        #expect(try await store.addEvidence(record(about: tree), data: mesh) == first)
        #expect(try await store.record(measurement(of: tree), by: player).changeset.id == changeset.id)

        #expect(try await store.allEvidence() == [first])
        #expect(try await store.observations().count == 1)
        #expect(try await store.changesets().count == 1)
        #expect(await store.state().trees[tree]?.evidenceRefs == [hash])
    }

    @Test func duplicatesFromBeforeVersion6AreMergedWhenTheStoreOpens() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "canopy-scans-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_761_200_000)
        let first = record(about: tree, at: start)
        let measured: FieldObservation
        do {
            let store = try LocalStore(directory: directory)
            try await store.importCandidates(candidates)
            try await store.addEvidence(first, data: mesh)
            measured = try await store.record(measurement(of: tree), by: player).observation

            // Version 5 let Save tapped twice in: another record and measurement for the tree, and a record of the
            // same scan for a second tree.
            let state = await store.state()
            let again = FieldObservation(
                meta: RecordMeta(createdAt: start.addingTimeInterval(1), playerID: player, chunk: measured.meta.chunk),
                changesetID: UUID(), kind: measurement(of: tree))
            try await store.rewindToVersion5(
                adding: [
                    record(about: tree, at: start.addingTimeInterval(1)),
                    record(about: candidates[1].id, at: start.addingTimeInterval(2)),
                ],
                observations: [(again, try ChangesetBuilder.changeset(for: again, in: state, author: player))])
            #expect(try await store.tableCount("evidence") == 3)
        }

        let store = try LocalStore(directory: directory)
        #expect(try await store.schemaVersion() == Schema.migrations.count)
        #expect(try await store.allEvidence() == [first], "the first record of the scan is kept")
        #expect(try await store.evidence(about: candidates[1].id).isEmpty)
        #expect(try await store.observations().count == 2, "observations are append-only and stay")
        #expect(await store.state().trees[tree]?.evidenceRefs == [hash])
        #expect(await store.state().trees[candidates[1].id]?.evidenceRefs == [])
        #expect(store.blobs.contains(hash))

        // Saving the scan again links to what is there: the first record and the first measurement.
        #expect(try await store.addEvidence(record(about: tree), data: mesh) == first)
        #expect(try await store.record(measurement(of: tree), by: player).observation == measured)
        #expect(try await store.observations().count == 2)

        // One record per scan from now on, and still immutable.
        await #expect(throws: SQLiteError.self) {
            try await store.execute(
                """
                INSERT INTO evidence (id, created_at, player_id, s2_l19_token, blob, subject_id, kind, payload)
                SELECT 'another', created_at, player_id, s2_l19_token, blob, subject_id, kind, payload FROM evidence
                """)
        }
        await #expect(throws: SQLiteError.self) {
            try await store.execute("DELETE FROM evidence")
        }
    }
}

extension LocalStore {
    /// Takes the database back to schema 5, which had no unique index on `evidence.blob` and no scan alignments, and
    /// writes rows as a second save of a scan wrote them then.
    func rewindToVersion5(adding records: [Evidence], observations: [(FieldObservation, Changeset)]) throws {
        let db = databaseForTesting
        try db.execute(
            """
            DROP INDEX evidence_blob;
            DROP TABLE scan_alignments;
            PRAGMA user_version = 5;
            UPDATE store_meta SET value = 'schema 5, derivation \(Schema.derivation)' WHERE key = 'derived';
            """)
        for record in records {
            try Self.insert(record, in: db)
        }
        for (observation, changeset) in observations {
            try Self.insert(observation, in: db)
            try Self.insert(changeset, in: db)
        }
    }
}
