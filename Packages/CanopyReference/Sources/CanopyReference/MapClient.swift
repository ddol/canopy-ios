import CanopyModel
import CanopySync
import Foundation

/// A client for a Gerardus server's map service (gerardus.map.v1alpha1): the shared tree census as a changeset log.
/// Changesets reach the map when two players agree and one of them is trusted; trees found in aerial LiDAR are saved
/// directly; a tile's entities come as a snapshot and then as the ops applied since. Every call is unary and every
/// failure arrives before any message, so HTTP/1.1's invisible trailers lose nothing.
///
/// Calls carry the player's identity (`GerardusIdentity`); writes need it.
public struct GerardusMapClient: GerardusClient {
    public static let service = "/gerardus.map.v1alpha1.MapService/"
    /// The trees layer: Canopy's census, CC0, with nothing from OpenStreetMap.
    public static let layer = "trees"

    public let transport: any GRPCTransport
    /// How long a call may take.
    public var timeout: Duration

    public init(transport: any GRPCTransport, timeout: Duration = .seconds(20)) {
        self.transport = transport
        self.timeout = timeout
    }

    /// A client for the server at `baseURL`, calling as `player`.
    public init(baseURL: URL, player: Player) {
        self.init(
            transport: URLSessionGRPCTransport(baseURL: baseURL, headers: GerardusIdentity.headers(for: player)))
    }

    // MARK: GerardusClient

    public func uploadBlob(_ data: Data, ref: BlobRef) async throws {
        var request = ProtoWriter()
        request.bytes(1, data)
        request.string(2, ref.rawValue)
        request.string(3, "model/gltf-binary")
        _ = try await call("UploadBlob", request)
    }

    /// Submits a changeset to the trees layer; `author` must be the calling player. Throws
    /// `GerardusError.missingBlobs` when the server lacks blobs the ops reference (nothing is stored then).
    public func submit(_ changeset: Changeset, author: Player) async throws -> Changeset {
        var request = ProtoWriter()
        request.message(1) { MapMessages.encode(changeset, to: &$0) }
        let fields = try await call("SubmitChangeset", request)
        let missing = fields.filter { $0.number == 2 }.compactMap { BlobRef(rawValue: $0.string) }
        if !missing.isEmpty { throw GerardusError.missingBlobs(missing) }
        guard let view = fields.first(where: { $0.number == 1 }) else { throw GRPCTransportError.noResponse }
        return try MapMessages.changeset(try ProtoReader.fields(view.bytes))
    }

    public func changesets(_ ids: [UUID]) async throws -> [Changeset] {
        guard !ids.isEmpty else { return [] }
        var result: [Changeset] = []
        // The server takes at most 1000 ids a call.
        for start in stride(from: 0, to: ids.count, by: 1000) {
            var request = ProtoWriter()
            for id in ids[start..<min(ids.count, start + 1000)] { request.string(1, id.uuidString.lowercased()) }
            result += try await call("GetChangesets", request).filter { $0.number == 1 }.map {
                try MapMessages.changeset(try ProtoReader.fields($0.bytes))
            }
        }
        return result
    }

    /// Every op applied in `tile` after `sequence`, oldest first, across as many pages as it takes.
    public func pullChanges(in tile: S2CellID, since sequence: Int64) async throws -> ChangePage {
        var changes: [AppliedChange] = []
        var since = sequence
        while true {
            var request = ProtoWriter()
            request.string(1, tile.token)
            request.uint(2, UInt64(since))
            let fields = try await call("PullChanges", request)
            changes += try fields.filter { $0.number == 1 }.map {
                try MapMessages.appliedChange(try ProtoReader.fields($0.bytes))
            }
            since = Int64(fields.first { $0.number == 2 }?.uint ?? UInt64(since))
            guard fields.first(where: { $0.number == 3 })?.bool == true else { break }
        }
        return ChangePage(changes: changes, latestSequence: since)
    }

    // MARK: Players

    /// The calling player as the server sees them.
    public struct PlayerInfo: Equatable, Sendable {
        public var id: String
        public var alias: String
        public var isTrusted: Bool
        public var isAdmin: Bool
        /// Whether the align service sends OpenStreetMap to this player.
        public var isOSMAllowed: Bool
    }

