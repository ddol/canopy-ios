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

/// Trunk diameter 1.37 m above the ground (DBH).
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

    /// The DBH a tree of several stems is reported by, as urban forest inventories do: the diameter of the one stem
    /// whose cross-section is all of theirs together, the square root of the sum of their squared diameters. Its
    /// uncertainty follows from theirs. Nil without a stem.
    public static func equivalent(of stems: [Quantity], method: Method) -> DBH? {
        guard !stems.isEmpty else { return nil }
        let sum = stems.reduce(0) { $0 + $1.value * $1.value }
        let diameter = sum.squareRoot()
        // dD/dd_i = d_i / D.
        let variance = stems.reduce(0) { $0 + pow($1.value * $1.uncertainty, 2) }
        let uncertainty = diameter > 0 ? variance.squareRoot() / diameter : stems[0].uncertainty
        return DBH(diameter: Quantity(diameter, uncertainty: uncertainty), method: method)
    }
}

/// One stem of a tree that comes out of the ground, or forks below breast height, as several: its diameter at
/// breast height and where it stands, in metres east and north of the tree's position.
public struct StemMeasure: Hashable, Codable, Sendable {
    /// At breast height (`DBH.standardHeight`), in metres.
    public var diameter: Quantity
    /// From the tree's position, on the ground, in metres.
    public var east: Double
    public var north: Double
    public var lean: Lean?

    public init(diameter: Quantity, east: Double, north: Double, lean: Lean? = nil) {
        self.diameter = diameter
        self.east = east
        self.north = north
        self.lean = lean
    }

    public var distance: Double { (east * east + north * north).squareRoot() }

    /// The stems of two scans of one tree together: a stem of `new` standing within `within` metres of one already
    /// measured replaces it, and the rest are added.
    public static func merging(_ old: [StemMeasure], with new: [StemMeasure], within: Double = 0.15) -> [StemMeasure] {
        var merged = old
        for stem in new {
            let near = merged.indices.filter {
                let (de, dn) = (merged[$0].east - stem.east, merged[$0].north - stem.north)
                return (de * de + dn * dn).squareRoot() <= within
            }
            if let index = near.first {
                merged[index] = stem
            } else {
                merged.append(stem)
            }
        }
        return merged
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
    /// For a tree of several stems, the equivalent DBH of them all (`DBH.equivalent`).
    public var dbh: DBH?
    public var lean: Lean?
    public var height: TreeHeight?
    public var evidenceRefs: [BlobRef]
    /// The aerial candidate this tree was detected as, if any.
    public var candidateID: String?
    /// Every stem at breast height, for a tree with more than one there; nil for a tree of one stem. Shared as
    /// `stems`, which a client that does not know it ignores.
    public var stems: [StemMeasure]?

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
        candidateID: String? = nil,
        stems: [StemMeasure]? = nil
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
        self.stems = stems
    }

    public var id: UUID { meta.id }

    /// How many stems the tree has at breast height, as far as is known.
    public var stemCount: Int { max(stems?.count ?? 1, 1) }

    /// The status to show: `proposed` while this device waits for agreement, otherwise the agreed status.
    public var displayStatus: CountStatus { proposedStatus == nil ? countStatus : .proposed }

    /// The status this device believes, including its own pending proposal.
    public var effectiveStatus: CountStatus { proposedStatus ?? countStatus }
}
