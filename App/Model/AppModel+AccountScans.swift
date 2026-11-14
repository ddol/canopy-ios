import CanopyModel
import CanopyReference
import CanopySync
import Foundation

/// A scan this player took on another device (a phone, when this is an iPad with no LiDAR), as the server has it: the
/// mesh is a blob on the server, named by its hash, and comes down when it is first opened (`evidenceFile`).
nonisolated struct AccountScan: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable {
        /// In a change of theirs still waiting for a second player to agree.
        case waiting
        /// On the shared map.
        case onMap
    }

    var blob: BlobRef
    /// The tree (or limb tag) the scan is about.
    var subject: UUID
    var entity: EntityKind
    /// When the change carrying it was made (waiting) or applied (on the map).
    var date: Date
    var state: State

    var id: BlobRef { blob }
}

extension AppModel {
    /// The scans this player took on their other devices, newest first: those in their changes still waiting for
    /// agreement (`ownOpenChangesets`, from the last sync) and those on the shared map, found in the change history of
    /// the tiles whose trees and tags hold scans not on this device, which says who added each. Scans on this device
    /// are left out: `store.allEvidence` lists those. Empty without a server.
    func scansFromOtherDevices() async throws -> [AccountScan] {
        guard let client = mapClient else { return [] }
        let local = Set(try await store.allEvidence().map(\.blob))
        var tiles: Set<S2CellID> = []
        for tree in census.trees.values where tree.evidenceRefs.contains(where: { !local.contains($0) }) {
            tiles.insert(tree.position.tile)
        }
        for tag in census.tags.values {
            guard let ref = tag.evidenceRef, !local.contains(ref), let tree = census.trees[tag.treeID] else { continue }
            tiles.insert(tree.position.tile)
        }
        let histories = try await Self.concurrently(tiles.sorted()) { try await Self.history(of: $0, client) }
        let author = player.id
        var found: [BlobRef: AccountScan] = [:]
        for scan in Self.scans(by: author, in: histories.flatMap { $0 }) { found[scan.blob] = scan }
        let shared = census.trees.mapValues { Set($0.evidenceRefs) }
        for scan in Self.waitingScans(by: author, in: ownOpenChangesets, alreadyOn: shared)
        where found[scan.blob] == nil {
            found[scan.blob] = scan
        }
        return found.values.filter { !local.contains($0.blob) }.sorted { $0.date > $1.date }
    }

    /// Every change applied in a tile, oldest first, a page at a time.
    nonisolated static func history(of tile: S2CellID, _ client: GerardusMapClient) async throws -> [AppliedChange] {
        var since: Int64 = 0
        var changes: [AppliedChange] = []
        while true {
            let page = try await client.pullChanges(in: tile, since: since)
            changes += page.changes
            guard let last = page.changes.last, last.sequence > since, last.sequence < page.latestSequence else {
                break
            }
            since = last.sequence
        }
        return changes
    }

    /// The scans `author` added in a run of applied changes: each change's scans that its entity did not hold before
    /// it, a tree's list of scans being given in full whenever it changes. A change seen in two tiles counts once.
    nonisolated static func scans(by author: PlayerID, in changes: [AppliedChange]) -> [AccountScan] {
        var held: [UUID: Set<BlobRef>] = [:]
        var seen: Set<Int64> = []
        var found: [BlobRef: AccountScan] = [:]
        for change in changes.sorted(by: { $0.sequence < $1.sequence }) where seen.insert(change.sequence).inserted {
            let op = change.op
            if op.op == .delete {
                held[op.id] = nil
                continue
            }
            let before = held[op.id, default: []]
            let (after, added) = scansAfter(op, holding: before)
            held[op.id] = after
            guard change.author == author else { continue }
            for ref in added where found[ref] == nil {
                found[ref] = AccountScan(
                    blob: ref, subject: op.id, entity: op.entity, date: change.appliedAt, state: .onMap)
            }
        }
        return Array(found.values)
    }

    /// The scans in `author`'s open changesets that the shared map does not hold yet.
    nonisolated static func waitingScans(
        by author: PlayerID, in open: [Changeset], alreadyOn shared: [UUID: Set<BlobRef>]
    ) -> [AccountScan] {
        var found: [BlobRef: AccountScan] = [:]
        for changeset in open where changeset.meta.playerID == author {
            for op in changeset.ops where op.op != .delete {
                for ref in scansAfter(op, holding: shared[op.id, default: []]).added where found[ref] == nil {
                    found[ref] = AccountScan(
                        blob: ref, subject: op.id, entity: op.entity, date: changeset.meta.createdAt, state: .waiting)
                }
            }
        }
        return Array(found.values)
    }

    /// What an entity holding `before` holds after `op`, and which of those are new: a tree's `evidenceRefs` replace
    /// its list, a tag's `evidenceRef` is its one scan.
    nonisolated static func scansAfter(
        _ op: ChangeOp, holding before: Set<BlobRef>
    ) -> (
        after: Set<BlobRef>, added: Set<BlobRef>
    ) {
        var after = op.op == .create ? [] : before
        if case .array(let values)? = op.fields["evidenceRefs"] {
            after = Set(values.compactMap { $0.stringValue.flatMap(BlobRef.init(rawValue:)) })
        }
        if let ref = op.fields["evidenceRef"]?.stringValue.flatMap(BlobRef.init(rawValue:)) {
            after.insert(ref)
        }
        return (after, after.subtracting(before))
    }
}
