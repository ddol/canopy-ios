import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyReference
import Foundation

/// Gerardus's vectors (building outlines and walls, streets, kerbs, street surfaces) on the main map, a site at a time.
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

    /// Loads the public vectors of the site at `centre` (preparing the site first when needed) and adds them to the
    /// map, beside any loaded before.
    func loadVectors(around centre: GeoPoint) async {
        guard !aerial.isWorking else { return }
        guard let client = alignClient else {
            aerial = .failed(NoServerSet().errorDescription!)
            return
        }
        let tile = centre.tile
        aerial = .working("Loading vectors…")
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
            let reference = Self.reference(vectors, georeference: georeference)
            vectorAreas[tile.token] = reference
            vectorTiles.formUnion(vectors.site.coveringL16Tokens.compactMap(S2CellID.init(token:)))
            vectorAttribution = Array(Set(vectorAttribution + vectors.attribution)).sorted()
            let format = QuantityFormat()
            let buildings = reference.lines.filter { $0.kind == .building || $0.kind == .wall }.count
            let streets = reference.lines.filter { [.road, .path, .kerb, .surface].contains($0.kind) }.count
            aerial = .done(
                "\(format.count(buildings)) building outlines and walls, \(format.count(streets)) street lines around "
                    + "tile \(tile.familyDisplay).")
        } catch let error as AerialTrees.Failure {
            aerial = .failed(error.localizedDescription)
        } catch {
            aerial = .failed("Could not load vectors: \(error.localizedDescription)")
        }
    }

    /// A site's vectors on the map, seen from above. Ground, trees (the census has its own) and sensor arrows are left
    /// out.
    nonisolated static func reference(_ vectors: VectorReference, georeference: SiteGeoreference) -> MapLayers.Reference
    {
        let lines = vectors.features.compactMap { feature -> MapLayers.Reference.Line? in
            guard let kind = lineKind(layer: feature.layer, kind: feature.line.kind) else { return nil }
            let points = feature.line.points.map { georeference.geo(x: $0.x, y: $0.y) }
            guard Set(points.map { [$0.latitude, $0.longitude] }).count >= 2 else { return nil }
            return MapLayers.Reference.Line(
                kind: kind, points: points, closed: feature.line.closed || kind == .building || kind == .surface)
        }
        return MapLayers.Reference(canopies: [], lines: lines)
    }

    nonisolated static func lineKind(layer: ReferenceLayer, kind: FeatureKind) -> MapLayers.Reference.LineKind? {
        switch layer {
        case .groundMesh, .trees, .aerialPoints, .registeredScans:
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
