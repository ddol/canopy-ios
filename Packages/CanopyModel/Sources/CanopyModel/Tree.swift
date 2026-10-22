import Foundation

/// Where a tree is in the census.
public enum CountStatus: String, Codable, Sendable, CaseIterable {
    /// Found by aerial LiDAR; no one has looked yet.
    case detected
    /// Added by a player and not yet agreed.
    case proposed
    /// Two players agree it is a tree, at least one of them trusted.
    case confirmed
    /// Confirmed, and its trunk measurement is agreed too.
    case verified
    /// Agreed not to be a tree (or gone).
    case removed
}

/// Diameter at breast height, measured 1.37 m above ground.
public struct DBH: Hashable, Codable, Sendable {
    public enum Method: String, Codable, Sendable {
        /// Circle fitted to a LiDAR mesh slice.
        case lidarCircleFit
        case tape
        case estimate
    }

    public static let standardHeight = 1.37

    /// Diameter in metres.
    public var diameter: Quantity
    public var method: Method
    /// Height above ground of the measurement, in metres.
    public var height: Double

    public init(diameter: Quantity, method: Method, height: Double = DBH.standardHeight) {
        self.diameter = diameter
        self.method = method
        self.height = height
    }
}

/// How far a trunk leans from vertical.
public struct Lean: Hashable, Codable, Sendable {
    /// Angle from vertical, in degrees.
    public var angle: Quantity
    /// Direction of the lean in degrees clockwise from true north, when the capture was north-aligned.
    public var azimuth: Quantity?

    public init(angle: Quantity, azimuth: Quantity? = nil) {
        self.angle = angle
        self.azimuth = azimuth
    }
}

public struct TreeHeight: Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable {
        case aerialLidar
        case groundLidar
        case estimate
    }

    /// Height in metres.
    public var height: Quantity
    public var source: Source

    public init(height: Quantity, source: Source) {
        self.height = height
        self.source = source
    }
}

public struct Tree: Identifiable, Hashable, Codable, Sendable {
    public var meta: RecordMeta
    public var position: Position
    /// The agreed status on the shared map.
    public var countStatus: CountStatus
    /// The status this device has proposed and is waiting for agreement on. Local only; never synced.
    public var proposedStatus: CountStatus?
    public var species: String?
    public var localName: String?
    public var dbh: DBH?
    public var lean: Lean?
    public var height: TreeHeight?
    public var evidenceRefs: [BlobRef]
    /// The aerial candidate this tree was detected as, if any.
    public var candidateID: String?

    public init(
        meta: RecordMeta,
        position: Position,
        countStatus: CountStatus,
        proposedStatus: CountStatus? = nil,
        species: String? = nil,
        localName: String? = nil,
        dbh: DBH? = nil,
        lean: Lean? = nil,
        height: TreeHeight? = nil,
        evidenceRefs: [BlobRef] = [],
        candidateID: String? = nil
    ) {
        self.meta = meta
        self.position = position
        self.countStatus = countStatus
        self.proposedStatus = proposedStatus
        self.species = species
        self.localName = localName
        self.dbh = dbh
        self.lean = lean
        self.height = height
        self.evidenceRefs = evidenceRefs
        self.candidateID = candidateID
    }

    public var id: UUID { meta.id }

    /// The status to show: `proposed` while this device waits for agreement, otherwise the agreed status.
    public var displayStatus: CountStatus { proposedStatus == nil ? countStatus : .proposed }

    /// The status this device believes, including its own pending proposal.
    public var effectiveStatus: CountStatus { proposedStatus ?? countStatus }
}
