import Foundation

public enum EntityKind: String, Codable, Sendable, CaseIterable {
    case tree
    case tag
    case route
}

/// One operation in a changeset.
public struct ChangeOp: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case create
        case update
        case delete
    }

    public var op: Kind
    public var entity: EntityKind
    public var id: UUID
    /// The entity version the change was made against; 0 for `create`. The server rejects the op as
    /// conflicted if the entity has moved on.
    public var baseVersion: Int
    /// For `create`, every shared field; for `update`, only the fields that change; empty for `delete`.
    public var fields: [String: JSONValue]

    public init(op: Kind, entity: EntityKind, id: UUID, baseVersion: Int, fields: [String: JSONValue]) {
        self.op = op
        self.entity = entity
        self.id = id
        self.baseVersion = baseVersion
        self.fields = fields
    }
}

/// A proposed change to the shared map. It reaches the map only when two players agree and at least one of
/// them is trusted.
public struct Changeset: Identifiable, Hashable, Codable, Sendable {
    public enum State: String, Codable, Sendable, CaseIterable {
        /// Waiting for agreement (or not yet sent).
        case pending
        /// Agreed by the policy; not yet applied to the shared map.
        case approved
        /// On the shared map.
        case applied
        case rejected
        /// A base version did not match; the player needs to look again.
        case conflicted

        /// Whether the changeset can still reach the shared map.
        public var isOpen: Bool { self == .pending || self == .approved }
    }

    public struct Approval: Hashable, Codable, Sendable {
        public var playerID: PlayerID
        public var isTrusted: Bool
        public var at: Date

        public init(playerID: PlayerID, isTrusted: Bool, at: Date) {
            self.playerID = playerID
            self.isTrusted = isTrusted
            self.at = at.roundedToMilliseconds
        }
    }

    /// `meta.id` is the client-generated changeset id; `meta.chunk` is the L19 chunk of the first op.
    public var meta: RecordMeta
    public var ops: [ChangeOp]
    /// The L16 tiles the changeset touches, sorted. Serialised as canonical tokens under `s2_l16_tokens`.
    public var tiles: [S2CellID]
    public var state: State
    public var approvals: [Approval]

    public init(
        meta: RecordMeta, ops: [ChangeOp], tiles: [S2CellID], state: State = .pending, approvals: [Approval] = []
    ) {
        self.meta = meta
        self.ops = ops
        self.tiles = tiles
        self.state = state
        self.approvals = approvals
    }

    private enum CodingKeys: String, CodingKey {
        case meta
        case ops
        case tiles = "s2_l16_tokens"
        case state
        case approvals
        /// Before the S2 field names named their level (schema v1).
        case legacyCells = "cells"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decode(RecordMeta.self, forKey: .meta)
        ops = try container.decode([ChangeOp].self, forKey: .ops)
        tiles =
            try container.decodeIfPresent([S2CellID].self, forKey: .tiles)
            ?? container.decode([S2CellID].self, forKey: .legacyCells)
        state = try container.decode(State.self, forKey: .state)
        approvals = try container.decode([Approval].self, forKey: .approvals)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meta, forKey: .meta)
        try container.encode(ops, forKey: .ops)
        try container.encode(tiles, forKey: .tiles)
        try container.encode(state, forKey: .state)
        try container.encode(approvals, forKey: .approvals)
    }

    public var id: UUID { meta.id }

    /// The Gerardus policy: at least two distinct players agree, and at least one of them is trusted. The
    /// author's own submission counts as agreement.
    public static func meetsPolicy(author: Player, approvals: [Approval]) -> Bool {
        var players: [PlayerID: Bool] = [author.id: author.isTrusted]
        for approval in approvals {
            players[approval.playerID] = (players[approval.playerID] ?? false) || approval.isTrusted
        }
        return players.count >= 2 && players.values.contains(true)
    }
}
