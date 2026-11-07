import CanopyCapture
import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyReference
import Foundation

/// A loaded site's vectors as the server sent them, with the georeference that places them on the map. The AR
/// overlay draws from these; the map draws from the `MapLayers.Reference` made of them.
struct LoadedVectors {
    let vectors: VectorReference
    let georeference: SiteGeoreference
}

/// Gerardus's vectors (building outlines and walls, streets, kerbs, street surfaces, trees) on the main map and in
/// AR, a site at a time.
extension AppModel {
    /// Whether the vectors around `point` are loaded.
    func hasVectors(at point: GeoPoint) -> Bool {
        vectorTiles.contains(point.tile)
    }

    /// Credits for everything drawn: the aerial trees and the loaded vectors.
    var mapAttribution: [String] {
        var seen: Set<String> = []
        return (aerialAttribution + vectorAttribution).filter { seen.insert($0).inserted }
    }

    /// How long a site load keeps retrying while the server builds the site's model, and how long between tries.
    static let vectorBuildPatience: Duration = .seconds(240)
    nonisolated static let vectorRetryInterval: Duration = .seconds(15)

    /// Loads the public vectors of the site at `centre` (preparing the site first when needed) and adds them to the
    /// map, beside any loaded before. A server that has not seen the site builds its model first, which takes a
    /// minute or two and times out a single request, so the load keeps asking at intervals until the site arrives or
    /// `vectorBuildPatience` runs out.
    func loadVectors(around centre: GeoPoint) async {
        guard !aerial.isWorking else { return }
        guard let client = alignClient else {
            aerial = .failed(NoServerSet().errorDescription!)
            return
        }
        let tile = centre.tile
        aerial = .working("Loading vectors…")
        let start = ContinuousClock.now
        var attempt = 0
        do {
            while true {
                attempt += 1
                do {
                    if try await client.site(tile.token) == nil {
                        aerial = .working("Preparing the site on the server…")
                        do {
                            _ = try await client.preparedSite(tile.token, label: "canopy-ggp")
                        } catch GRPCTransportError.timedOut {
                            throw AerialTrees.Failure.stillPreparing
                        }
                    }
                    let vectors = try await VectorReference.load(token: tile.token, client: client)
                    let georeference = try await SiteGeoreference.fetch(for: vectors.site, client: client)
                    add(vectors, georeference: georeference, tile: tile)
                    return
                } catch let error where Self.isStillBuilding(error) {
                    let waited = ContinuousClock.now - start
                    guard waited < Self.vectorBuildPatience else { throw error }
                    let seconds = Int(waited.components.seconds)
                    aerial = .working(
                        "The server is building this site's model (\(seconds) s so far). Asking again shortly…")
                    try await Task.sleep(for: Self.vectorRetryInterval)
                }
            }
        } catch let error as AerialTrees.Failure {
            aerial = .failed(error.localizedDescription)
        } catch let error as VectorReference.Failure {
            aerial = .failed(error.localizedDescription)
        } catch {
            aerial = .failed("Could not load vectors: \(error.localizedDescription)")
        }
    }

    /// Whether a load failed only because the server is still building the site's model.
    nonisolated static func isStillBuilding(_ error: any Error) -> Bool {
        switch error {
        case AerialTrees.Failure.stillPreparing, VectorReference.Failure.stillBuilding: true
        case GRPCTransportError.timedOut: true
        default: false
        }
    }

    /// Keeps a loaded site and reports what arrived.
    private func add(_ vectors: VectorReference, georeference: SiteGeoreference, tile: S2CellID) {
        let reference = Self.reference(vectors, georeference: georeference, token: tile.token)
        loadedVectors[tile.token] = LoadedVectors(vectors: vectors, georeference: georeference)
        vectorAreas[tile.token] = reference
        vectorTiles.formUnion(vectors.site.coveringL16Tokens.compactMap(S2CellID.init(token:)))
        vectorAttribution = Array(Set(vectorAttribution + vectors.attribution)).sorted()
        let format = QuantityFormat()
        let buildings = reference.lines.filter { $0.kind == .building || $0.kind == .wall }.count
        let streets = reference.lines.filter { [.road, .path, .kerb, .surface].contains($0.kind) }.count
        let trees = reference.lines.filter { $0.kind == .tree }.count
        aerial = .done(
            "\(format.count(buildings)) building outlines and walls, \(format.count(streets)) street lines and "
                + "\(format.count(trees)) trees around tile \(tile.familyDisplay).")
    }

    /// A site's vectors on the map, seen from above: Gerardus's trees as their crowns, buildings as outlines and
    /// walls, streets as lines. Ground and sensor arrows are left out.
    nonisolated static func reference(
        _ vectors: VectorReference, georeference: SiteGeoreference, token: String = ""
    ) -> MapLayers.Reference {
        let lines = vectors.features.compactMap { feature -> MapLayers.Reference.Line? in
            if feature.layer == .trees {
                guard let tree = GerardusTree(feature.line) else { return nil }
                return MapLayers.Reference.Line(
                    kind: .tree, points: crown(of: tree, georeference: georeference), closed: true)
            }
            guard let kind = lineKind(layer: feature.layer, kind: feature.line.kind) else { return nil }
            let points = feature.line.points.map { georeference.geo(x: $0.x, y: $0.y) }
            guard Set(points.map { [$0.latitude, $0.longitude] }).count >= 2 else { return nil }
            return MapLayers.Reference.Line(
                kind: kind, points: points, closed: feature.line.closed || kind == .building || kind == .surface)
        }
        return MapLayers.Reference(
            canopies: [], lines: lines,
            sites: [MapLayers.Reference.Site(token: token, vectors: vectors, georeference: georeference)])
    }

    /// A tree's crown from above: a ring of its radius round the trunk.
    nonisolated static func crown(of tree: GerardusTree, georeference: SiteGeoreference) -> [GeoPoint] {
        let centre = georeference.geo(x: Double(tree.base.x), y: Double(tree.base.y))
        let frame = LocalFrame(origin: centre)
        let radius = tree.form.crownWidth / 2
        return (0..<24).map { i in
            let angle = Double(i) / 24 * 2 * .pi
            return frame.geoPoint(of: ENU(east: cos(angle) * radius, north: sin(angle) * radius, up: 0)).point
        }
    }

    nonisolated static func lineKind(layer: ReferenceLayer, kind: FeatureKind) -> MapLayers.Reference.LineKind? {
        switch layer {
        case .trees:
            return kind == .tree ? .tree : nil
        case .groundMesh, .aerialPoints, .registeredScans:
            return nil
        case .boxes:
            return .wall
        case .observed:
            switch kind {
            case .wallPlane, .facade: return .wall
            case .pole: return .other
            default: return nil  // sensor positions and corrections
            }
        case .footprints:
            return .building
        case .buildings:
            // A wall surface is vertical, so from above it is a line, like a box wall.
            return kind == .wallSurface ? .wall : .building
        case .kerbs:
            return .kerb
        case .streetUse:
            return .surface
        case .cityStreets:
            return kind == .path ? .path : .road
        default:
            switch kind {
            case .building, .buildingPart, .roofPlane: return .building
            case .road, .travelLane: return .road
            case .path: return .path
            case .kerb, .island: return .kerb
            case .surface, .driveway, .parkingSpace: return .surface
            case .wallPlane, .facade, .wallSurface: return .wall
            case .sensor, .correction, .tree: return nil
            default: return .other
            }
        }
    }
}
