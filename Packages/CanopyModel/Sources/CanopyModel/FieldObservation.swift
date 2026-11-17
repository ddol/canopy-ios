import Foundation

/// Something a player saw or did, recorded once and never changed.
///
/// Observations are the local source of truth: the store appends them to a log and derives the current
/// trees and tags from that log (see `CensusState`). Each one is shared through a changeset.
public struct FieldObservation: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        /// "Confirm tree": an existing (usually detected) tree is real.
        case treeConfirmed(treeID: UUID)
        /// "New tree here": a tree the aerial survey missed.
        case treeAdded(Tree)
        /// "Not a tree".
        case treeRejected(treeID: UUID)
        /// "Move": the tree stands at `position` instead, which also says it is a tree.
        case treeMoved(treeID: UUID, position: Position)
        /// A trunk measurement with its evidence mesh. For a tree of several stems, `dbh` is their equivalent DBH and
        /// `stems` each of them (`Tree.stems`); a log written before stems were kept reads as nil.
        case trunkMeasured(treeID: UUID, dbh: DBH, lean: Lean?, evidence: BlobRef, stems: [StemMeasure]? = nil)
        /// The stems of a measured tree sorted by the player, with no new scan: one that was not a stem taken out, one
        /// the scan missed added, or some split off into a tree of their own. `stems` empty or of one stem leaves the
        /// tree with one.
        case stemsMeasured(treeID: UUID, dbh: DBH, stems: [StemMeasure])
        /// A limb hazard.
        case tagPlaced(Tag)

        /// A short stable name, stored alongside the payload for querying.
        public var name: String {
            switch self {
            case .treeConfirmed: "treeConfirmed"
            case .treeAdded: "treeAdded"
            case .treeRejected: "treeRejected"
            case .treeMoved: "treeMoved"
            case .trunkMeasured: "trunkMeasured"
            case .stemsMeasured: "stemsMeasured"
            case .tagPlaced: "tagPlaced"
            }
        }

        /// The entity the observation is about.
        public var subject: (entity: EntityKind, id: UUID) {
            switch self {
            case .treeConfirmed(let id), .treeRejected(let id): (.tree, id)
            case .trunkMeasured(let id, _, _, _, _), .treeMoved(let id, _), .stemsMeasured(let id, _, _): (.tree, id)
            case .treeAdded(let tree): (.tree, tree.id)
            case .tagPlaced(let tag): (.tag, tag.id)
            }
        }

        /// The scan the observation records, if it records one: a trunk measurement's mesh, or a tag's limb mesh. A
        /// scan is named by its hash (the SHA-256 of its GLB bytes), and one scan is recorded once.
        public var scan: BlobRef? {
            switch self {
            case .trunkMeasured(_, _, _, let evidence, _): evidence
            case .tagPlaced(let tag): tag.evidenceRef
            case .treeConfirmed, .treeAdded, .treeRejected, .treeMoved, .stemsMeasured: nil
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
