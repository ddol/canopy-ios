import CanopyModel
import Foundation

public enum LocalStoreError: Error, Equatable {
    /// The observation is about a tree or tag the store does not have.
    case unknownSubject(UUID)
    case unknownChangeset(UUID)
}

/// The app's local data: an append-only observation log, the changesets that share it, immutable evidence,
/// the aerial base layer, the shared map pulled from a Gerardus server, and current-state tables derived from all of
/// those.
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

    /// The aerial base layer.
    public func candidates() throws -> [TreeCandidate] {
        try db.query("SELECT payload FROM candidates ORDER BY id") { row in
            try CanopyJSON.decoder.decode(TreeCandidate.self, from: Data(row.string(0).utf8))
        }
    }

    public func candidateCount() throws -> Int {
        try db.query("SELECT count(*) FROM candidates") { $0.int(0) }.first ?? 0
    }

    // MARK: Writing

    /// Replaces the candidates in an area (where `covers` is true) with new ones, such as the aerial trees found there,
    /// keeping every candidate elsewhere. A candidate in the area that a player has already observed stays, so their
    /// work is not orphaned, and a replacement within `duplicateRadius` metres of one it keeps is dropped as the same
    /// tree. Returns how many candidates were removed.
    @discardableResult
    public func replaceCandidates(
        where covers: @Sendable (GeoPoint) -> Bool, with replacements: [TreeCandidate],
        duplicateRadius: Double = 2.5
    ) throws -> Int {
        let current = try candidates()
        let observed = Set(
            try db.query("SELECT DISTINCT subject_id FROM observations") { UUID(uuidString: $0.string(0)) }
                .compactMap { $0 })
        let kept = current.filter { !covers($0.location) || observed.contains($0.id) }
        let keptInArea = kept.filter { covers($0.location) }
        let keptIDs = Set(kept.map(\.id))
        let added = replacements.filter { replacement in
            guard !keptIDs.contains(replacement.id) else { return false }
            let frame = LocalFrame(origin: replacement.location)
            return !keptInArea.contains { frame.enu(of: $0.location).horizontalDistance < duplicateRadius }
        }
        try importCandidates(kept + added)
        return current.count - kept.count
    }

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
            meta: RecordMeta(createdAt: date, playerID: player, chunk: chunk),
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
            INSERT INTO evidence (id, created_at, player_id, s2_l19_token, blob, subject_id, kind, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(evidence.id.uuidString), .integer(Self.milliseconds(evidence.meta.createdAt)),
                .text(evidence.meta.playerID.rawValue), .text(evidence.meta.chunk.token), .text(evidence.blob.rawValue),
                .text(evidence.subjectID.uuidString), .text(evidence.kind.rawValue), .text(try Self.json(evidence)),
            ]
        )
    }

    // MARK: The shared map

    /// What a sync brings for one tile: the tile's whole snapshot, or the ops applied in it since the last pull.
    public struct SharedTileUpdate: Sendable {
        public enum Content: Sendable {
            case snapshot([SharedRecord])
            case changes([SharedChange])
        }

        public var tile: S2CellID
        /// The sequence to pull from next.
        public var sequence: Int64
        public var content: Content

        public init(tile: S2CellID, sequence: Int64, content: Content) {
            self.tile = tile
            self.sequence = sequence
            self.content = content
        }
    }

    /// The tiles pulled from the shared map, and the sequence to pull each from next.
    public func sharedTiles() throws -> [S2CellID: Int64] {
        let rows = try db.query("SELECT s2_l16_token, sequence FROM shared_tiles") { row in
            (S2CellID(token: row.string(0)), Int64(row.int(1)))
        }
        var cursors: [S2CellID: Int64] = [:]
        for case (let tile?, let sequence) in rows {
            cursors[tile] = sequence
        }
        return cursors
    }

    /// Every record pulled from the shared map.
    public func sharedRecords() throws -> [SharedRecord] {
        try Self.sharedRecords(db)
    }

    /// Applies what a sync pulled, in one transaction, and re-derives. A tile whose changes update an entity the store
    /// has never seen (it moved in from a tile not pulled yet) is left as it was and returned: take its snapshot.
    @discardableResult
    public func applyShared(_ updates: [SharedTileUpdate]) throws -> Set<S2CellID> {
        var stale: Set<S2CellID> = []
        try write {
            for update in updates {
                switch update.content {
                case .snapshot(let records):
                    try db.run("DELETE FROM shared WHERE s2_l16_token = ?", [.text(update.tile.token)])
                    for record in records { try Self.upsert(record, in: db) }
                case .changes(let changes):
                    var known = Dictionary(
                        try Self.sharedRecords(db, ids: Set(changes.map(\.op.id))).map { ($0.id, $0) },
                        uniquingKeysWith: { first, _ in first })
                    var changed: [SharedRecord] = []
                    var deleted: Set<UUID> = []
                    var complete = true
                    for change in changes {
                        let op = change.op
                        switch op.op {
                        case .create:
                            known[op.id] = SharedRecord(
                                kind: op.entity, id: op.id, version: 1, tile: change.tile, createdBy: change.author,
                                createdAt: change.appliedAt, fields: op.fields)
                        case .update:
                            guard let record = known[op.id] else {
                                complete = false
                                continue
                            }
                            known[op.id] = record.applying(op, tile: change.tile)
                        case .delete:
                            known[op.id] = nil
                            deleted.insert(op.id)
                            continue
                        }
                        deleted.remove(op.id)
                        changed.append(known[op.id]!)
                    }
                    guard complete else {
                        stale.insert(update.tile)
                        continue
                    }
                    for id in Set(changed.map(\.id)) {
                        if let record = known[id] { try Self.upsert(record, in: db) }
                    }
                    for id in deleted { try db.run("DELETE FROM shared WHERE id = ?", [.text(id.uuidString)]) }
                }
                try db.run(
                    """
                    INSERT INTO shared_tiles (s2_l16_token, sequence, synced_at) VALUES (?, ?, ?)
                    ON CONFLICT (s2_l16_token) DO UPDATE SET sequence = excluded.sequence, synced_at = excluded.synced_at
                    """,
                    [.text(update.tile.token), .integer(update.sequence), .integer(Self.milliseconds(.now))])
            }
        }
        return stale
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
        return CensusState.derive(
            base: base, shared: try sharedRecords(db), observations: try observations(db),
            changesetStates: changesetStates)
    }

    private static func sharedRecords(_ db: SQLiteDatabase, ids: Set<UUID>? = nil) throws -> [SharedRecord] {
        let rows = try db.query(
            "SELECT id, kind, version, s2_l16_token, created_by, created_at, fields FROM shared ORDER BY id"
        ) { row -> SharedRecord? in
            guard let id = UUID(uuidString: row.string(0)), ids?.contains(id) != false,
                let kind = EntityKind(rawValue: row.string(1)), let tile = S2CellID(token: row.string(3))
            else { return nil }
            return SharedRecord(
                kind: kind, id: id, version: row.int(2), tile: tile, createdBy: PlayerID(rawValue: row.string(4)),
                createdAt: Date(timeIntervalSince1970: Double(row.int(5)) / 1000),
                fields: try CanopyJSON.decoder.decode([String: JSONValue].self, from: Data(row.string(6).utf8)))
        }
        return rows.compactMap { $0 }
    }

    private static func upsert(_ record: SharedRecord, in db: SQLiteDatabase) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO shared (id, kind, version, s2_l16_token, created_by, created_at, fields)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(record.id.uuidString), .text(record.kind.rawValue), .int(record.version),
                .text(record.tile.token), .text(record.createdBy.rawValue),
                .integer(milliseconds(record.createdAt)), .text(try json(record.fields)),
            ])
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
                INSERT INTO trees (id, s2_l19_token, s2_l16_token, count_status, proposed_status, version, payload)
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
                INSERT INTO tags (id, tree_id, s2_l19_token, s2_l16_token, status, version, payload)
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
            INSERT INTO observations (id, created_at, player_id, s2_l19_token, version, kind, subject_id, changeset_id, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(observation.id.uuidString), .integer(milliseconds(observation.meta.createdAt)),
                .text(observation.meta.playerID.rawValue), .text(observation.meta.chunk.token),
                .int(observation.meta.version), .text(observation.kind.name),
                .text(observation.kind.subject.id.uuidString), .optional(observation.changesetID?.uuidString),
                .text(try json(observation)),
            ]
        )
    }

    private static func insert(_ changeset: Changeset, in db: SQLiteDatabase) throws {
        try db.run(
            """
            INSERT INTO changesets (id, created_at, player_id, s2_l19_token, state, s2_l16_tokens, payload, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(changeset.id.uuidString), .integer(milliseconds(changeset.meta.createdAt)),
                .text(changeset.meta.playerID.rawValue), .text(changeset.meta.chunk.token),
                .text(changeset.state.rawValue), .text(changeset.tiles.map(\.token).joined(separator: " ")),
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
        """,
        // 2: S2 columns name their level and representation (canonical tokens), following the S2 style guide
        // shared with velocity.report.
        """
        ALTER TABLE observations RENAME COLUMN cell TO s2_l19_token;
        ALTER TABLE evidence RENAME COLUMN cell TO s2_l19_token;
        ALTER TABLE changesets RENAME COLUMN cell TO s2_l19_token;
        ALTER TABLE changesets RENAME COLUMN cells TO s2_l16_tokens;
        ALTER TABLE trees RENAME COLUMN cell TO s2_l19_token;
        ALTER TABLE trees RENAME COLUMN tile TO s2_l16_token;
        ALTER TABLE tags RENAME COLUMN cell TO s2_l19_token;
        ALTER TABLE tags RENAME COLUMN tile TO s2_l16_token;
        DROP INDEX trees_tile;
        CREATE INDEX trees_s2_l16_token ON trees (s2_l16_token);
        CREATE INDEX tags_s2_l16_token ON tags (s2_l16_token);
        """,
        // 3: the shared map pulled from a Gerardus server, and how far each tile has been pulled.
        """
        CREATE TABLE shared (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            version INTEGER NOT NULL,
            s2_l16_token TEXT NOT NULL,
            created_by TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            fields TEXT NOT NULL
        );
        CREATE INDEX shared_s2_l16_token ON shared (s2_l16_token);
        CREATE TABLE shared_tiles (
            s2_l16_token TEXT PRIMARY KEY,
            sequence INTEGER NOT NULL,
            synced_at INTEGER NOT NULL
        );
        """,
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
