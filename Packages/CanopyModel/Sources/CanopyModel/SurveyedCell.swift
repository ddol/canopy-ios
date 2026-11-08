import Foundation

/// A level-16 cell a player has walked and looked over: the detections in it were confirmed, rejected or judged not
/// worth a tap each. Marking the cell says the area is done, so the detections left in it count as looked at
/// without a verdict on each. Kept on the device for now; not yet shared through a changeset.
public struct SurveyedCell: Hashable, Codable, Sendable, Identifiable {
    public var cell: S2CellID
    public var surveyedAt: Date
    public var playerID: PlayerID
    /// What the census held in the cell when it was marked.
    public var confirmed: Int
    public var rejected: Int
    /// Detections left as they were.
    public var unreviewed: Int

    public init(
        cell: S2CellID, surveyedAt: Date = .now, playerID: PlayerID, confirmed: Int, rejected: Int, unreviewed: Int
    ) {
        self.cell = cell
        self.surveyedAt = surveyedAt
        self.playerID = playerID
        self.confirmed = confirmed
        self.rejected = rejected
        self.unreviewed = unreviewed
    }

    public var id: S2CellID { cell }
}

/// What the census holds in one level-16 cell, for deciding whether it is surveyed.
public struct CellCensus: Hashable, Sendable {
    public var cell: S2CellID
    /// Detections no one has acted on.
    public var detected: Int
    /// Trees confirmed or verified, and ones proposed by a player.
    public var confirmed: Int
    public var rejected: Int

    public init(cell: S2CellID, detected: Int, confirmed: Int, rejected: Int) {
        self.cell = cell
        self.detected = detected
        self.confirmed = confirmed
        self.rejected = rejected
    }

    /// Everything that was ever in the cell.
    public var total: Int { detected + confirmed + rejected }
    /// Trees someone has acted on, out of everything.
    public var reviewed: Int { confirmed + rejected }

    /// The census of every cell that holds a tree.
    public static func byCell(_ trees: some Collection<Tree>) -> [S2CellID: CellCensus] {
        var cells: [S2CellID: CellCensus] = [:]
        for tree in trees {
            let tile = tree.position.tile
            var census = cells[tile] ?? CellCensus(cell: tile, detected: 0, confirmed: 0, rejected: 0)
            switch tree.effectiveStatus {
            case .detected: census.detected += 1
            case .proposed, .confirmed, .verified: census.confirmed += 1
            case .removed: census.rejected += 1
            }
            cells[tile] = census
        }
        return cells
    }
}