    public func player() async throws -> PlayerInfo {
        let fields = try await call("GetPlayer", ProtoWriter())
        guard let player = fields.first(where: { $0.number == 1 }) else { throw GRPCTransportError.noResponse }
        var info = PlayerInfo(id: "", alias: "", isTrusted: false, isAdmin: false, isOSMAllowed: false)
        for f in try ProtoReader.fields(player.bytes) {
            switch f.number {
            case 1: info.id = f.string
            case 2: info.alias = f.string
            case 5: info.isTrusted = f.bool
            case 6: info.isAdmin = f.bool
            case 7: info.isOSMAllowed = f.bool
            default: break
            }
        }
        return info
    }

    // MARK: Reviewing

    /// Agrees with an open changeset, or (a trusted player) rejects it with a reason. Returns the server's view.
    public func review(_ id: UUID, approve: Bool, note: String = "") async throws -> Changeset {
        var request = ProtoWriter()
        request.string(1, id.uuidString.lowercased())
        request.enumValue(2, approve ? 1 : 2)
        request.string(3, note)
        let fields = try await call("ReviewChangeset", request)
        guard let view = fields.first(where: { $0.number == 1 }) else { throw GRPCTransportError.noResponse }
        return try MapMessages.changeset(try ProtoReader.fields(view.bytes))
    }

    // MARK: Blobs

    /// A blob by its SHA-256, such as the mesh behind another player's measurement. The caller checks the hash. A blob
    /// the server lacks is `GRPCStatusError.notFound`.
    public func blob(_ ref: BlobRef) async throws -> Data {
        var request = ProtoWriter()
        request.string(1, ref.rawValue)
        guard let data = try await call("GetBlob", request).first(where: { $0.number == 2 }) else {
            throw GRPCTransportError.noResponse
        }
        return Data(data.bytes)
    }

    /// An open changeset waiting for agreement, with its author as the server knows them.
    public struct OpenChangeset: Sendable {
        public var changeset: Changeset
        public var authorAlias: String
        public var authorTrusted: Bool
    }

    /// The open changesets that touch a tile, oldest first: the review queue.
    public func openChangesets(in tile: S2CellID) async throws -> [OpenChangeset] {
        var request = ProtoWriter()
        request.string(1, tile.token)
        return try await call("ListOpenChangesets", request).filter { $0.number == 1 }.map { field in
            let fields = try ProtoReader.fields(field.bytes)
            return OpenChangeset(
                changeset: try MapMessages.changeset(fields),
                authorAlias: fields.first { $0.number == 10 }?.string ?? "",
                authorTrusted: fields.first { $0.number == 11 }?.bool ?? false)
        }
    }

    // MARK: Tiles

    /// A tile's current entities and the sequence to pull from next.
    public struct TileSnapshot: Sendable {
        public struct Entity: Sendable {
            public var kind: EntityKind?
            public var id: UUID
            public var version: Int
            public var fields: [String: JSONValue]
            public var tile: S2CellID?
            public var createdBy = PlayerID(rawValue: "")
            public var createdAt = Date(timeIntervalSince1970: 0)
            /// Trees: the S2 L22 cell the tree stands in.
            public var occupancy: S2CellID?

            /// The entity as the store keeps it, or nil when it is of a kind Canopy does not know.
            public var record: SharedRecord? {
                guard let kind, let tile else { return nil }
                return SharedRecord(
                    kind: kind, id: id, version: version, tile: tile, createdBy: createdBy, createdAt: createdAt,
                    fields: fields)
            }
        }

        public var entities: [Entity]
        public var latestSequence: Int64
    }

    public func tile(_ tile: S2CellID) async throws -> TileSnapshot {
        var request = ProtoWriter()
        request.string(1, tile.token)
        let fields = try await call("GetTile", request)
        let entities = try fields.filter { $0.number == 1 }.map { field in
            var entity = TileSnapshot.Entity(kind: nil, id: UUID(), version: 0, fields: [:], occupancy: nil)
            for f in try ProtoReader.fields(field.bytes) {
                switch f.number {
                case 1: entity.kind = MapMessages.entityKind(f.int)
                case 2: entity.id = UUID(uuidString: f.string) ?? entity.id
                case 3: entity.version = f.int
                case 4: entity.fields = try MapMessages.fields(f.string)
                case 5: entity.tile = S2CellID(token: f.string)
                case 6: entity.createdBy = PlayerID(rawValue: f.string)
                case 7: entity.createdAt = MapMessages.date(try ProtoReader.fields(f.bytes))
                case 10: entity.occupancy = S2CellID(token: f.string)
                default: break
                }
            }
            return entity
        }
        return TileSnapshot(entities: entities, latestSequence: Int64(fields.first { $0.number == 2 }?.uint ?? 0))
    }

