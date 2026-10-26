import CanopyModel
import Foundation
import Testing

@testable import CanopyStore

@Suite struct LocalStoreTests {
    let player = PlayerID(rawValue: "T:_tester")
    let candidates = [
        TreeCandidate(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            location: GeoPoint(latitude: 37.7699, longitude: -122.4757), height: 20, crownRadius: 5,
            confidence: 0.9, isSynthetic: true),
        TreeCandidate(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            location: GeoPoint(latitude: 37.7704, longitude: -122.5090), height: 12, crownRadius: 3,
            confidence: 0.6, isSynthetic: true),
        TreeCandidate(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            location: GeoPoint(latitude: 37.7720, longitude: -122.4602), height: 25, crownRadius: 6,
            confidence: 0.8, isSynthetic: true),
    ]
    let dbh = DBH(diameter: Quantity(0.42, uncertainty: 0.008), method: .lidarCircleFit)

    func makeStore() async throws -> LocalStore {
        let store = try LocalStore.inMemory()
        try await store.importCandidates(candidates)
        return store
    }

    @Test func importedCandidatesAreDetectedTrees() async throws {
        let store = try await makeStore()
        let state = await store.state()
        #expect(state.trees.count == 3)
        #expect(state.trees.values.allSatisfy { $0.countStatus == .detected && $0.proposedStatus == nil })
        #expect(try await store.candidateCount() == 3)
        let summary = await store.summary()
        #expect(summary == CensusSummary(confirmed: 0, estimated: 3, coverage: 0))
    }

    @Test func recordingAppendsAnObservationAndAPendingChangeset() async throws {
        let store = try await makeStore()
        let tree = candidates[0].id
        let (observation, changeset) = try await store.record(.treeConfirmed(treeID: tree), by: player)

        #expect(observation.changesetID == changeset.id)
        #expect(observation.meta.chunk == candidates[0].location.chunk)
        #expect(changeset.state == .pending)
        #expect(changeset.ops.first?.baseVersion == 1)
        #expect(try await store.observations() == [observation])
        #expect(try await store.changesets() == [changeset])
        #expect(try await store.changesets(in: [.applied]).isEmpty)

        let derived = try #require(await store.state().trees[tree])
        #expect(derived.displayStatus == .proposed)
        #expect(derived.proposedStatus == .confirmed)
        let summary = await store.summary()
        #expect(summary.confirmed == 0)
        #expect(abs(summary.coverage - 1.0 / 3.0) < 1e-12)
    }

    @Test func derivedStateFollowsChangesetStates() async throws {
        let store = try await makeStore()
        let tree = candidates[0].id
        _ = try await store.record(.treeConfirmed(treeID: tree), by: player)
        let (_, measure) = try await store.record(
            .trunkMeasured(treeID: tree, dbh: dbh, lean: nil, evidence: BlobStore.reference(for: Data("mesh".utf8))),
            by: player
        )
        #expect(measure.ops.first?.baseVersion == 2)

        var all = try await store.changesets()
        for index in all.indices {
            all[index].state = .applied
            try await store.updateChangeset(all[index])
        }
        var derived = try #require(await store.state().trees[tree])
        #expect(derived.countStatus == .verified)
        #expect(derived.proposedStatus == nil)
        #expect(derived.dbh == dbh)
        #expect(await store.summary().confirmed == 1)

        var rejected = measure
        rejected.state = .rejected
        try await store.updateChangeset(rejected)
        derived = try #require(await store.state().trees[tree])
        #expect(derived.countStatus == .confirmed)
        #expect(derived.dbh == nil)
    }

    @Test func replacingCandidatesInAnAreaKeepsObservedOnesAndOthers() async throws {
        let store = try await makeStore()
        let observed = candidates[0]
        _ = try await store.record(.treeConfirmed(treeID: observed.id), by: player)
        let tiles: Set = [candidates[0].location.tile, candidates[1].location.tile]
        let real = [
            // 1.5 m from the observed candidate: the same tree.
            TreeCandidate(
                id: UUID(), location: GeoPoint(latitude: 37.76991, longitude: -122.47571), height: 21,
                crownRadius: 4, confidence: 0.9, isSynthetic: false, source: "USGS 3DEP"),
            TreeCandidate(
                id: UUID(), location: GeoPoint(latitude: 37.7705, longitude: -122.5091), height: 14, crownRadius: 3,
                confidence: 0.8, isSynthetic: false, source: "USGS 3DEP"),
        ]
        let replacement = try await store.replaceCandidates(where: { tiles.contains($0.tile) }, with: real)
        // The unobserved candidate in those tiles goes; the replacement next to the observed one is the same tree.
        #expect(replacement == .init(replaced: 1, added: 1, gone: 1, samplesGone: 1))
        // The same trees again: nothing new, nothing gone.
        let again = try await store.replaceCandidates(where: { tiles.contains($0.tile) }, with: real)
        #expect(again == .init(replaced: 1, added: 0, gone: 0, samplesGone: 0))
        let ids = Set(try await store.candidates().map(\.id))
        #expect(ids == [observed.id, candidates[2].id, real[1].id])
        let state = await store.state()
        #expect(state.trees[observed.id]?.proposedStatus == .confirmed)
        #expect(state.trees[real[1].id]?.countStatus == .detected)
        #expect(try await store.candidates().first { $0.id == real[1].id }?.source == "USGS 3DEP")
    }

