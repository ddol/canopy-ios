import CanopyModel
import Foundation

public enum LocalStoreError: Error, Equatable {
    /// The observation is about a tree or tag the store does not have.
    case unknownSubject(UUID)
    case unknownChangeset(UUID)
}

/// The app's local data: an append-only observation log, the changesets that share it, immutable evidence (one
/// record per scan, by hash), the aerial base layer, the shared map pulled from a Gerardus server, and current-state
/// tables derived from all of those.
///
/// Every write re-derives the current state (`CensusState.derive`) and brings the `trees` and `tags` tables up to
/// date in the same transaction, so the tables always match the log. Opening a store re-derives too, and rewrites
/// those tables only when the schema or the derivation has changed since they were written (`Schema.derived`).
///
/// Opening a store only opens the database: reading what derivation needs and deriving waits for `prepare()`, or for
/// the first call that needs the census, and runs on the store's own executor. With a city's worth of shared trees that
/// takes seconds, which an app opening its store at launch would otherwise spend on the main thread before its first
/// frame.
///
/// What derivation reads (the candidates, the shared map, the log and the changesets' states) is kept in memory as it
/// is in the database, so a write decodes only what it adds, and only the rows of trees and tags that changed are
/// written: a player's tap costs much the same with thirty thousand trees in the park as with two hundred.
public actor LocalStore {
    public nonisolated let blobs: BlobStore
    private let databasePath: String
    private var db: SQLiteDatabase
    /// The inputs and the census derived from them, once `prepare` has read them.
    private var derived: (inputs: Inputs, current: CensusState)?
    /// `candidates()` and `changesets()` as last read, until a write changes them.
    private var sortedCandidates: [TreeCandidate]?
    private var decodedChangesets: [Changeset]?

    /// The inputs to derivation, as they are in the database.
    struct Inputs {
        var candidates: [UUID: TreeCandidate] = [:]
        /// The candidates as detected trees, made once each.
        var base: [UUID: Tree] = [:]
        var shared: [SharedRecord] = []
        /// Oldest first.
        var observations: [FieldObservation] = []
        var changesetStates: [UUID: Changeset.State] = [:]

        mutating func setCandidates(_ candidates: [UUID: TreeCandidate]) {
            var base: [UUID: Tree] = [:]
            base.reserveCapacity(candidates.count)
            for (id, candidate) in candidates {
                if let kept = self.base[id], self.candidates[id] == candidate {
                    base[id] = kept
                } else {
                    base[id] = candidate.makeTree()
                }
            }
            self.candidates = candidates
            self.base = base
        }
    }

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
    }

    /// Reads what derivation needs and derives the census, once; later calls return at once. Any call that needs the
    /// census does this first, so calling it is only to have it done, and its errors thrown, when the caller chooses:
    /// an app opening its store at launch, say, draws its first frame and then prepares the store.
    public func prepare() throws {
        guard derived == nil else { return }
        let inputs = try Self.readInputs(db)
        let current = Self.derive(inputs)
        // Every write keeps the tables in step, so they need writing again only when what writes them has changed:
        // with a park's worth of trees that is seconds.
        if try Self.derivedStamp(db) != Schema.derived {
            try db.transaction {
                try Self.materialize(current, replacing: nil, in: db)
                try Self.stampDerived(db)
            }
        }
        derived = (inputs, current)
    }

    /// The census, prepared first if need be. A store whose database cannot be read has an empty one; `prepare` says
    /// why.
    private var current: CensusState {
        get { prepared().current }
        set { derived = (prepared().inputs, newValue) }
    }

    /// What the census is derived from, read first if need be.
    private var inputs: Inputs {
        get { prepared().inputs }
        set { derived = (newValue, prepared().current) }
    }

    private func prepared() -> (inputs: Inputs, current: CensusState) {
        if derived == nil { try? prepare() }
        return derived ?? (Inputs(), CensusState())
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
        let all =
            try decodedChangesets
            ?? db.query("SELECT payload FROM changesets ORDER BY created_at, rowid") { row in
                try CanopyJSON.decoder.decode(Changeset.self, from: Data(row.string(0).utf8))
            }
        decodedChangesets = all
        return states.map { states in all.filter { states.contains($0.state) } } ?? all
    }

    /// Every evidence record on this device (this device's scans), newest first: one per scan.
    public func allEvidence() throws -> [Evidence] {
        try db.query("SELECT payload FROM evidence ORDER BY created_at DESC, rowid DESC") { row in
            try CanopyJSON.decoder.decode(Evidence.self, from: Data(row.string(0).utf8))
        }
    }

    public func evidence(about subjectID: UUID) throws -> [Evidence] {
        try db.query(
            "SELECT payload FROM evidence WHERE subject_id = ? ORDER BY created_at, rowid",
            [.text(subjectID.uuidString)]
        ) { row in
            try CanopyJSON.decoder.decode(Evidence.self, from: Data(row.string(0).utf8))
        }
    }

    /// The record of the scan with this hash (the SHA-256 of its GLB bytes), if this device has one.
    public func evidence(hash: BlobRef) throws -> Evidence? {
        try db.query("SELECT payload FROM evidence WHERE blob = ?", [.text(hash.rawValue)]) { row in
            try CanopyJSON.decoder.decode(Evidence.self, from: Data(row.string(0).utf8))
        }.first
    }

    /// The aerial base layer, by id.
    public func candidates() throws -> [TreeCandidate] {
        if let sortedCandidates { return sortedCandidates }
        let sorted = inputs.candidates.values.sorted { $0.id.uuidString < $1.id.uuidString }
        sortedCandidates = sorted
        return sorted
    }

    public func candidateCount() throws -> Int {
        inputs.candidates.count
    }

    /// Where each candidate came from, for those that say (`TreeCandidate.source`).
    public func candidateSources() -> [UUID: String] {
        inputs.candidates.compactMapValues(\.source)
    }

    /// How many evidence records this device has.
    public func evidenceCount() throws -> Int {
        try db.query("SELECT count(*) FROM evidence") { $0.int(0) }.first ?? 0
    }

    // MARK: Writing

    /// What replacing an area's candidates did.
    public struct CandidateReplacement: Equatable, Sendable {
        /// Candidates in the area that were replaced: all of them but those a player has observed.
        public var replaced: Int
        /// Candidates there now that were not there before.
        public var added: Int
        /// Candidates there before that are not there now, and how many of those were the made-up sample.
        public var gone: Int
        public var samplesGone: Int

        public init(replaced: Int, added: Int, gone: Int, samplesGone: Int) {
            self.replaced = replaced
            self.added = added
            self.gone = gone
            self.samplesGone = samplesGone
        }
    }

    /// Replaces the candidates in an area (where `covers` is true) with new ones, such as the aerial trees found there,
    /// keeping every candidate elsewhere. A candidate in the area that a player has already observed stays, so their
    /// work is not orphaned, and a replacement within `duplicateRadius` metres of one it keeps is dropped as the same
    /// tree. Loading the same area again replaces its candidates with the same ones: nothing is added or gone.
    @discardableResult
    public func replaceCandidates(
        where covers: @Sendable (GeoPoint) -> Bool, with replacements: [TreeCandidate],
        duplicateRadius: Double = 2.5
    ) throws -> CandidateReplacement {
        let current = inputs.candidates.values
        let observed = Set(inputs.observations.map(\.kind.subject.id))
        let kept = current.filter { !covers($0.location) || observed.contains($0.id) }
        let keptInArea = kept.filter { covers($0.location) }
        let keptIDs = Set(kept.map(\.id))
        let added = replacements.filter { replacement in
            guard !keptIDs.contains(replacement.id) else { return false }
            let frame = LocalFrame(origin: replacement.location)
            return !keptInArea.contains { frame.enu(of: $0.location).horizontalDistance < duplicateRadius }
        }
        let before = inputs.candidates
        try importCandidates(kept + added)
        let after = inputs.candidates
        let gone = before.values.filter { after[$0.id] == nil }
        return CandidateReplacement(
            replaced: current.count - kept.count, added: after.keys.filter { before[$0] == nil }.count,
            gone: gone.count, samplesGone: gone.filter(\.isSynthetic).count)
    }

    /// Replaces the aerial base layer. Only the rows that change are written.
    public func importCandidates(_ candidates: [TreeCandidate]) throws {
        var next: [UUID: TreeCandidate] = [:]
        next.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard next.updateValue(candidate, forKey: candidate.id) == nil else {
                throw SQLiteError(code: 19, message: "UNIQUE constraint failed: candidates.id")
            }
        }
        let previous = inputs.candidates
        try write {
            for id in previous.keys where next[id] == nil {
                try db.run("DELETE FROM candidates WHERE id = ?", [.text(id.uuidString)])
            }
            for (id, candidate) in next where previous[id] != candidate {
                try db.run(
                    "INSERT OR REPLACE INTO candidates (id, payload) VALUES (?, ?)",
                    [.text(id.uuidString), .text(try Self.json(candidate))]
                )
            }
        } update: { inputs in
            inputs.setCandidates(next)
        }
        sortedCandidates = nil
    }

    /// Records an observation and the changeset that shares it, in one transaction.
    ///
    /// Recording a scan (`FieldObservation.Kind.scan`) that an observation in the log already records adds nothing
    /// while that observation stands (its changeset is open or applied): it and its changeset are returned instead, so
    /// saving one scan twice is one measurement. A scan whose changeset was rejected or conflicted can be recorded again.
    @discardableResult
    public func record(
        _ kind: FieldObservation.Kind, by player: PlayerID, at date: Date = .now
    ) throws
        -> (observation: FieldObservation, changeset: Changeset)
    {
        if let scan = kind.scan, let recorded = try recorded(scan) {
            return recorded
        }
        let subject = kind.subject
        let chunk: S2CellID
        switch kind {
        case .treeAdded(let tree):
            chunk = tree.position.chunk
        case .tagPlaced(let tag):
            chunk = tag.point.position.chunk
        case .treeConfirmed(let id), .treeRejected(let id), .trunkMeasured(let id, _, _, _), .treeMoved(let id, _):
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
        } update: { inputs in
            inputs.observations.append(observation)
            inputs.changesetStates[changeset.id] = changeset.state
        }
        decodedChangesets = nil
        return (observation, changeset)
    }

    /// Stores a scan: its mesh and its evidence record. The data must hash to `evidence.blob`.
    ///
    /// A scan is identified by its hash, so saving or importing one this device already has adds no record: the one
    /// already stored is returned, and callers link to it (its `subjectID` is the tree or tag the scan is about).
    /// Otherwise the new record is returned.
    @discardableResult
    public func addEvidence(_ evidence: Evidence, data: Data) throws -> Evidence {
        try blobs.put(data, expecting: evidence.blob)
        if let stored = try self.evidence(hash: evidence.blob) { return stored }
        try Self.insert(evidence, in: db)
        return evidence
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

    // MARK: Surveyed cells

    /// The level-16 cells marked as surveyed on this device.
    public func surveyedCells() throws -> [SurveyedCell] {
        try db.query("SELECT payload FROM surveyed_cells") { row in
            try CanopyJSON.decoder.decode(SurveyedCell.self, from: Data(row.string(0).utf8))
        }
    }

    /// Marks a cell as surveyed, replacing an earlier mark.
    public func setSurveyed(_ cell: SurveyedCell) throws {
        try db.run(
            "INSERT OR REPLACE INTO surveyed_cells (s2_l16_token, payload) VALUES (?, ?)",
            [.text(cell.cell.token), .text(try Self.json(cell))])
    }

    /// Takes a cell's mark away.
    public func clearSurveyed(_ cell: S2CellID) throws {
        try db.run("DELETE FROM surveyed_cells WHERE s2_l16_token = ?", [.text(cell.token)])
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
        } update: { inputs in
            inputs.shared = try Self.sharedRecords(db)
        }
        return stale
    }

    /// Forgets what was pulled for some tiles, their records and their cursors, in one transaction, and re-derives: a
    /// later pull starts each again with a snapshot. This device's own observations stay in the log and are folded again
    /// for anything the shared map no longer holds. For a phone that holds more of the shared map than it follows (an
    /// earlier version pulled every tile in the city).
    ///
    /// A tile holding a shared tree or tag this device observed (confirmed, measured, moved, rejected or tagged, under
    /// any player id) is kept: the record is the only copy of that tree here, and forgetting it would take the tree and
    /// the work on it off the census. Deciding that here, in the same step as the forgetting, also covers an observation
    /// recorded after the caller chose the tiles. Returns the tiles forgotten.
    @discardableResult
    public func forgetShared(_ tiles: Set<S2CellID>) throws -> Set<S2CellID> {
        guard !tiles.isEmpty else { return [] }
        try prepare()
        var observed: Set<UUID> = []
        for observation in inputs.observations {
            observed.insert(observation.kind.subject.id)
            if case .tagPlaced(let tag) = observation.kind { observed.insert(tag.treeID) }
        }
        let worked = Set(inputs.shared.lazy.filter { observed.contains($0.id) }.map(\.tile))
        let forgotten = tiles.subtracting(worked)
        guard !forgotten.isEmpty else { return [] }
        try write {
            for tile in forgotten {
                try db.run("DELETE FROM shared WHERE s2_l16_token = ?", [.text(tile.token)])
                try db.run("DELETE FROM shared_tiles WHERE s2_l16_token = ?", [.text(tile.token)])
            }
        } update: { inputs in
            inputs.shared.removeAll { forgotten.contains($0.tile) }
        }
        return forgotten
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
        } update: { inputs in
            inputs.changesetStates[changeset.id] = changeset.state
        }
        decodedChangesets = nil
    }

    /// Re-derives the current state from the database alone, and rewrites the current-state tables.
    @discardableResult
    public func rebuild() throws -> CensusState {
        let (inputs, state) = try db.transaction {
            let inputs = try Self.readInputs(db)
            let state = Self.derive(inputs)
            try Self.materialize(state, replacing: nil, in: db)
            try Self.stampDerived(db)
            return (inputs, state)
        }
        derived = (inputs, state)
        sortedCandidates = nil
        decodedChangesets = nil
        return state
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
        derived = (Inputs(), CensusState())
        sortedCandidates = nil
        decodedChangesets = nil
        try Self.materialize(CensusState(), replacing: nil, in: db)
        try Self.stampDerived(db)
    }

    // MARK: Internals

    /// The underlying connection, for tests that need raw SQL.
    var databaseForTesting: SQLiteDatabase { db }

    /// Runs `body`, brings the inputs up to date with what it wrote (`update`), re-derives, and writes the trees and
    /// tags that changed, in one transaction. The inputs and state change only once it commits.
    private func write(_ body: () throws -> Void, update: (inout Inputs) throws -> Void) throws {
        try prepare()
        var inputs = self.inputs
        let previous = current
        let db = db
        let next = try db.transaction {
            try body()
            try update(&inputs)
            let next = Self.derive(inputs)
            try Self.materialize(next, replacing: previous, in: db)
            return next
        }
        derived = (inputs, next)
    }

    /// The first observation in the log that records `scan` and still stands (its changeset is open or applied), with
    /// its changeset.
    private func recorded(_ scan: BlobRef) throws -> (observation: FieldObservation, changeset: Changeset)? {
        for observation in inputs.observations where observation.kind.scan == scan {
            guard let id = observation.changesetID, let state = inputs.changesetStates[id],
                state.isOpen || state == .applied,
                let changeset = try changesets().first(where: { $0.id == id })
            else { continue }
            return (observation, changeset)
        }
        return nil
    }

    /// What wrote the `trees` and `tags` tables last, or nil before any stamp.
    static func derivedStamp(_ db: SQLiteDatabase) throws -> String? {
        try db.query("SELECT value FROM store_meta WHERE key = 'derived'") { $0.string(0) }.first
    }

    private static func stampDerived(_ db: SQLiteDatabase) throws {
        try db.run("INSERT OR REPLACE INTO store_meta (key, value) VALUES ('derived', ?)", [.text(Schema.derived)])
    }

    private static func readInputs(_ db: SQLiteDatabase) throws -> Inputs {
        var inputs = Inputs()
        let candidates = try db.query("SELECT payload FROM candidates") { row in
            try CanopyJSON.decoder.decode(TreeCandidate.self, from: Data(row.string(0).utf8))
        }
        inputs.setCandidates(Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
        let states = try db.query("SELECT id, state FROM changesets") { row in
            (UUID(uuidString: row.string(0)), Changeset.State(rawValue: row.string(1)))
        }
        for case (let id?, let state?) in states {
            inputs.changesetStates[id] = state
        }
        inputs.shared = try sharedRecords(db)
        inputs.observations = try observations(db)
        return inputs
    }

    private static func derive(_ inputs: Inputs) -> CensusState {
        CensusState.derive(
            base: Array(inputs.base.values), shared: inputs.shared, observations: inputs.observations,
            changesetStates: inputs.changesetStates)
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

    /// Writes the trees and tags of `state`: those that differ from `previous`, or all of them.
    private static func materialize(
        _ state: CensusState, replacing previous: CensusState?, in db: SQLiteDatabase
    ) throws {
        let trees: [Tree]
        let tags: [Tag]
        if let previous {
            for id in previous.trees.keys where state.trees[id] == nil {
                try db.run("DELETE FROM trees WHERE id = ?", [.text(id.uuidString)])
            }
            for id in previous.tags.keys where state.tags[id] == nil {
                try db.run("DELETE FROM tags WHERE id = ?", [.text(id.uuidString)])
            }
            trees = state.trees.values.filter { previous.trees[$0.id] != $0 }
            tags = state.tags.values.filter { previous.tags[$0.id] != $0 }
        } else {
            try db.run("DELETE FROM trees")
            try db.run("DELETE FROM tags")
            trees = Array(state.trees.values)
            tags = Array(state.tags.values)
        }
        for tree in trees {
            try db.run(
                """
                INSERT OR REPLACE INTO trees (id, s2_l19_token, s2_l16_token, count_status, proposed_status, version, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(tree.id.uuidString), .text(tree.position.chunk.token), .text(tree.position.tile.token),
                    .text(tree.countStatus.rawValue), .optional(tree.proposedStatus?.rawValue), .int(tree.meta.version),
                    .text(try json(tree)),
                ]
            )
        }
        for tag in tags {
            try db.run(
                """
                INSERT OR REPLACE INTO tags (id, tree_id, s2_l19_token, s2_l16_token, status, version, payload)
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

    static func insert(_ observation: FieldObservation, in db: SQLiteDatabase) throws {
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

    static func insert(_ evidence: Evidence, in db: SQLiteDatabase) throws {
        try db.run(
            """
            INSERT INTO evidence (id, created_at, player_id, s2_l19_token, blob, subject_id, kind, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(evidence.id.uuidString), .integer(milliseconds(evidence.meta.createdAt)),
                .text(evidence.meta.playerID.rawValue), .text(evidence.meta.chunk.token), .text(evidence.blob.rawValue),
                .text(evidence.subjectID.uuidString), .text(evidence.kind.rawValue), .text(try json(evidence)),
            ]
        )
    }

    static func insert(_ changeset: Changeset, in db: SQLiteDatabase) throws {
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
        // 4: what wrote the derived tables, so opening a store rewrites them only when that changes.
        """
        CREATE TABLE store_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """,
        // 5: the level-16 cells the player has marked as surveyed. On the device only, until the server has a
        // record for them.
        """
        CREATE TABLE surveyed_cells (
            s2_l16_token TEXT PRIMARY KEY,
            payload TEXT NOT NULL
        );
        """,
        // 6: one evidence record per scan. A scan is identified by its hash, the SHA-256 of its GLB bytes (`blob`), so
        // records with the same blob are one scan saved more than once (Save tapped twice): the first record is kept,
        // the others go, and no second record can be added. Observations, trees, tags and changesets name scans by
        // hash, so they all still point at the one kept. The observations themselves are append-only and stay.
        // Numbering each scan's records in one pass keeps this quick with thousands of scans: it runs at launch, on
        // the main thread, and a query comparing every record with every other took seconds there.
        """
        DROP TRIGGER evidence_no_delete;
        DELETE FROM evidence WHERE rowid IN (
            SELECT duplicate FROM (
                SELECT rowid AS duplicate,
                    row_number() OVER (PARTITION BY blob ORDER BY created_at, rowid) AS position
                FROM evidence
            )
            WHERE position > 1
        );
        CREATE TRIGGER evidence_no_delete BEFORE DELETE ON evidence
            BEGIN SELECT RAISE(ABORT, 'evidence is immutable'); END;
        CREATE UNIQUE INDEX evidence_blob ON evidence (blob);
        """,
    ]

    /// Bump when `CensusState.derive` or `LocalStore.materialize` changes what the `trees` and `tags` tables hold:
    /// every store then rewrites them once, when it is next opened.
    static let derivation = 1

    /// The stamp of the tables as this version writes them.
    static var derived: String { "schema \(migrations.count), derivation \(derivation)" }

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