    // MARK: Detected trees

    public struct ImportResult: Equatable, Sendable {
        public var created = 0
        public var alreadyPresent = 0
        /// Skipped because another tree stands in the candidate's L22 cell.
        public var occupied = 0
        /// "<candidate id>: <why>" for candidates the server did not accept.
        public var refused: [String] = []
    }

    /// Saves trees found in aerial LiDAR to the trees layer as detected, in one changeset the server applies at once.
    /// Idempotent: candidates already saved, or in an occupied L22 cell, are skipped. The server refuses the whole
    /// request when `source` mentions OpenStreetMap or says the candidates are for checking only.
    public func importDetectedTrees(
        _ candidates: [TreeCandidate], source: String, tiles: Set<S2CellID>, detector: String
    ) async throws -> ImportResult {
        var total = ImportResult()
        // The server takes at most 20 000 a call.
        for start in stride(from: 0, to: candidates.count, by: 20_000) {
            var request = ProtoWriter()
            for candidate in candidates[start..<min(candidates.count, start + 20_000)] {
                request.message(1) { tree in
                    tree.string(1, candidate.id.uuidString.lowercased())
                    tree.double(2, candidate.location.latitude, always: true)
                    tree.double(3, candidate.location.longitude, always: true)
                    if let height = candidate.height { tree.double(4, height, always: true) }
                    if let crown = candidate.crownRadius { tree.double(5, crown, always: true) }
                    tree.double(6, candidate.confidence, always: true)
                }
            }
            request.string(2, source)
            for tile in tiles.sorted() { request.string(3, tile.token) }
            request.string(4, detector)
            for f in try await call("ImportDetectedTrees", request) {
                switch f.number {
                case 2: total.created += f.int
                case 3: total.alreadyPresent += f.int
                case 4: total.occupied += f.int
                case 5: total.refused.append(f.string)
                default: break
                }
            }
        }
        return total
    }

    // MARK: Plumbing

    func call(_ method: String, _ request: ProtoWriter) async throws -> [ProtoField] {
        try await transport.unaryFields(Self.service + method, request.data, limit: timeout)
    }
}

/// The map service's messages, to and from CanopyModel's types. Op fields travel as CanopyModel's own JSON.
enum MapMessages {
    static let ops: [ChangeOp.Kind: Int] = [.create: 1, .update: 2, .delete: 3]
    static let entities: [EntityKind: Int] = [.tree: 1, .tag: 2, .route: 3]
    static let states: [Changeset.State: Int] = [
        .pending: 1, .approved: 2, .applied: 3, .rejected: 4, .conflicted: 5,
    ]

    static func entityKind(_ value: Int) -> EntityKind? {
        entities.first { $0.value == value }?.key
    }

    static func encode(_ changeset: Changeset, to w: inout ProtoWriter) {
        w.string(1, changeset.id.uuidString.lowercased())
        w.string(2, changeset.meta.playerID.rawValue)
        w.message(3) { timestamp(&$0, changeset.meta.createdAt) }
        w.string(4, changeset.meta.chunk.token)
        for tile in changeset.tiles { w.string(5, tile.token) }
        for op in changeset.ops {
            w.message(6) { encode(op, to: &$0) }
        }
        w.string(9, GerardusMapClient.layer)
    }

    static func encode(_ op: ChangeOp, to w: inout ProtoWriter) {
        w.enumValue(1, ops[op.op] ?? 0)
        w.enumValue(2, entities[op.entity] ?? 0)
        w.string(3, op.id.uuidString.lowercased())
        w.uint(4, UInt64(max(0, op.baseVersion)))
        let json = (try? CanopyJSON.encoder.encode(op.fields)).map { String(decoding: $0, as: UTF8.self) }
        w.string(5, json ?? "{}")
    }

