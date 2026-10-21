import CanopyModel
import Foundation

public enum LocalStoreError: Error, Equatable {
    /// The observation is about a tree or tag the store does not have.
    case unknownSubject(UUID)
    case unknownChangeset(UUID)
}

/// The app's local data: an append-only observation log, the changesets that share it, immutable evidence,
/// the aerial base layer, and current-state tables derived from all of those.
///
/// Every write re-derives the current state (`CensusState.derive`) and rewrites the `trees` and `tags` tables in
/// the same transaction, so the tables always match the log. Opening a store re-derives too.
public actor LocalStore {
    public nonisolated let blobs: BlobStore
    private let databasePath: String
    private var db: SQLiteDatabase
    private var current = CensusState()

    /// Opens (creating if needed) the store in `directory`: `canopy.sqlite` and a `blobs/` folder.
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileProtection.apply(to: directory)
        let path = directory.appending(path: "canopy.sqlite").path
        try self.init(databasePath: path, blobs: BlobStore(directory: directory.appending(path: "blobs")))
    }

    /// A store whose database lives in memory, with blobs in a fresh temporary folder. For tests and previews.
    public static func inMemory() throws -> LocalStore {
        let blobs = FileManager.default.temporaryDirectory.appending(path: "canopy-blobs-\(UUID().uuidString)")
        return try LocalStore(databasePath: ":memory:", blobs: BlobStore(directory: blobs))
    }

    private init(databasePath: String, blobs: BlobStore) throws {
        self.databasePath = databasePath
        self.blobs = blobs
        let db = try SQLiteDatabase(path: databasePath)
        try Schema.migrate(db)
        self.db = db
        self.current = try Self.derive(db)
        try Self.materialize(current, in: db)
    }

    // MARK: Reading

    /// The current trees and tags.
    public func state() -> CensusState { current }

    public func summary() -> CensusSummary { CensusSummary(trees: current.trees.values) }

    /// Every observation, oldest first.
    public func observations() throws -> [FieldObservation] {
        try Self.observations(db)
    }

    /// Changesets, oldest first, optionally only those in `states`.
    public func changesets(in states: Set<Changeset.State>? = nil) throws -> [Changeset] {
        try db.query("SELECT payload FROM changesets ORDER BY created_at, rowid") { row in
            try CanopyJSON.decoder.decode(Changeset.self, from: Data(row.string(0).utf8))
        }
        .filter { states?.contains($0.state) ?? true }
    }

    public func evidence(about subjectID: UUID) throws -> [Evidence] {
        try db.query(
            "SELECT payload FROM evidence WHERE subject_id = ? ORDER BY created_at, rowid",
            [.text(subjectID.uuidString)]
        ) { row in
            try CanopyJSON.decoder.decode(Evidence.self, from: Data(row.string(0).utf8))
        }
    }

    public func candidateCount() throws -> Int {
        try db.query("SELECT count(*) FROM candidates") { $0.int(0) }.first ?? 0
    }

    // MARK: Writing

    /// Replaces the aerial base layer.
    public func importCandidates(_ candidates: [TreeCandidate]) throws {
        try write {
            try db.run("DELETE FROM candidates")
            for candidate in candidates {
                try db.run(
                    "INSERT INTO candidates (id, payload) VALUES (?, ?)",
                    [.text(candidate.id.uuidString), .text(try Self.json(candidate))]
                )
            }
        }
    }

    /// Records an observation and the changeset that shares it, in one transaction.
    @discardableResult
    public func record(
        _ kind: FieldObservation.Kind, by player: PlayerID, at date: Date = .now
    ) throws
        -> (observation: FieldObservation, changeset: Changeset)
    {
        let subject = kind.subject
        let chunk: S2CellID
        switch kind {
        case .treeAdded(let tree):
            chunk = tree.position.chunk
        case .tagPlaced(let tag):
            chunk = tag.point.position.chunk
        case .treeConfirmed(let id), .treeRejected(let id), .trunkMeasured(let id, _, _, _):
            guard let tree = current.trees[id] else { throw LocalStoreError.unknownSubject(subject.id) }
            chunk = tree.position.chunk
        }
        let observation = FieldObservation(
            meta: RecordMeta(createdAt: date, playerID: player, cell: chunk),
            changesetID: UUID(),
            kind: kind
        )
        let changeset: Changeset
        do {
            changeset = try ChangesetBuilder.changeset(for: observation, in: current, author: player)
        } catch ChangesetBuilderError.unknownSubject(let id) {
            throw LocalStoreError.unknownSubject(id)
        }
        try write {
            try Self.insert(observation, in: db)
            try Self.insert(changeset, in: db)
        }
        return (observation, changeset)
    }

    /// Stores an evidence mesh and its record. The data must hash to `evidence.blob`.
    public func addEvidence(_ evidence: Evidence, data: Data) throws {
        try blobs.put(data, expecting: evidence.blob)
        try db.run(
            """
            INSERT INTO evidence (id, created_at, player_id, cell, blob, subject_id, kind, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(evidence.id.uuidString), .integer(Self.milliseconds(evidence.meta.createdAt)),
                .text(evidence.meta.playerID.rawValue), .text(evidence.meta.cell.token), .text(evidence.blob.rawValue),
                .text(evidence.subjectID.uuidString), .text(evidence.kind.rawValue), .text(try Self.json(evidence)),
            ]
        )
    }

    /// Updates a changeset's state and approvals (for example after a sync) and re-derives.
    public func updateChangeset(_ changeset: Changeset) throws {
        let exists = try db.query("SELECT 1 FROM changesets WHERE id = ?", [.text(changeset.id.uuidString)]) { _ in 1 }
        guard !exists.isEmpty else { throw LocalStoreError.unknownChangeset(changeset.id) }
        try write {
            try db.run(
                "UPDATE changesets SET state = ?, payload = ?, updated_at = ? WHERE id = ?",
                [
                    .text(changeset.state.rawValue), .text(try Self.json(changeset)),
                    .integer(Self.milliseconds(.now)), .text(changeset.id.uuidString),
                ]
            )
        }
    }

    /// Re-derives the current state from the base layer and the log, and rewrites the current-state tables.
    @discardableResult
    public func rebuild() throws -> CensusState {
        try write {}
        return current
    }

    /// Deletes everything: database and blobs. For the debug "Reset local data" action.
    public func reset() throws {
        if databasePath == ":memory:" {
            db = try SQLiteDatabase(path: ":memory:")
        } else {
            db = try SQLiteDatabase(path: ":memory:")  // closes the file connection
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: databasePath + suffix) {
                try FileManager.default.removeItem(atPath: databasePath + suffix)
            }
            db = try SQLiteDatabase(path: databasePath)
        }
        try Schema.migrate(db)
        try blobs.removeAll()
        current = CensusState()
        try Self.materialize(current, in: db)
    }

    // MARK: Internals

    /// The underlying connection, for tests that need raw SQL.
    var databaseForTesting: SQLiteDatabase { db }

    /// Runs `body` and re-derives the state in one transaction.
    private func write(_ body: () throws -> Void) throws {
        let next = try db.transaction {
            try body()
            let next = try Self.derive(db)
            try Self.materialize(next, in: db)
            return next
        }
        current = next
    }

    private static func derive(_ db: SQLiteDatabase) throws -> CensusState {
        let base = try db.query("SELECT payload FROM candidates ORDER BY id") { row in
            try CanopyJSON.decoder.decode(TreeCandidate.self, from: Data(row.string(0).utf8)).makeTree()
        }
        let states = try db.query("SELECT id, state FROM changesets") { row in
            (UUID(uuidString: row.string(0)), Changeset.State(rawValue: row.string(1)))
        }
        var changesetStates: [UUID: Changeset.State] = [:]
        for case (let id?, let state?) in states {
            changesetStates[id] = state
        }
        return CensusState.derive(base: base, observations: try observations(db), changesetStates: changesetStates)
    }

    private static func observations(_ db: SQLiteDatabase) throws -> [FieldObservation] {
        try db.query("SELECT payload FROM observations ORDER BY seq") { row in
            try CanopyJSON.decoder.decode(FieldObservation.self, from: Data(row.string(0).utf8))
        }
    }

    private static func materialize(_ state: CensusState, in db: SQLiteDatabase) throws {
        try db.run("DELETE FROM trees")
        try db.run("DELETE FROM tags")
        for tree in state.trees.values {
            try db.run(
                """
                INSERT INTO trees (id, cell, tile, count_status, proposed_status, version, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(tree.id.uuidString), .text(tree.position.chunk.token), .text(tree.position.tile.token),
                    .text(tree.countStatus.rawValue), .optional(tree.proposedStatus?.rawValue), .int(tree.meta.version),
                    .text(try json(tree)),
                ]
            )
        }
        for tag in state.tags.values {
            try db.run(
                """
                INSERT INTO tags (id, tree_id, cell, tile, status, version, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(tag.id.uuidString), .text(tag.treeID.uuidString), .text(tag.point.position.chunk.token),
                    .text(tag.point.position.tile.token), .text(tag.status.rawValue), .int(tag.meta.version),
                    .text(try json(tag)),
                ]
            )
        }
    }

    private static func insert(_ observation: FieldObservation, in db: SQLiteDatabase) throws {
        try db.run(
            """
            INSERT INTO observations (id, created_at, player_id, cell, version, kind, subject_id, changeset_id, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(observation.id.uuidString), .integer(milliseconds(observation.meta.createdAt)),
                .text(observation.meta.playerID.rawValue), .text(observation.meta.cell.token),
                .int(observation.meta.version), .text(observation.kind.name),
                .text(observation.kind.subject.id.uuidString), .optional(observation.changesetID?.uuidString),
                .text(try json(observation)),
            ]
        )
    }

    private static func insert(_ changeset: Changeset, in db: SQLiteDatabase) throws {
        try db.run(
            """
            INSERT INTO changesets (id, created_at, player_id, cell, state, cells, payload, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(changeset.id.uuidString), .integer(milliseconds(changeset.meta.createdAt)),
                .text(changeset.meta.playerID.rawValue), .text(changeset.meta.cell.token),
                .text(changeset.state.rawValue), .text(changeset.cells.map(\.token).joined(separator: " ")),
                .text(try json(changeset)), .integer(milliseconds(changeset.meta.createdAt)),
            ]
        )
    }

    private static func json(_ value: some Encodable) throws -> String {
        String(decoding: try CanopyJSON.encoder.encode(value), as: UTF8.self)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

/// Database schema and migrations, tracked with `PRAGMA user_version`.
enum Schema {
    static let migrations: [String] = [
        // 1: initial schema
        """
        CREATE TABLE observations (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            created_at INTEGER NOT NULL,
            player_id TEXT NOT NULL,
            cell TEXT NOT NULL,
            version INTEGER NOT NULL,
            kind TEXT NOT NULL,
            subject_id TEXT NOT NULL,
            changeset_id TEXT,
            payload TEXT NOT NULL
        );
        CREATE INDEX observations_subject ON observations (subject_id);
        CREATE INDEX observations_changeset ON observations (changeset_id);
        CREATE TRIGGER observations_no_update BEFORE UPDATE ON observations
            BEGIN SELECT RAISE(ABORT, 'observations are append-only'); END;
        CREATE TRIGGER observations_no_delete BEFORE DELETE ON observations
            BEGIN SELECT RAISE(ABORT, 'observations are append-only'); END;

        CREATE TABLE changesets (
            id TEXT PRIMARY KEY,
            created_at INTEGER NOT NULL,
            player_id TEXT NOT NULL,
            cell TEXT NOT NULL,
            state TEXT NOT NULL,
            cells TEXT NOT NULL,
            payload TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        );
        CREATE INDEX changesets_state ON changesets (state);

        CREATE TABLE evidence (
            id TEXT PRIMARY KEY,
            created_at INTEGER NOT NULL,
            player_id TEXT NOT NULL,
            cell TEXT NOT NULL,
            blob TEXT NOT NULL,
            subject_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            payload TEXT NOT NULL
        );
        CREATE INDEX evidence_subject ON evidence (subject_id);
        CREATE TRIGGER evidence_no_update BEFORE UPDATE ON evidence
            BEGIN SELECT RAISE(ABORT, 'evidence is immutable'); END;
        CREATE TRIGGER evidence_no_delete BEFORE DELETE ON evidence
            BEGIN SELECT RAISE(ABORT, 'evidence is immutable'); END;

        CREATE TABLE candidates (
            id TEXT PRIMARY KEY,
            payload TEXT NOT NULL
        );

        CREATE TABLE trees (
            id TEXT PRIMARY KEY,
            cell TEXT NOT NULL,
            tile TEXT NOT NULL,
            count_status TEXT NOT NULL,
            proposed_status TEXT,
            version INTEGER NOT NULL,
            payload TEXT NOT NULL
        );
        CREATE INDEX trees_tile ON trees (tile);

        CREATE TABLE tags (
            id TEXT PRIMARY KEY,
            tree_id TEXT NOT NULL,
            cell TEXT NOT NULL,
            tile TEXT NOT NULL,
            status TEXT NOT NULL,
            version INTEGER NOT NULL,
            payload TEXT NOT NULL
        );
        CREATE INDEX tags_tree ON tags (tree_id);
        """
    ]

    static func migrate(_ db: SQLiteDatabase) throws {
        let version = try db.userVersion
        guard version < migrations.count else { return }
        try db.transaction {
            for index in version..<migrations.count {
                try db.execute(migrations[index])
            }
            try db.execute("PRAGMA user_version = \(migrations.count)")
        }
    }
}
