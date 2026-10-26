import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyReference
import CanopyStore
import Foundation
import os

/// Where loading aerial trees has got to.
enum AerialProgress: Equatable {
    case idle
    case working(String)
    case done(String)
    case failed(String)

    var isWorking: Bool {
        if case .working = self { true } else { false }
    }
}

/// The clients for one Gerardus server, calling as one player.
struct GerardusConnection {
    let url: URL
    let player: Player
    let align: AlignClient
    let map: GerardusMapClient
    let cache: ReferenceCache?
}

/// Real tree candidates and scan registration from a Gerardus align server.
extension AppModel {
    static let attributionKey = "canopy.aerialAttribution"

    /// The Gerardus server set in Me → Settings; nil until one is set.
    var gerardusURL: URL? { serverSettings.endpoint?.url }

    /// The align service, calling as the player: the server sends OpenStreetMap only to its admins.
    var alignClient: AlignClient? { gerardus?.align }

    /// The map service, where the shared tree census lives; nil until a server is set.
    var mapClient: GerardusMapClient? { gerardus?.map }

    /// Aerial data kept on this phone for the server in Settings, so loading an area again costs no download.
    var referenceCache: ReferenceCache? { gerardus?.cache }

    /// The clients for the server in Settings, calling as the player. Made once per server and player and then
    /// kept: each client holds a URLSession, so keeping them lets calls reuse connections, and screens can ask for
    /// them as often as they draw.
    var gerardus: GerardusConnection? {
        guard let url = gerardusURL else { return nil }
        if let kept = gerardusConnection, kept.url == url, kept.player == player { return kept }
        let connection = GerardusConnection(
            url: url, player: player, align: AlignClient(baseURL: url, player: player),
            map: GerardusMapClient(baseURL: url, player: player),
            cache: Self.isTesting()
                ? ReferenceCache(
                    directory: FileManager.default.temporaryDirectory.appending(path: "reference-\(UUID().uuidString)"))
                : ReferenceCache.caches(for: url))
        gerardusConnection = connection
        return connection
    }

    /// Thrown, or shown, when something needs the server and none is set.
    struct NoServerSet: LocalizedError {
        var errorDescription: String? { "Set the Gerardus server in Me → Settings." }
    }

    /// Credits for the aerial data on the map; empty while only the synthetic sample is loaded.
    var aerialAttribution: [String] {
        guard !candidateSources.isEmpty else { return [] }
        return UserDefaults.standard.stringArray(forKey: Self.attributionKey) ?? []
    }

    /// The farthest from the map centre trees are loaded, in metres. A zoomed-out map loads only its middle, which keeps
    /// the download to a few megabytes.
    static let aerialRadiusLimit = 150.0

    /// Replaces the candidates within `radius` metres of `centre` (at most `aerialRadiusLimit`) with the trees found
    /// in 3DEP there.
    func loadAerialTrees(around centre: GeoPoint, radius: Double) async {
        guard !aerial.isWorking else { return }
        guard let client = alignClient, let host = gerardusURL?.host() else {
            aerial = .failed(NoServerSet().errorDescription!)
            return
        }
        aerial = .working("Asking \(host)…")
        let area = AerialTrees.Area(centre: centre, radius: min(radius, Self.aerialRadiusLimit))
        // Progress arrives off the main actor; one consumer applies it in order.
        let (stages, stageSink) = AsyncStream.makeStream(of: AerialTrees.Stage.self)
        let updates = Task { [weak self] in
            for await stage in stages {
                // A late update must not overwrite the result.
                guard let self, aerial.isWorking else { return }
                aerial = .working(Self.describe(stage))
            }
        }
        defer {
            stageSink.finish()
            updates.cancel()
        }
        do {
            let start = ContinuousClock.now
            let result = try await AerialTrees.load(
                tile: centre.tile, area: area, osm: isAdmin && adminSettings.useOSM, label: "canopy-ggp",
                client: client, cache: referenceCache
            ) { stageSink.yield($0) }
            let stored = ContinuousClock.now
            let replacement = try await store.replaceCandidates(
                where: { result.covers($0) }, with: result.candidates)
            UserDefaults.standard.set(result.attribution, forKey: Self.attributionKey)
            aerialReference = Self.reference(result)
            await refresh()
            var timed = result
            timed.timings.append(.init(step: "store", seconds: Self.seconds(ContinuousClock.now - stored)))
            let timing = Self.describe(timed, total: ContinuousClock.now - start)
            Self.aerialLog.info("Loaded \(result.candidates.count) trees. \(timing, privacy: .public)")
            let format = QuantityFormat()
            var message =
                "\(format.count(result.candidates.count)) trees from aerial LiDAR within "
                + "\(format.length(area.radius, fractionDigits: 0)) of the map centre"
                + (result.fromCache ? ", from data saved on this phone" : "")
                + Self.describe(replacement)
            if result.osmRefused {
                message += " The server sends OpenStreetMap only to its admins, so it was left out."
            }
            if let saved = await saveDetectedTrees(result) {
                message += " " + saved
            }
            #if DEBUG || TESTING_TOOLS
                message += "\n" + timing
            #endif
            aerial = .done(message)
            syncSoon(after: .zero)
        } catch let error as AerialTrees.Failure {
            aerial = .failed(error.localizedDescription)
        } catch {
            aerial = .failed("Could not load aerial trees: \(error.localizedDescription)")
        }
    }

