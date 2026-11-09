import CanopyMap
import CanopyModel
import Foundation

/// Surveying by area: marking a level-16 cell as looked over, so its detections count as reviewed without a verdict
/// on each, and what the census holds in each cell.
extension AppModel {
    /// What the census holds in every cell with a tree in it.
    var cellCensus: [S2CellID: CellCensus] {
        CellCensus.byCell(census.trees.values)
    }

    /// What the census holds in one cell, from the census by tile: the AR view shows this twice an update, and finding
    /// every tree's cell instead took a tenth of a second each time with the whole city loaded.
    func cellCensus(_ cell: S2CellID) -> CellCensus {
        Self.cellCensus(cell, in: census, tiles: censusTiles)
    }

    /// What `census` holds in one cell. With `tiles` (the census by tile, made from that same census), only the trees
    /// in the cell are looked at; without it, every tree is placed.
    nonisolated static func cellCensus(
        _ cell: S2CellID, in census: CensusState, tiles: CensusTiles? = nil
    ) -> CellCensus {
        var result = CellCensus(cell: cell, detected: 0, confirmed: 0, rejected: 0)
        let trees =
            tiles.map { ($0.trees[cell] ?? []).compactMap { census.trees[$0] } }
            ?? census.trees.values.filter { $0.position.tile == cell }
        for tree in trees {
            switch tree.effectiveStatus {
            case .detected: result.detected += 1
            case .proposed, .confirmed, .verified: result.confirmed += 1
            case .removed: result.rejected += 1
            }
        }
        return result
    }

    func isSurveyed(_ cell: S2CellID) -> Bool {
        surveyedCells[cell] != nil
    }

    /// Marks a cell as surveyed with what the census holds there now: the store's census, which waits for the store
    /// to be read at launch, where `census` is still empty and would mark the cell with nothing in it.
    func markSurveyed(_ cell: S2CellID) async {
        let counts = Self.cellCensus(cell, in: await store.state())
        let record = SurveyedCell(
            cell: cell, playerID: player.id, confirmed: counts.confirmed, rejected: counts.rejected,
            unreviewed: counts.detected)
        do {
            try await store.setSurveyed(record)
            await refresh()
        } catch {
            self.error = "Could not mark the cell: \(error.localizedDescription)"
        }
    }

    func unmarkSurveyed(_ cell: S2CellID) async {
        do {
            try await store.clearSurveyed(cell)
            await refresh()
        } catch {
            self.error = "Could not unmark the cell: \(error.localizedDescription)"
        }
    }
}
