import Foundation

public enum ChangesetBuilderError: Error, Equatable {
    /// The builder has no operations.
    case empty
    /// The observation is about a tree or tag that is not in the state.
    case unknownSubject(UUID)
    /// The observation would not change anything (for example confirming a tree that is already confirmed).
    case noChange(UUID)
}

/// Turns observations into a changeset.
///
/// For each observation the builder applies it to a copy of the current state and diffs the entity's
/// shared fields before and after: a new entity becomes a `create` op with all its fields, an existing one
/// an `update` op with only the fields that changed, made against the entity's current version. Several
/// observations about one entity in one changeset become chained ops (each op's `baseVersion` is the
/// previous op's result).
public struct ChangesetBuilder: Sendable {
    public let id: UUID
    public let author: PlayerID
    public let createdAt: Date

    public private(set) var ops: [ChangeOp] = []
    private var state: CensusState
    private var tiles: Set<S2CellID> = []
    private var firstChunk: S2CellID?

    public init(id: UUID = UUID(), author: PlayerID, createdAt: Date = .now, state: CensusState) {
        self.id = id
        self.author = author
        self.createdAt = createdAt
        self.state = state
    }

    /// Adds the ops for one observation and advances the builder's copy of the state.
    public mutating func add(_ observation: FieldObservation) throws {
        let next = state.applying(observation)
        let subject = observation.kind.subject
        let op: ChangeOp
        let position: Position
        switch subject.entity {
        case .tree:
            guard let after = next.trees[subject.id] else { throw ChangesetBuilderError.unknownSubject(subject.id) }
            op = try Self.op(entity: .tree, id: subject.id, before: state.trees[subject.id], after: after)
            position = after.position
        case .tag:
            guard let after = next.tags[subject.id] else { throw ChangesetBuilderError.unknownSubject(subject.id) }
            op = try Self.op(entity: .tag, id: subject.id, before: state.tags[subject.id], after: after)
            position = after.point.position
        case .route:
            throw ChangesetBuilderError.unknownSubject(subject.id)
        }
        ops.append(op)
        tiles.insert(position.tile)
        if firstChunk == nil {
            firstChunk = position.chunk
        }
        state = next
    }

    public func build() throws -> Changeset {
        guard !ops.isEmpty, let firstChunk else { throw ChangesetBuilderError.empty }
        return Changeset(
            meta: RecordMeta(id: id, createdAt: createdAt, playerID: author, cell: firstChunk),
            ops: ops,
            cells: tiles.sorted(),
            state: .pending
        )
    }

    /// Builds a changeset for a single observation.
    public static func changeset(
        for observation: FieldObservation,
        in state: CensusState,
        author: PlayerID
    ) throws -> Changeset {
        var builder = ChangesetBuilder(
            id: observation.changesetID ?? UUID(),
            author: author,
            createdAt: observation.meta.createdAt,
            state: state
        )
        try builder.add(observation)
        return try builder.build()
    }

    private static func op<Entity: SharedEntity>(
        entity: EntityKind,
        id: UUID,
        before: Entity?,
        after: Entity
    ) throws -> ChangeOp {
        let afterFields = try after.sharedFields()
        guard let before else {
            return ChangeOp(op: .create, entity: entity, id: id, baseVersion: 0, fields: afterFields)
        }
        let beforeFields = try before.sharedFields()
        var changed: [String: JSONValue] = [:]
        for key in Set(beforeFields.keys).union(afterFields.keys) where beforeFields[key] != afterFields[key] {
            changed[key] = afterFields[key] ?? .null
        }
        guard !changed.isEmpty else { throw ChangesetBuilderError.noChange(id) }
        return ChangeOp(op: .update, entity: entity, id: id, baseVersion: before.meta.version, fields: changed)
    }
}

/// An entity whose fields can be shared in a changeset.
protocol SharedEntity: Encodable {
    var meta: RecordMeta { get }
    /// Keys that never leave the device.
    static var localOnlyKeys: Set<String> { get }
}

extension SharedEntity {
    /// The entity's fields as JSON, without the record metadata (which the changeset carries) and without
    /// local-only fields, plus the chunk it is in as `cell`.
    func sharedFields() throws -> [String: JSONValue] {
        guard var object = try JSONValue(encoding: self).objectValue else { return [:] }
        object["meta"] = nil
        for key in Self.localOnlyKeys {
            object[key] = nil
        }
        object["cell"] = .string(meta.cell.token)
        return object
    }
}

extension Tree: SharedEntity {
    static var localOnlyKeys: Set<String> { ["proposedStatus"] }
}

extension Tag: SharedEntity {
    static var localOnlyKeys: Set<String> { [] }
}