    /// Saves the trees found in a load to the server's trees layer, so they are on the shared map and players can
    /// confirm them. Trees found with OpenStreetMap stay on the phone: the shared layer takes nothing from it. Returns
    /// what to tell the player, or nil when there is nothing to say.
    func saveDetectedTrees(_ result: AerialTrees.SiteResult) async -> String? {
        guard let client = mapClient, !result.candidates.isEmpty else { return nil }
        guard !result.usedOSM else { return "They were found with OpenStreetMap, so they stay on this phone." }
        let version = Bundle.main.object(forInfoDictionaryKey: "CanopyVersion") as? String ?? "dev"
        do {
            let saved = try await client.importDetectedTrees(
                result.candidates, source: result.candidates[0].source ?? "USGS 3DEP aerial LiDAR",
                tiles: result.tiles, detector: "Canopy \(version) TreeDetector, 1 m voxels")
            let format = QuantityFormat()
            return saved.created == 0
                ? "The server already has them."
                : "Saved \(format.count(saved.created)) new \(saved.created == 1 ? "tree" : "trees") to the server."
        } catch let error as GRPCStatusError where error.code == GRPCStatusError.unimplemented {
            return "This server cannot save trees yet."
        } catch {
            return "Not saved to the server: \(error.localizedDescription)"
        }
    }

    /// What the Gerardus map draws for a loaded area: canopy heights and outlines, on the map.
    nonisolated static func reference(_ result: AerialTrees.SiteResult) -> MapLayers.Reference? {
        guard let georeference = result.georeference else { return nil }
        let canopy = result.canopy.map { chm in
            // The points are thinned to 1 m, so a 0.5 m grid is speckled: draw the highest of each 2 × 2 cells.
            let factor = chm.cellSize < 1 ? 2 : 1
            let nx = chm.nx / factor
            let ny = chm.ny / factor
            var heights = [Float](repeating: 0, count: nx * ny)
            for j in 0..<(ny * factor) {
                for i in 0..<(nx * factor) {
                    let k = (j / factor) * nx + i / factor
                    heights[k] = max(heights[k], chm.heights[j * chm.nx + i])
                }
            }
            let size = chm.cellSize * Double(factor)
            return MapLayers.Reference.Raster(
                southWest: georeference.geo(x: chm.origin.x, y: chm.origin.y),
                northEast: georeference.geo(
                    x: chm.origin.x + Double(nx) * size, y: chm.origin.y + Double(ny) * size),
                nx: nx, ny: ny, heights: heights)
        }
        let lines = result.lines.map { line in
            let kind: MapLayers.Reference.LineKind =
                switch line.kind {
                case .building: .building
                case .road: .road
                case .path: .path
                default: .other
                }
            return MapLayers.Reference.Line(
                kind: kind, points: line.points.map { georeference.geo(x: $0.x, y: $0.y) }, closed: line.closed)
        }
        return MapLayers.Reference(canopies: canopy.map { [$0] } ?? [], lines: lines)
    }

    static let aerialLog = Logger(subsystem: "io.github.ddol.canopy", category: "aerial")