    static func timestamp(_ w: inout ProtoWriter, _ date: Date) {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = milliseconds.quotientAndRemainder(dividingBy: 1000)
        let (whole, rest) = seconds.remainder < 0 ? (seconds.quotient - 1, seconds.remainder + 1000) : seconds
        w.uint(1, UInt64(bitPattern: whole))
        w.uint(2, UInt64(rest * 1_000_000))
    }

    static func date(_ fields: [ProtoField]) -> Date {
        var seconds: Int64 = 0
        var nanos: Int64 = 0
        for f in fields {
            if f.number == 1 { seconds = Int64(bitPattern: f.uint) }
            if f.number == 2 { nanos = Int64(Int32(truncatingIfNeeded: f.uint)) }
        }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9)
    }

    static func fields(_ json: String) throws -> [String: JSONValue] {
        guard !json.isEmpty else { return [:] }
        return try CanopyJSON.decoder.decode([String: JSONValue].self, from: Data(json.utf8))
    }

    static func op(_ fields: [ProtoField]) throws -> ChangeOp {
        var op = ChangeOp(op: .update, entity: .tree, id: UUID(), baseVersion: 0, fields: [:])
        for f in fields {
            switch f.number {
            case 1: op.op = ops.first { $0.value == f.int }?.key ?? op.op
            case 2: op.entity = entityKind(f.int) ?? op.entity
            case 3: op.id = UUID(uuidString: f.string) ?? op.id
            case 4: op.baseVersion = f.int
            case 5: op.fields = try Self.fields(f.string)
            default: break
            }
        }
        return op
    }

    static func changeset(_ fields: [ProtoField]) throws -> Changeset {
        var id = UUID()
        var author = PlayerID(rawValue: "")
        var created = Date(timeIntervalSince1970: 0)
        var chunk: S2CellID?
        var tiles: [S2CellID] = []
        var ops: [ChangeOp] = []
        var state = Changeset.State.pending
        var approvals: [Changeset.Approval] = []
        for f in fields {
            switch f.number {
            case 1: id = UUID(uuidString: f.string) ?? id
            case 2: author = PlayerID(rawValue: f.string)
            case 3: created = date(try ProtoReader.fields(f.bytes))
            case 4: chunk = S2CellID(token: f.string)
            case 5: if let tile = S2CellID(token: f.string) { tiles.append(tile) }
            case 6: ops.append(try op(try ProtoReader.fields(f.bytes)))
            case 7: state = states.first { $0.value == f.int }?.key ?? state
            case 8:
                var player = PlayerID(rawValue: "")
                var trusted = false
                var at = Date(timeIntervalSince1970: 0)
                for g in try ProtoReader.fields(f.bytes) {
                    switch g.number {
                    case 1: player = PlayerID(rawValue: g.string)
                    case 2: trusted = g.bool
                    case 3: at = date(try ProtoReader.fields(g.bytes))
                    default: break
                    }
                }
                approvals.append(Changeset.Approval(playerID: player, isTrusted: trusted, at: at))
            default: break
            }
        }
        let firstTile = tiles.first ?? S2CellID(GeoPoint(latitude: 0, longitude: 0)).tile
        return Changeset(
            meta: RecordMeta(id: id, createdAt: created, playerID: author, chunk: chunk ?? firstTile),
            ops: ops, tiles: tiles.sorted(), state: state, approvals: approvals)
    }

    static func appliedChange(_ fields: [ProtoField]) throws -> AppliedChange {
        var change = AppliedChange(
            sequence: 0, changesetID: UUID(), tile: S2CellID(GeoPoint(latitude: 0, longitude: 0)).tile,
            op: ChangeOp(op: .update, entity: .tree, id: UUID(), baseVersion: 0, fields: [:]),
            appliedAt: Date(timeIntervalSince1970: 0))
        for f in fields {
            switch f.number {
            case 1: change.sequence = Int64(bitPattern: f.uint)
            case 2: change.changesetID = UUID(uuidString: f.string) ?? change.changesetID
            case 3: change.tile = S2CellID(token: f.string) ?? change.tile
            case 4: change.op = try op(try ProtoReader.fields(f.bytes))
            case 5: change.appliedAt = date(try ProtoReader.fields(f.bytes))
            case 7: change.author = PlayerID(rawValue: f.string)
            default: break
            }
        }
        return change
    }
}
