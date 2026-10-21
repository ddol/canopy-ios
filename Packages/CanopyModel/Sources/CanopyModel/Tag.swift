import Foundation

/// A limb hazard on a tree.
public struct Tag: Identifiable, Hashable, Codable, Sendable {
    public enum Issue: String, Codable, Sendable, CaseIterable {
        case deadwood
        case hanger
        case crack
        case decay
        case weakUnion
        case other
    }

    /// What the limb could hit if it fell.
    public enum Target: String, Codable, Sendable, CaseIterable {
        case path
        case road
        case seating
        case playArea
        case structure
        case nothing
    }

    /// Limb diameter class.
    public enum SizeClass: String, Codable, Sendable, CaseIterable {
        /// Under 0.10 m.
        case small
        /// 0.10 m to 0.30 m.
        case medium
        /// Over 0.30 m.
        case large
    }

    public enum Urgency: String, Codable, Sendable, CaseIterable {
        case low
        case moderate
        case high
        case immediate
    }

    public enum Status: String, Codable, Sendable, CaseIterable {
        /// Created on this device and not yet agreed.
        case proposed
        case confirmed
        case resolved
    }

    /// Where on the tree the limb is.
    public struct Point: Hashable, Codable, Sendable {
        public var position: Position
        /// Height above the ground at the trunk, in metres.
        public var heightAboveGround: Quantity

        public init(position: Position, heightAboveGround: Quantity) {
            self.position = position
            self.heightAboveGround = heightAboveGround
        }
    }

    public var meta: RecordMeta
    public var treeID: UUID
    public var point: Point
    public var issue: Issue
    public var couldHit: Target
    public var sizeClass: SizeClass
    public var urgency: Urgency
    public var evidenceRef: BlobRef?
    public var status: Status

    public init(
        meta: RecordMeta,
        treeID: UUID,
        point: Point,
        issue: Issue,
        couldHit: Target,
        sizeClass: SizeClass,
        urgency: Urgency,
        evidenceRef: BlobRef? = nil,
        status: Status = .proposed
    ) {
        self.meta = meta
        self.treeID = treeID
        self.point = point
        self.issue = issue
        self.couldHit = couldHit
        self.sizeClass = sizeClass
        self.urgency = urgency
        self.evidenceRef = evidenceRef
        self.status = status
    }

    public var id: UUID { meta.id }
}