    /// Where a load's time went, for measuring a link: "2.1 s: site 0.12, georeference 0.00, points 1.43 (270,132
    /// downloaded), detection 0.38, placing 0.01, store 0.16".
    nonisolated static func describe(_ result: AerialTrees.SiteResult, total: Duration) -> String {
        let format = QuantityFormat()
        let steps = result.timings.map { timing in
            String(format: "%@ %.2f", timing.step, timing.seconds)
                + (timing.step == "points"
                    ? " (\(format.count(result.pointCount)) \(result.fromCache ? "saved" : "downloaded"))" : "")
        }
        return String(format: "%.1f s: ", seconds(total)) + steps.joined(separator: ", ")
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    /// What a load changed among the candidates, ending the sentence: the sample it replaced, or the trees that are new
    /// or gone since this area was last loaded.
    nonisolated static func describe(_ replacement: LocalStore.CandidateReplacement) -> String {
        let format = QuantityFormat()
        if replacement.samplesGone > 0 {
            return ", replacing \(format.count(replacement.samplesGone)) sample candidates."
        }
        switch (replacement.added, replacement.gone) {
        case (0, 0): return "."
        case (let added, 0): return ", \(format.count(added)) of them new."
        case (0, let gone): return "; \(format.count(gone)) found before are gone."
        case (let added, let gone):
            return ", \(format.count(added)) of them new; \(format.count(gone)) found before are gone."
        }
    }

    nonisolated static func describe(_ stage: AerialTrees.Stage) -> String {
        switch stage {
        case .preparing(let progress) where progress.stage == "aerial" && (0...1).contains(progress.fraction):
            return "Preparing aerial LiDAR on the server: \(QuantityFormat().percent(Double(progress.fraction)))…"
        case .preparing:
            return "Preparing the site on the server…"
        case .downloading(let points):
            return "Downloading \(QuantityFormat().count(points)) aerial points…"
        case .readingSaved(let points):
            return "Reading \(QuantityFormat().count(points)) saved aerial points…"
        case .detecting:
            return "Finding trees…"
        case .placing:
            return "Placing them on the map…"
        }
    }

    // MARK: Registration

    struct RegistrationOutcome {
        var registration: Registration
        /// Nil when the server found no pose.
        var placed: RegisteredScan?
    }

    enum RegistrationFailure: LocalizedError {
        case tooFewPoints(Int)

        var errorDescription: String? {
            switch self {
            case .tooFewPoints(let n):
                "Only \(n) mesh points so far. Look around slowly, ground and trees included, then try again."
            }
        }
    }

    /// Uploads the session's mesh (colourless points within 60 m of where the session started) and registers it
    /// against the site's 3DEP points.
    func registerScan(
        arkitPoints: [SIMD3<Float>], gps: GeoPoint, camera: SIMD3<Float>, groundBelowOrigin: Float?,
        northAligned: Bool, progress: @escaping @MainActor (String) -> Void
    ) async throws -> RegistrationOutcome {
        guard let client = alignClient else { throw NoServerSet() }
        progress("Thinning the scan…")
        let points = await Task.detached { ScanRegistration.scanPoints(fromARKit: arkitPoints) }.value
        guard points.count >= 2000 else { throw RegistrationFailure.tooFewPoints(points.count) }

        let hint = ScanRegistration.hint(
            gps: gps, camera: camera, groundBelowOrigin: groundBelowOrigin, northAligned: northAligned)
        let tile = GeoPoint(latitude: hint.position.latitude, longitude: hint.position.longitude).tile
        progress("Preparing the site…")
        let site: Site
        if let prepared = try await client.site(tile.token, cache: referenceCache) {
            site = prepared
        } else {
            do {
                site = try await client.preparedSite(tile.token, label: "canopy-ggp")
            } catch GRPCTransportError.timedOut {
                throw AerialTrees.Failure.stillPreparing
            }
        }
        let georeference = try await SiteGeoreference.fetch(for: site, client: client, cache: referenceCache)

        progress("Uploading \(QuantityFormat().count(points.count)) points…")
        let header = ScanHeader(
            l16Token: tile.token, sensorID: "canopy-" + UUID().uuidString.prefix(8).lowercased(),
            sensorModel: "apple-lidar-arkit", kind: .accumulated,
            captureRef: "canopy:" + UUID().uuidString.lowercased(),
            capturedAt: .now)
        let (scan, _) = try await client.uploadScan(header, points: points)

        var registration: Registration?
        for try await event in client.register(scanID: scan.scanID, hint: hint) {
            switch event {
            case .progress(let p): progress("Registering: \(p.stage)…")
            case .hypothesis: break
            case .finished(let result): registration = result
            }
        }
        guard let registration else { throw GRPCTransportError.noResponse }
        return RegistrationOutcome(
            registration: registration, placed: RegisteredScan(registration, georeference: georeference))
    }
}
