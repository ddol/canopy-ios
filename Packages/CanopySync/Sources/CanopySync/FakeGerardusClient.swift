import CanopyModel
import CryptoKit
import Foundation

/// An in-memory Gerardus server for development and tests. No network.
///
/// It keeps blobs, changesets, a version per shared entity and an append-only log of applied ops. It applies
/// the Gerardus policy: a changeset is applied once at least two distinct players agree and at least one of
/// them is trusted. Ops are checked against the shared entity versions when a changeset is applied; a stale
/// base version marks the whole changeset `conflicted`.
public actor FakeGerardusClient: GerardusClient {
    private var blobs: [BlobRef: Data] = [:]
    private var submitted: [UUID: (changeset: Changeset, author: Player)] = [:]
    private var versions: [UUID: Int] = [:]
    private var log: [AppliedChange] = []
    private let clock: @Sendable () -> Date

    /// - Parameter baseEntities: entities already on the shared map (for example the aerial base layer), with
    ///   their versions.
    public init(baseEntities: [UUID: Int] = [:], clock: @escaping @Sendable () -> Date = { .now }) {
        self.versions = baseEntities
        self.clock = clock
    }

    /// Adds entities to the shared map without a changeset, as the aerial import does.
    public func seed(_ entities: [UUID: Int]) {
        versions.merge(entities) { current, _ in current }
    }

    public func uploadBlob(_ data: Data, ref: BlobRef) throws {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hex == ref.rawValue else { throw GerardusError.blobHashMismatch(ref) }
        blobs[ref] = data
    }

    public func submit(_ changeset: Changeset, author: Player) throws -> Changeset {
        guard submitted[changeset.id] == nil else { throw GerardusError.alreadySubmitted(changeset.id) }
        let missing = changeset.referencedBlobs.filter { blobs[$0] == nil }
        guard missing.isEmpty else { throw GerardusError.missingBlobs(missing) }
        var accepted = changeset
        accepted.state = .pending
        accepted.approvals = []
        submitted[changeset.id] = (accepted, author)
        return try settle(changeset.id)
    }

    public func changesets(_ ids: [UUID]) -> [Changeset] {
        ids.compactMap { submitted[$0]?.changeset }
    }

    public func pullChanges(in tile: S2CellID, since sequence: Int64) -> ChangePage {
        ChangePage(
            changes: log.filter { $0.tile == tile && $0.sequence > sequence },
            latestSequence: log.last(where: { $0.tile == tile })?.sequence ?? sequence
        )
    }

    /// Records another player's agreement with a changeset, as the review flow will. Applies the changeset if
    /// the policy is now met. Approving a changeset that is no longer open has no effect.
    @discardableResult
    public func approve(_ id: UUID, by player: Player) throws -> Changeset {
        guard var entry = submitted[id] else { throw GerardusError.unknownChangeset(id) }
        guard entry.changeset.state.isOpen else { return entry.changeset }
        if !entry.changeset.approvals.contains(where: { $0.playerID == player.id }) {
            entry.changeset.approvals.append(
                Changeset.Approval(playerID: player.id, isTrusted: player.isTrusted, at: clock())
            )
        }
        submitted[id] = entry
        return try settle(id)
    }

    /// Rejects a changeset, as a trusted reviewer can.
    @discardableResult
    public func reject(_ id: UUID) throws -> Changeset {
        guard var entry = submitted[id] else { throw GerardusError.unknownChangeset(id) }
        if entry.changeset.state.isOpen {
            entry.changeset.state = .rejected
            submitted[id] = entry
        }
        return entry.changeset
    }

    /// The ids of changesets still waiting for agreement.
    public func openChangesetIDs() -> [UUID] {
        submitted.values.filter { $0.changeset.state.isOpen }.map(\.changeset.id).sorted {
            $0.uuidString < $1.uuidString
        }
    }

    /// The shared version of an entity, if it is on the shared map.
    public func version(of id: UUID) -> Int? { versions[id] }

    private func settle(_ id: UUID) throws -> Changeset {
        guard var entry = submitted[id] else { throw GerardusError.unknownChangeset(id) }
        guard entry.changeset.state.isOpen,
            Changeset.meetsPolicy(author: entry.author, approvals: entry.changeset.approvals)
        else { return entry.changeset }

        // Check every op against the shared versions before applying any, chaining ops on one entity.
        var pending = versions
        for op in entry.changeset.ops {
            let current = pending[op.id] ?? 0
            let expected = op.op == .create ? 0 : current
            guard op.baseVersion == expected, op.op == .create ? current == 0 : current > 0 else {
                entry.changeset.state = .conflicted
                submitted[id] = entry
                return entry.changeset
            }
            pending[op.id] = op.op == .delete ? nil : current + 1
        }

        let now = clock()
        let tile = entry.changeset.cells.first ?? entry.changeset.meta.cell.parent(level: S2CellID.tileLevel)
        for op in entry.changeset.ops {
            let opTile = op.fields["cell"]?.stringValue.flatMap(S2CellID.init(token:))?.tile ?? tile
            log.append(
                AppliedChange(
                    sequence: Int64(log.count + 1), changesetID: id, tile: opTile, op: op, appliedAt: now))
        }
        versions = pending
        entry.changeset.state = .applied
        submitted[id] = entry
        return entry.changeset
    }
}
