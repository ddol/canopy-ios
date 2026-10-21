import Foundation

/// Something a player saw or did, recorded once and never changed.
///
/// Observations are the local source of truth: the store appends them to a log and derives the current
/// trees and tags from that log (see `CensusState`). Each one is shared through a changeset.
public struct Observation: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        /// "Confirm tree": an existing (usually detected) tree is real.
        case treeConfirmed(treeID: UUID)
        /// "New tree here": a tree the aerial survey missed.
        case treeAdded(Tree)
        /// "Not a tree".
        case treeRejected(treeID: UUID)
        /// A trunk measurement with its evidence mesh.
        case trunkMeasured(treeID: UUID, dbh: DBH, lean: Lean?, evidence: BlobRef)
        /// A limb hazard.
        case tagPlaced(Tag)

        /// A short stable name, stored alongside the payload for querying.
        public var name: String {
            switch self {
            case .treeConfirmed: "treeConfirmed"
            case .treeAdded: "treeAdded"
            case .treeRejected: "treeRejected"
            case .trunkMeasured: "trunkMeasured"
            case .tagPlaced: "tagPlaced"
            }
        }

        /// The entity the observation is about.
        public var subject: (entity: EntityKind, id: UUID) {
            switch self {
            case .treeConfirmed(let id), .treeRejected(let id): (.tree, id)
            case .trunkMeasured(let id, _, _, _): (.tree, id)
            case .treeAdded(let tree): (.tree, tree.id)
            case .tagPlaced(let tag): (.tag, tag.id)
            }
        }
    }

    public var meta: RecordMeta
    /// The changeset that shares this observation. Nil only for observations that are never shared.
    public var changesetID: UUID?
    public var kind: Kind

    public init(meta: RecordMeta, changesetID: UUID?, kind: Kind) {
        self.meta = meta
        self.changesetID = changesetID
        self.kind = kind
    }

    public var id: UUID { meta.id }
}
