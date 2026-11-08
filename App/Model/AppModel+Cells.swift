import CanopyMap
import CanopyModel
import CanopyReference
import Foundation
import Observation

/// What the server has prepared in one S2 level-13 cell: which of its 64 level-16 sites exist.
struct CellCoverage: Identifiable, Equatable {
    nonisolated static let level = 13

    let cell: S2CellID
    var prepared: Set<S2CellID>

    var id: S2CellID { cell }
    var sites: [S2CellID] { cell.children(atLevel: S2CellID.tileLevel) }
    var total: Int { sites.count }
    var count: Int { sites.filter(prepared.contains).count }
    var isComplete: Bool { count == total }
    var missing: [S2CellID] { sites.filter { !prepared.contains($0) } }
}

/// Preparing every site of a level-13 cell on the server, one after another, with progress. Lives on the model, so
/// it carries on when the screen that started it closes.
@MainActor
@Observable
final class CellPreparation {
    let cell: S2CellID
    /// True when every site is fetched again even if the server had it.
    let refresh: Bool
    let total: Int
    private(set) var done = 0
    private(set) var current: String?
    private(set) var failed: [String] = []
    private(set) var isFinished = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(cell: S2CellID, refresh: Bool, total: Int) {
        self.cell = cell
        self.refresh = refresh
        self.total = total
    }

    var isRunning: Bool { !isFinished }

    func cancel() {
        task?.cancel()
        finish()
    }

    fileprivate func start(_ work: @escaping @MainActor (CellPreparation) async -> Void) {
        task = Task { await work(self) }
    }

    fileprivate func began(_ token: S2CellID) {
        current = token.familyDisplay
    }

    fileprivate func ended(_ token: S2CellID, error: (any Error)?) {
        done += 1
        if let error { failed.append("\(token.familyDisplay): \(error.localizedDescription)") }
    }

    fileprivate func finish() {
        current = nil
        isFinished = true
    }
}

/// Whole level-13 cells on the server: how much of each is prepared, and preparing the rest.
extension AppModel {
    /// How long one site is given while the server builds it, and how often it is asked after.
    nonisolated static let cellSitePatience: Duration = .seconds(600)

    /// The level-13 cells under a map region, nearest the centre first, with the sites the server has prepared in
    /// each. A zoomed-out map shows at most the dozen nearest.
    func cellCoverage(in viewport: MapViewport) async throws -> [CellCoverage] {
        guard let client = alignClient else { throw NoServerSet() }
        let prepared = Set(try await client.listSites().compactMap { S2CellID(token: $0.l16Token) })
        return Self.cells(in: viewport).map { cell in
            CellCoverage(cell: cell, prepared: prepared.filter { cell.contains($0) })
        }
    }

    /// The level-13 cells a region touches, nearest its centre first.
    nonisolated static func cells(in viewport: MapViewport, limit: Int = 12) -> [S2CellID] {
        var cells: [S2CellID: Double] = [:]
        let steps = 6
        for i in 0...steps {
            for j in 0...steps {
                let point = GeoPoint(
                    latitude: viewport.center.latitude + (Double(i) / Double(steps) - 0.5) * viewport.latitudeDelta,
                    longitude: viewport.center.longitude + (Double(j) / Double(steps) - 0.5)
                        * viewport.longitudeDelta)
                let cell = S2CellID(point, level: CellCoverage.level)
                let distance = LocalFrame(origin: viewport.center).enu(of: cell.center).horizontalDistance
                cells[cell] = min(cells[cell] ?? .infinity, distance)
            }
        }
        return cells.sorted { $0.value < $1.value }.prefix(limit).map(\.key)
    }

    /// Prepares the sites of a cell the server does not have (or every site again, with `refresh`), one at a time,
    /// reporting through `cellPreparation`. One cell at a time; a second request replaces a finished one.
    func prepareCell(_ coverage: CellCoverage, refresh: Bool) {
        guard cellPreparation?.isRunning != true, let client = alignClient else { return }
        let tokens = refresh ? coverage.sites : coverage.missing
        let preparation = CellPreparation(cell: coverage.cell, refresh: refresh, total: tokens.count)
        cellPreparation = preparation
        preparation.start { preparation in
            for token in tokens where !Task.isCancelled {
                preparation.began(token)
                do {
                    try await Self.prepare(token, refresh: refresh, client: client)
                    preparation.ended(token, error: nil)
                } catch is CancellationError {
                    break
                } catch {
                    preparation.ended(token, error: error)
                }
            }
            preparation.finish()
        }
    }

    /// Asks the server for one site and waits, asking again at intervals while it builds, until it is there.
    nonisolated static func prepare(_ token: S2CellID, refresh: Bool, client: AlignClient) async throws {
        let start = ContinuousClock.now
        var first = true
        while true {
            try Task.checkCancellation()
            do {
                for try await event in client.prepareSite(token.token, label: "canopy-ggp", refresh: refresh && first) {
                    if case .ready = event { return }
                }
                // The stream ended without a site: ask whether it is there now.
                if try await client.site(token.token) != nil { return }
            } catch let error where isStillBuilding(error) {
                if try await client.site(token.token) != nil, !(refresh && first) { return }
            }
            first = false
            guard ContinuousClock.now - start < cellSitePatience else {
                throw AerialTrees.Failure.stillPreparing
            }
            try await Task.sleep(for: vectorRetryInterval)
        }
    }
}
