import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyReference
import Foundation
import Observation

/// Detecting the park's trees over whole tiles, site by site, with progress. Lives on the model, so it carries on when
/// the menu that started it closes.
@MainActor
@Observable
final class ParkDetection {
    /// The park's level-16 tiles.
    let total: Int
    /// Tiles detected in full so far, counting those already detected when it started.
    private(set) var detected = 0
    private(set) var sites = 0
    private(set) var trees = 0
    private(set) var failed: [String] = []
    private(set) var isFinished = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(total: Int) {
        self.total = total
    }

    var isRunning: Bool { !isFinished }

    func cancel() {
        task?.cancel()
    }

    fileprivate func start(_ work: @escaping @MainActor (ParkDetection) async -> Void) {
        task = Task { await work(self) }
    }

    fileprivate func update(detected: Int) {
        self.detected = detected
    }

    fileprivate func ended(_ site: S2CellID, trees: Int, error: (any Error)?) {
        sites += 1
        self.trees += trees
        if let error { failed.append("\(site.familyDisplay): \(error.localizedDescription)") }
    }

    fileprivate func finish() {
        isFinished = true
    }
}

/// Trees detected over whole S2 tiles. A Gerardus site is a level-16 tile and its 8 neighbours, and a load of the
/// whole site detects all 9 in full; the tiles detected so are remembered (`detectedTiles`), here and, on a server
/// that records them, in its tile summaries.
extension AppModel {
    nonisolated static let detectedTilesKey = "canopy.detectedTiles"

    nonisolated static func savedDetectedTiles(defaults: UserDefaults = .standard) -> Set<S2CellID> {
        Set((defaults.stringArray(forKey: detectedTilesKey) ?? []).compactMap(S2CellID.init(token:)))
    }

    static func saveDetectedTiles(_ tiles: Set<S2CellID>, defaults: UserDefaults = .standard) {
        guard !isTesting() else { return }
        defaults.set(tiles.map(\.token).sorted(), forKey: detectedTilesKey)
    }

    /// Detects the trees over every tile of the park the server does not have detected in full, a site at a time, and
    /// saves each site's trees to the server and to this phone: the series of loads that fills the tiles single loads
    /// left part done. Each site is the one round the first tile still to do that covers the most tiles still to do,
    /// one the server has prepared already where that is as good. For admins; `parkDetection` follows it.
    func detectPark() {
        guard parkDetection?.isRunning != true, !aerial.isWorking else { return }
        guard let client = alignClient else {
            aerial = .failed(NoServerSet().errorDescription!)
            return
        }
        let tiles = Self.parkTiles(boundary)
        let detection = ParkDetection(total: tiles.count)
        parkDetection = detection
        detection.start { [weak self] detection in
            await self?.detect(tiles, client: client, progress: detection)
            detection.finish()
        }
    }

    private func detect(_ tiles: Set<S2CellID>, client: AlignClient, progress: ParkDetection) async {
        let format = QuantityFormat()
        var remaining = tiles.subtracting(detectedTiles)
        // Only the tiles detected in full count, not those of sites that failed and were skipped.
        progress.update(detected: tiles.intersection(detectedTiles).count)
        aerial = .working("Finding the sites the server has prepared…")
        var prepared: [S2CellID: Set<S2CellID>] = [:]
        for site in (try? await client.listSites()) ?? [] {
            guard let tile = S2CellID(token: site.l16Token) else { continue }
            prepared[tile] = Set(site.coveringL16Tokens.compactMap(S2CellID.init(token:)))
        }
        var failuresInARow = 0
        while !Task.isCancelled, let next = Self.nextSite(for: remaining, prepared: prepared) {
            let site = next.site
            aerial = .working(
                "Detecting the park tile by tile: \(format.count(progress.detected)) of "
                    + "\(format.count(tiles.count)) detected in full, \(format.count(progress.trees)) trees. Now the "
                    + "site round \(site.familyDisplay)…")
            do {
                if prepared[site] == nil {
                    try await Self.prepare(site, refresh: false, client: client)
                }
                let result = try await loadWholeSite(site, client: client)
                _ = try await store.replaceCandidates(where: { result.covers($0) }, with: result.candidates)
                _ = try await importDetected(result)
                let credits = UserDefaults.standard.stringArray(forKey: Self.attributionKey) ?? []
                UserDefaults.standard.set(
                    credits + result.attribution.filter { !credits.contains($0) }, forKey: Self.attributionKey)
                detectedTiles.formUnion(result.tiles)
                remaining.subtract(result.tiles)
                remaining.remove(next.first)
                progress.ended(site, trees: result.candidates.count, error: nil)
                failuresInARow = 0
                await refresh()
            } catch is CancellationError {
                break
            } catch {
                // Stopping cancels the load under way, which fails as the network's own error.
                if Task.isCancelled { break }
                // That site cannot be done from here: leave its tiles for another run and carry on with the rest,
                // unless the server has stopped answering.
                Self.skip(site, remaining: &remaining, prepared: &prepared)
                remaining.remove(next.first)
                progress.ended(site, trees: 0, error: error)
                failuresInARow += 1
                if failuresInARow >= 3 { break }
            }
            progress.update(detected: tiles.intersection(detectedTiles).count)
        }
        syncSoon(after: .zero)
        var message =
            "\(format.count(progress.detected)) of the park's \(format.count(tiles.count)) tiles detected in full, "
            + "\(format.count(progress.sites)) \(progress.sites == 1 ? "site" : "sites") loaded, "
            + "\(format.count(progress.trees)) trees."
        if Task.isCancelled { message = "Stopped. " + message }
        if !progress.failed.isEmpty {
            message += " Failed: " + progress.failed.prefix(3).joined(separator: "; ")
        }
        aerial = progress.failed.isEmpty || progress.sites > progress.failed.count ? .done(message) : .failed(message)
    }

