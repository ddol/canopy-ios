import CanopyDesign
import CanopyModel
import CanopyReference
import Foundation

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

/// Real tree candidates and scan registration from a Gerardus align server.
extension AppModel {
    static let attributionKey = "canopy.aerialAttribution"

    /// The Gerardus server set in Me → Settings; nil until one is set.
    var gerardusURL: URL? { serverSettings.endpoint?.url }

    var alignClient: AlignClient? { gerardusURL.map { AlignClient(baseURL: $0) } }

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
            let result = try await AerialTrees.load(
                tile: centre.tile, area: area, label: "canopy-ggp", client: client
            ) { stageSink.yield($0) }
            let removed = try await store.replaceCandidates(where: { result.covers($0) }, with: result.candidates)
            UserDefaults.standard.set(result.attribution, forKey: Self.attributionKey)
            await refresh()
            let format = QuantityFormat()
            aerial = .done(
                "\(format.count(result.candidates.count)) trees from aerial LiDAR within "
                    + "\(format.length(area.radius, fractionDigits: 0)) of the map centre"
                    + (removed > 0 ? ", replacing \(format.count(removed)) sample candidates." : "."))
        } catch let error as AerialTrees.Failure {
            aerial = .failed(error.localizedDescription)
        } catch {
            aerial = .failed("Could not load aerial trees: \(error.localizedDescription)")
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
        if let prepared = try await client.site(tile.token) {
            site = prepared
        } else {
            do {
                site = try await client.preparedSite(tile.token, label: "canopy-ggp")
            } catch GRPCTransportError.timedOut {
                throw AerialTrees.Failure.stillPreparing
            }
        }
        let georeference = try await SiteGeoreference.fetch(for: site, client: client)

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
