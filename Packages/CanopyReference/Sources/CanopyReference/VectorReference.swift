import Foundation

/// The reference envelope retains the model and completion flag even when a message also carries geometry.
public struct ReferenceMessage: Sendable, ProtoDecodable {
    public var layer = ReferenceLayer.unspecified
    public var chunk: ReferenceChunk?
    public var complete = false
    public var modelID = ""

    public init(fields: [ProtoField]) throws {
        for f in fields {
            switch f.number {
            case 1: layer = ReferenceLayer(rawValue: f.int) ?? .unspecified
            case 2: chunk = .points(layer, try PointBlock(f))
            case 3:
                chunk = .lines(
                    layer, try ProtoReader.fields(f.bytes).filter { $0.number == 1 }.map { try LineFeature($0) })
            case 4, 6: chunk = .other(layer)
            case 5: complete = f.bool
            case 7: chunk = .groundMesh(try Heightfield(f))
            case 8: modelID = f.string
            default: break
            }
        }
        // Protobuf permits the layer field after the payload.
        switch chunk {
        case .points(_, let block): chunk = .points(layer, block)
        case .lines(_, let lines): chunk = .lines(layer, lines)
        case .other: chunk = .other(layer)
        default: break
        }
        if chunk == nil, complete { chunk = .layerComplete(layer) }
    }
}

/// A bounded vector scene in one site's ENU frame. No raw scans, OSM or aerial point clouds are requested.
public struct VectorReference: Sendable {
    public static let kirkham9th = "8085875ef"
    public static let supportedLayers: [ReferenceLayer] = [
        .groundMesh, .footprints, .boxes, .observed, .cityStreets, .kerbs, .streetUse,
        .buildings, .laneMarkings, .streetFurniture, .trees,
    ]

    public struct Feature: Sendable {
        public var layer: ReferenceLayer
        public var line: LineFeature

        public init(layer: ReferenceLayer, line: LineFeature) {
            self.layer = layer
            self.line = line
        }
    }

    public var site: Site
    public var features: [Feature]
    public var ground: Heightfield?
    public var modelID: String
    /// Requested layers, including those that completed empty.
    public var layers: [ReferenceLayer]
    public var attribution: [String]

    public enum Failure: LocalizedError, Equatable {
        case unprepared, unavailable, incomplete, mixedModels, tooLarge, stillBuilding

        public var errorDescription: String? {
            switch self {
            case .unprepared: "This site has not been prepared on the server."
            case .unavailable: "The server has no vector geometry for this site."
            case .incomplete: "The server stopped before all vector layers finished. Try loading again."
            case .mixedModels: "The site's model changed while loading. Reload to get one consistent model."
            case .tooLarge: "This vector scene is too large. Try a smaller area."
            case .stillBuilding:
                "The server took too long to send this site. After being idle it builds the site's model first, "
                    + "which can take a minute or two. Try again shortly."
            }
        }
    }

    public static func load(token: String, client: AlignClient) async throws -> VectorReference {
        let info = try await client.serverInfo()
        guard let site = try await client.site(token) else { throw Failure.unprepared }
        let layers = supportedLayers.filter { info.availableLayers.contains($0) }
        guard !layers.isEmpty else { throw Failure.unavailable }
        var features: [Feature] = []
        var ground: Heightfield?
        var modelIDs: Set<String> = []
        var completed: Set<ReferenceLayer> = []
        var vertexCount = 0
        let request = StreamReferenceRequest(l16Token: token, layers: layers, radius: 220)
        do {
            for try await message in client.referenceMessages(request) {
                try Task.checkCancellation()
                guard layers.contains(message.layer) else { continue }
                if !message.modelID.isEmpty { modelIDs.insert(message.modelID) }
                guard modelIDs.count <= 1 else { throw Failure.mixedModels }
                if message.complete { completed.insert(message.layer) }
                switch message.chunk {
                case .lines(let layer, let lines):
                    vertexCount += lines.reduce(0) { $0 + $1.xyz.count / 3 }
                    guard vertexCount <= 250_000 else { throw Failure.tooLarge }
                    features += lines.filter { line in
                        line.xyz.count >= 6 && line.xyz.count.isMultiple(of: 3) && line.xyz.allSatisfy(\.isFinite)
                    }.map { Feature(layer: layer, line: $0) }
                case .groundMesh(let field):
                    guard field.nx > 0, field.ny > 0, field.nx <= 1000, field.ny <= 1000,
                        field.z.count == field.nx * field.ny, field.cellSize.isFinite, field.cellSize > 0,
                        field.origin.x.isFinite, field.origin.y.isFinite, field.origin.z.isFinite
                    else { throw Failure.tooLarge }
                    ground = field
                default: break
                }
            }
        } catch  where AlignClient.timedOut(error) {
            // The server went quiet past the time limit, usually while it builds the site's model; it carries on.
            throw Failure.stillBuilding
        }
        guard completed.isSuperset(of: layers) else { throw Failure.incomplete }
        guard !features.isEmpty || ground?.z.contains(where: \.isFinite) == true else { throw Failure.unavailable }
        // Derived box heights use 3DEP + DataSF; observed surfaces also use contributed scans.
        let sourceLayers = Set(layers + [.aerialPoints, .footprints])
        let attribution = site.sources.filter { sourceLayers.contains($0.layer) }.map {
            "\($0.attribution.isEmpty ? $0.name : $0.attribution) (\($0.licence))"
        }
        return VectorReference(
            site: site, features: features, ground: ground, modelID: modelIDs.first ?? "",
            layers: layers, attribution: Array(Set(attribution)).sorted())
    }
}
