import Foundation

/// The current trees and tags, derived from the aerial base layer and the observation log.
///
/// Derivation folds observations over the base layer twice:
/// - the **shared** fold uses only observations whose changesets were applied to the shared map;
/// - the **local** fold uses every observation whose changeset is still open or applied.
///
/// A tree's `countStatus` comes from the shared fold (`proposed` if it exists only locally), and its
/// `proposedStatus` is the local fold's status when that differs. Everything else comes from the local fold,
/// so a player sees their own measurements straight away. Observations in rejected or conflicted changesets
/// drop out of both folds.
public struct CensusState: Hashable, Sendable {
    public private(set) var trees: [UUID: Tree]
    public private(set) var tags: [UUID: Tag]

    public init(trees: [Tree] = [], tags: [Tag] = []) {
        self.trees = Dictionary(trees.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.tags = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public static func derive(
        base: [Tree],
        observations: [Observation],
        changesetStates: [UUID: Changeset.State]
    ) -> CensusState {
        let baseState = CensusState(trees: base)
        var shared = baseState
        var local = baseState
        for observation in observations {
            let state = observation.changesetID.flatMap { changesetStates[$0] }
            switch state {
            case .applied:
                shared.apply(observation)
                local.apply(observation)
            case .pending, .approved:
                local.apply(observation)
            case .rejected, .conflicted:
                break
            case nil:
                // Not shared (no changeset) or the changeset is missing: keep it on this device only.
                local.apply(observation)
            }
        }

        var result = local
        for (id, var tree) in local.trees {
            let agreed = shared.trees[id]?.countStatus ?? .proposed
            let believed = tree.countStatus
            tree.countStatus = agreed
            tree.proposedStatus = believed == agreed ? nil : believed
            result.trees[id] = tree
        }
        for (id, var tag) in local.tags {
            tag.status = shared.tags[id]?.status ?? .proposed
            result.tags[id] = tag
        }
        return result
    }

    /// Applies one observation as if it were agreed. Observations about unknown entities are ignored.
    public mutating func apply(_ observation: Observation) {
        switch observation.kind {
        case .treeConfirmed(let id):
            update(tree: id) { tree in
                if tree.countStatus != .verified {
                    tree.countStatus = .confirmed
                }
            }
        case .treeAdded(let tree):
            guard trees[tree.id] == nil else { return }
            var added = tree
            added.countStatus = .confirmed
            added.proposedStatus = nil
            added.meta.version = 1
            trees[added.id] = added
        case .treeRejected(let id):
            update(tree: id) { tree in
                tree.countStatus = .removed
            }
        case .trunkMeasured(let id, let dbh, let lean, let evidence):
            update(tree: id) { tree in
                tree.dbh = dbh
                tree.lean = lean
                if !tree.evidenceRefs.contains(evidence) {
                    tree.evidenceRefs.append(evidence)
                }
                if tree.countStatus != .removed {
                    tree.countStatus = .verified
                }
            }
        case .tagPlaced(let tag):
            guard tags[tag.id] == nil, trees[tag.treeID] != nil else { return }
            var placed = tag
            placed.status = .confirmed
            placed.meta.version = 1
            tags[placed.id] = placed
        }
    }

    public func applying(_ observation: Observation) -> CensusState {
        var copy = self
        copy.apply(observation)
        return copy
    }

    private mutating func update(tree id: UUID, _ change: (inout Tree) -> Void) {
        guard var tree = trees[id] else { return }
        change(&tree)
        tree.meta.version += 1
        trees[id] = tree
    }
}

/// The numbers in the map's summary bar.
public struct CensusSummary: Hashable, Sendable {
    /// Trees agreed on the shared map (confirmed or verified).
    public var confirmed: Int
    /// The best current estimate of how many trees there are: every tree this device believes is not removed.
    public var estimated: Int
    /// The share of the estimated trees a person has looked at (anything past `detected`), 0…1.
    public var coverage: Double

    public init(confirmed: Int, estimated: Int, coverage: Double) {
        self.confirmed = confirmed
        self.estimated = estimated
        self.coverage = coverage
    }

    public init(trees: some Collection<Tree>) {
        var confirmed = 0
        var estimated = 0
        var looked = 0
        for tree in trees {
            if tree.countStatus == .confirmed || tree.countStatus == .verified {
                confirmed += 1
            }
            switch tree.effectiveStatus {
            case .removed:
                break
            case .detected:
                estimated += 1
            case .proposed, .confirmed, .verified:
                estimated += 1
                looked += 1
            }
        }
        self.init(
            confirmed: confirmed,
            estimated: estimated,
            coverage: estimated == 0 ? 0 : Double(looked) / Double(estimated)
        )
    }
}
