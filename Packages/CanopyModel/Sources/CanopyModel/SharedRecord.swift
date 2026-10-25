import Foundation

/// A tree or tag as the shared map has it: a Gerardus server's trees layer, pulled to this device. Its fields are
/// the entity's shared fields (as in a changeset op); the record metadata comes from the server.
public struct SharedRecord: Hashable, Sendable {
    public var kind: EntityKind
    public var id: UUID
    /// Goes up by one with every op applied to the entity on the shared map.
    public var version: Int
    public var tile: S2CellID
    public var createdBy: PlayerID
    public var createdAt: Date
    public var fields: [String: JSONValue]

    public init(
        kind: EntityKind, id: UUID, version: Int, tile: S2CellID, createdBy: PlayerID, createdAt: Date,
        fields: [String: JSONValue]
    ) {
        self.kind = kind
        self.id = id
        self.version = version
        self.tile = tile
        self.createdBy = createdBy
        self.createdAt = createdAt.roundedToMilliseconds
        self.fields = fields
    }

    /// The record after an op applied on the shared map: an update changes only the fields it names (null removes
    /// one) and moves the version on by one.
    public func applying(_ op: ChangeOp, tile: S2CellID) -> SharedRecord {
        var next = self
        for (key, value) in op.fields {
            next.fields[key] = value == .null ? nil : value
        }
        next.version += 1
        next.tile = tile
        return next
    }

    /// The record as a tree, or nil when it is not one or its fields do not make one.
    public func tree() -> Tree? {
        guard kind == .tree else { return nil }
        return try? decode(Tree.self)
    }

    /// The record as a tag, or nil when it is not one or its fields do not make one.
    public func tag() -> Tag? {
        guard kind == .tag else { return nil }
        return try? decode(Tag.self)
    }

    private func decode<Entity: Decodable>(_ type: Entity.Type) throws -> Entity {
        guard let token = fields["s2_l19_token"]?.stringValue else { throw DecodingError.missingChunk }
        var object = fields
        object["s2_l19_token"] = nil
        object["meta"] = .object([
            "id": .string(id.uuidString),
            "createdAt": .number((createdAt.timeIntervalSince1970 * 1000).rounded()),
            "playerID": .string(createdBy.rawValue),
            "s2_l19_token": .string(token),
            "version": .number(Double(version)),
        ])
        let data = try CanopyJSON.encoder.encode(JSONValue.object(object))
        return try CanopyJSON.decoder.decode(type, from: data)
    }

    enum DecodingError: Error {
        case missingChunk
    }
}

/// An op applied on the shared map, as a pull brings it.
public struct SharedChange: Hashable, Sendable {
    public var op: ChangeOp
    /// The tile the entity is in after the op (before it, for a delete).
    public var tile: S2CellID
    public var author: PlayerID
    public var appliedAt: Date

    public init(op: ChangeOp, tile: S2CellID, author: PlayerID, appliedAt: Date) {
        self.op = op
        self.tile = tile
        self.author = author
        self.appliedAt = appliedAt
    }
}
