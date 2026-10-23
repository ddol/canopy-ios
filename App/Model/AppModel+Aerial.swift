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

    /// Replaces the candidates in the 9 L16 tiles around `point` with the trees found in 3DEP there.
    func loadAerialTrees(around point: GeoPoint) async {
        guard !aerial.isWorking else { return }
        guard let client = alignClient, let host = gerardusURL?.host() else {
            aerial = .failed(NoServerSet().errorDescription!)
            return
        }
        aerial = .working("Asking \(host)…")
        let tile = point.tile
        do {
            let result = try await AerialTrees.load(tile: tile, label: "canopy-ggp", client: client) { stage in
                Task { @MainActor [weak self] in
                    // A late update must not overwrite the result.
                    guard let self, aerial.isWorking else { return }
                    aerial = .working(Self.describe(stage))
                }
            }
            let removed = try await store.replaceCandidates(inTiles: result.tiles, with: result.candidates)
            UserDefaults.standard.set(result.attribution, forKey: Self.attributionKey)
            await refresh()
            let format = QuantityFormat()
            aerial = .done(
                "\(format.count(result.candidates.count)) trees from aerial LiDAR around tile \(tile.familyDisplay)"
                    + (removed > 0 ? ", replacing \(format.count(removed)) sample candidates." : "."))
        } catch {
            aerial = .failed("Could not load aerial trees: \(error.localizedDescription)")
        }
    }

    nonisolated static func describe(_ stage: AerialTrees.Stage) -> String {
        switch stage {
        case .preparing(let progress):
            let stage = progress.stage.isEmpty ? "site" : progress.stage
            return "Preparing the \(stage) data on the server…"
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
            site = try await client.preparedSite(tile.token, label: "canopy-ggp")
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