    @Test func observationsAreAppendOnly() async throws {
        let store = try await makeStore()
        _ = try await store.record(.treeRejected(treeID: candidates[1].id), by: player)
        let error = await #expect(throws: SQLiteError.self) {
            try await store.execute("UPDATE observations SET kind = 'treeConfirmed'")
        }
        #expect(error?.message.contains("append-only") == true)
        await #expect(throws: SQLiteError.self) {
            try await store.execute("DELETE FROM observations")
        }
        #expect(try await store.observations().count == 1)
    }

    @Test func rebuildingFromTheLogMatchesTheIncrementalState() async throws {
        let store = try await makeStore()
        _ = try await store.record(.treeConfirmed(treeID: candidates[0].id), by: player)
        _ = try await store.record(.treeRejected(treeID: candidates[1].id), by: player)
        let added = Tree(
            meta: RecordMeta(playerID: player, chunk: GeoPoint(latitude: 37.771, longitude: -122.47).chunk),
            position: Position(
                geo: GeoPoint(latitude: 37.771, longitude: -122.47), covariance: .isotropic(horizontal: 5, vertical: 5)),
            countStatus: .proposed
        )
        _ = try await store.record(.treeAdded(added), by: player)
        let before = await store.state()
        #expect(before.trees.count == 4)
        try await store.execute("DELETE FROM trees")
        #expect(try await store.rebuild() == before)
        #expect(try await store.tableCount("trees") == 4)
    }

    @Test func persistsAcrossReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "canopy-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: LocalStore? = try LocalStore(directory: directory)
        try await store?.importCandidates(candidates)
        _ = try await store?.record(.treeConfirmed(treeID: candidates[2].id), by: player)
        let before = await store?.state()
        store = nil

        let reopened = try LocalStore(directory: directory)
        #expect(await reopened.state() == before)
        #expect(try await reopened.observations().count == 1)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "canopy.sqlite").path))
    }

    @Test func unknownSubjectsAreRejected() async throws {
        let store = try await makeStore()
        let unknown = UUID()
        await #expect(throws: LocalStoreError.unknownSubject(unknown)) {
            try await store.record(.treeConfirmed(treeID: unknown), by: player)
        }
        #expect(try await store.observations().isEmpty)
    }

    @Test func evidenceIsStoredByHashAndImmutable() async throws {
        let store = try await makeStore()
        let mesh = Data("glTF mesh bytes".utf8)
        let ref = BlobStore.reference(for: mesh)
        let tree = candidates[0]
        let evidence = Evidence(
            meta: RecordMeta(playerID: player, chunk: tree.location.chunk),
            blob: ref, byteCount: mesh.count, kind: .trunkScan, subjectID: tree.id,
            cropRadius: 1.5, vertexCount: 3, triangleCount: 1
        )
        try await store.addEvidence(evidence, data: mesh)
        #expect(try await store.evidence(about: tree.id) == [evidence])
        #expect(try store.blobs.data(for: ref) == mesh)
        await #expect(throws: SQLiteError.self) {
            try await store.execute("DELETE FROM evidence")
        }

        var wrong = evidence
        wrong.meta = RecordMeta(playerID: player, chunk: tree.location.chunk)
        wrong.blob = BlobStore.reference(for: Data("other".utf8))
        await #expect(throws: BlobStoreError.self) {
            try await store.addEvidence(wrong, data: mesh)
        }
    }

    @Test func resetDeletesEverything() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "canopy-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(directory: directory)
        try await store.importCandidates(candidates)
        _ = try await store.record(.treeConfirmed(treeID: candidates[0].id), by: player)
        let ref = try store.blobs.put(Data("x".utf8))

        try await store.reset()

        #expect(await store.state().trees.isEmpty)
        #expect(try await store.observations().isEmpty)
        #expect(try await store.changesets().isEmpty)
        #expect(try await store.candidateCount() == 0)
        #expect(!store.blobs.contains(ref))
        // Still usable afterwards.
        try await store.importCandidates(candidates)
        #expect(await store.state().trees.count == 3)
    }
}

extension LocalStore {
    /// Test hook: run raw SQL against the store's database.
    func execute(_ sql: String) throws {
        try databaseForTesting.execute(sql)
    }

    func tableCount(_ table: String) throws -> Int {
        try databaseForTesting.query("SELECT count(*) FROM \(table)") { $0.int(0) }.first ?? 0
    }
}