    /// Loads a whole site's trees. After being idle the server builds a site's model on first asking and the stream
    /// times out meanwhile, so it asks again every `vectorRetryInterval` for up to `vectorBuildPatience`. Whole sites
    /// are big and wanted once, so they are not kept in the cache.
    private func loadWholeSite(_ site: S2CellID, client: AlignClient) async throws -> AerialTrees.SiteResult {
        let start = ContinuousClock.now
        while true {
            do {
                return try await AerialTrees.load(tile: site, label: "canopy-ggp", client: client)
            } catch let error where Self.isStillBuilding(error) || error as? AerialTrees.Failure == .slowServer {
                let waited = ContinuousClock.now - start
                guard waited < Self.vectorBuildPatience else { throw error }
                if case .working(let message) = aerial, let line = message.split(separator: "\n").first {
                    aerial = .working(
                        "\(line)\nThe server is building that site (\(Int(waited.components.seconds)) s so far).")
                }
                try await Task.sleep(for: Self.vectorRetryInterval)
            }
        }
    }

    /// Sends a load's trees to the server's trees layer for the tiles it covered in full. Returns how many were new;
    /// nil when there is no server, nothing to send, or the trees were found with OpenStreetMap (which the shared layer
    /// never takes).
    func importDetected(_ result: AerialTrees.SiteResult) async throws -> Int? {
        guard let client = mapClient, !result.candidates.isEmpty, !result.usedOSM else { return nil }
        let version = Bundle.main.object(forInfoDictionaryKey: "CanopyVersion") as? String ?? "dev"
        return try await client.importDetectedTrees(
            result.candidates, source: result.candidates[0].source ?? "USGS 3DEP aerial LiDAR", tiles: result.tiles,
            detector: "Canopy \(version) TreeDetector, 1 m voxels"
        ).created
    }

    /// The site to load next, and the tile still to do that chose it: of the sites whose 9 tiles include the first
    /// tile still to do, the one covering the most tiles still to do, a prepared one winning a near tie (preparing a
    /// site takes the server up to a minute or so). A prepared site covers the tiles the server says; any other, the
    /// tile and the 8 round it. Nil when nothing is left.
    nonisolated static func nextSite(
        for remaining: Set<S2CellID>, prepared: [S2CellID: Set<S2CellID>] = [:]
    ) -> (site: S2CellID, first: S2CellID)? {
        guard let first = remaining.min() else { return nil }
        func score(_ site: S2CellID) -> Int {
            let covers = prepared[site] ?? block(around: site)
            return 2 * covers.intersection(remaining).count + (prepared[site] == nil ? 0 : 3)
        }
        let candidates = block(around: first).sorted()
        guard let best = candidates.max(by: { score($0) < score($1) }) else { return nil }
        return (best, first)
    }

    /// The tiles still to do once loading `site` failed: less all of its tiles, and it no longer counts as prepared, so
    /// the next pick is another site. Only the tile that chose it would be taken off otherwise, and the same site,
    /// still covering the most of the rest, would be picked again and fail again: three times, and the run stopped.
    nonisolated static func skip(
        _ site: S2CellID, remaining: inout Set<S2CellID>, prepared: inout [S2CellID: Set<S2CellID>]
    ) {
        remaining.subtract(block(around: site))
        if let covers = prepared.removeValue(forKey: site) { remaining.subtract(covers) }
    }

    /// A level-16 tile and the 8 round it, as a Gerardus site covers them: the tiles under the tile's centre reflected
    /// through each of its corners and the middles of its edges.
    nonisolated static func block(around tile: S2CellID) -> Set<S2CellID> {
        let frame = LocalFrame(origin: tile.center)
        let corners = tile.vertices.map { frame.enu(of: $0) }
        var points = [ENU(east: 0, north: 0, up: 0)]
        for (index, corner) in corners.enumerated() {
            let next = corners[(index + 1) % corners.count]
            points.append(ENU(east: 2 * corner.east, north: 2 * corner.north, up: 0))
            points.append(ENU(east: corner.east + next.east, north: corner.north + next.north, up: 0))
        }
        return Set(points.map { S2CellID(frame.geoPoint(of: $0).point, level: S2CellID.tileLevel) })
    }

    /// The level-16 tiles of the park: those with any of a 25 m grid of points inside its boundary.
    nonisolated static func parkTiles(_ boundary: [[GeoPoint]], step: Double = 25) -> Set<S2CellID> {
        var tiles: Set<S2CellID> = []
        for ring in boundary where ring.count >= 3 {
            let latitudes = ring.map(\.latitude)
            let longitudes = ring.map(\.longitude)
            guard let south = latitudes.min(), let north = latitudes.max(), let west = longitudes.min(),
                let east = longitudes.max()
            else { continue }
            let latitudeStep = step / 110_574
            let longitudeStep = step / (111_320 * cos((south + north) / 2 * .pi / 180))
            var latitude = south
            while latitude <= north {
                var longitude = west
                while longitude <= east {
                    let point = GeoPoint(latitude: latitude, longitude: longitude)
                    if contains(ring, point) { tiles.insert(point.tile) }
                    longitude += longitudeStep
                }
                latitude += latitudeStep
            }
        }
        return tiles
    }

    /// Whether a ring (in degrees, small enough to treat as flat) holds a point: even-odd crossings.
    nonisolated static func contains(_ ring: [GeoPoint], _ point: GeoPoint) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i]
            let b = ring[j]
            if (a.latitude > point.latitude) != (b.latitude > point.latitude) {
                let x =
                    (b.longitude - a.longitude) * (point.latitude - a.latitude) / (b.latitude - a.latitude)
                    + a.longitude
                if point.longitude < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
