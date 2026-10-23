import CanopyModel
import CryptoKit
import Foundation

/// Real tree candidates for an area: prepares the Gerardus site for an L16 tile (the tile and its 8 neighbours),
/// streams its 3DEP points, buildings and ground model, finds the trees and places them on the map.
public enum AerialTrees {
    /// The candidates found for one site.
    public struct SiteResult: Sendable {
        public var site: Site
        public var candidates: [TreeCandidate]
        /// The L16 tiles the site covers; candidates there can be replaced by `candidates`.
        public var tiles: Set<S2CellID>
        /// Who to credit, one line per source: "U.S. Geological Survey, 3D Elevation Program (public domain)".
        public var attribution: [String]
        public var pointCount: Int
    }

    public enum Stage: Sendable, Equatable {
        /// The server is building the site's bundle.
        case preparing(Progress)
        case downloading(points: Int)
        case detecting
        case placing
    }

    /// Classes that can be canopy in 3DEP: unclassified and the vegetation classes. Buildings (6), bridges (17),
    /// noise (7, 18), ground (2) and water (9) are left out.
    public static let canopyClasses: [UInt32] = [1, 3, 4, 5]

    public static func load(
        tile: S2CellID, label: String, client: AlignClient, voxelSize: Float = 1.0,
        detector: TreeDetector = TreeDetector(), progress: @Sendable (Stage) -> Void = { _ in }
    ) async throws -> SiteResult {
        let token = tile.parent(level: S2CellID.tileLevel).token
        let site: Site
        if let prepared = try await client.site(token) {
            site = prepared
        } else {
            site = try await client.preparedSite(token, label: label) { progress(.preparing($0)) }
        }

        var blocks: [PointBlock] = []
        var ground: Heightfield?
        var buildings: [[SIMD2<Double>]] = []
        var count = 0
        let request = StreamReferenceRequest(
            l16Token: token, layers: [.aerialPoints, .osm, .footprints, .groundMesh], voxelSize: voxelSize,
            aerialClasses: canopyClasses)
        for try await chunk in client.reference(request) {
            switch chunk {
            case .points(_, let block):
                blocks.append(block)
                count += block.count
                progress(.downloading(points: count))
            case .groundMesh(let field):
                ground = field
            case .lines(_, let lines):
                buildings += lines.filter { $0.kind == .building && $0.points.count >= 3 }.map(\.points)
            default:
                break
            }
        }
        if ground == nil {
            // Older servers have no ground layer: build one from the ground and water returns.
            var groundBlocks: [PointBlock] = []
            let groundRequest = StreamReferenceRequest(
                l16Token: token, layers: [.aerialPoints], voxelSize: voxelSize, aerialClasses: [2, 9])
            for try await chunk in client.reference(groundRequest) {
                if case .points(_, let block) = chunk { groundBlocks.append(block) }
            }
            ground = Heightfield(groundPoints: groundBlocks, cellSize: 1)
        }
        guard let ground else { throw GRPCTransportError.noResponse }

        progress(.detecting)
        let trees = detector.detect(points: blocks, ground: ground, buildings: buildings)
        progress(.placing)
        let georeference = try await SiteGeoreference.fetch(for: site, client: client)
        let aerialSource = site.sources.first { $0.layer == .aerialPoints }
        let source = aerialSource.map { "\($0.name) (\($0.licence))" } ?? "Gerardus aerial points"
        // The bundle is the bounding box of its 9 tiles, which reaches past them; a site answers for its tiles only, so
        // loading the neighbouring site later neither duplicates nor drops a tree.
        let tiles = Set(site.coveringL16Tokens.compactMap(S2CellID.init(token:)))
        return SiteResult(
            site: site,
            candidates: candidates(trees, georeference: georeference, source: source).filter {
                tiles.contains($0.location.tile)
            },
            tiles: tiles,
            attribution: site.sources.map { source in
                let licence = source.licence == "public-domain" ? "public domain" : source.licence
                return "\(source.attribution.isEmpty ? source.name : source.attribution) (\(licence))"
            },
            pointCount: count
        )
    }

    /// Detected trees as candidates. Ids come from the position (rounded to about a metre), so finding the same tree
    /// again gives the same id.
    public static func candidates(
        _ trees: [TreeDetector.Tree], georeference: SiteGeoreference, source: String
    ) -> [TreeCandidate] {
        trees.map { tree in
            let location = georeference.geo(x: tree.x, y: tree.y)
            return TreeCandidate(
                id: stableID(location), location: location, height: (tree.height * 10).rounded() / 10,
                crownRadius: (tree.crownRadius * 10).rounded() / 10, confidence: tree.confidence, isSynthetic: false,
                source: source)
        }
    }

    /// A UUID derived from a position rounded to 1e-5 degrees.
    public static func stableID(_ point: GeoPoint) -> UUID {
        let key = String(format: "canopy.aerial:%.5f,%.5f", point.latitude, point.longitude)
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80  // version 8: application-defined
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 9562 variant
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
                bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}

extension Heightfield {
    /// A ground model from ground (and water) returns: the lowest return per cell, with empty cells filled from their
    /// filled neighbours, ring by ring, up to `maxFill` rings. Cells further than that from any return stay NaN.
    public init?(groundPoints blocks: [PointBlock], cellSize: Double, maxFill: Int = 10) {
        var minX = Float.infinity
        var minY = Float.infinity
        var maxX = -Float.infinity
        var maxY = -Float.infinity
        for block in blocks {
            for k in 0..<block.count {
                minX = min(minX, block.x[k])
                minY = min(minY, block.y[k])
                maxX = max(maxX, block.x[k])
                maxY = max(maxY, block.y[k])
            }
        }
        guard minX.isFinite, maxX > minX, maxY > minY else { return nil }
        let nx = Int((Double(maxX - minX) / cellSize).rounded(.down)) + 1
        let ny = Int((Double(maxY - minY) / cellSize).rounded(.down)) + 1
        var z = [Float](repeating: .nan, count: nx * ny)
        for block in blocks {
            for k in 0..<block.count {
                let i = Int(Double(block.x[k] - minX) / cellSize)
                let j = Int(Double(block.y[k] - minY) / cellSize)
                let index = j * nx + i
                if z[index].isNaN || block.z[k] < z[index] { z[index] = block.z[k] }
            }
        }
        for _ in 0..<maxFill {
            var next = z
            var changed = false
            for j in 0..<ny {
                for i in 0..<nx where z[j * nx + i].isNaN {
                    var sum: Float = 0
                    var n: Float = 0
                    for dj in -1...1 {
                        for di in -1...1 {
                            let ii = i + di
                            let jj = j + dj
                            guard ii >= 0, jj >= 0, ii < nx, jj < ny else { continue }
                            let v = z[jj * nx + ii]
                            if v.isFinite {
                                sum += v
                                n += 1
                            }
                        }
                    }
                    if n > 0 {
                        next[j * nx + i] = sum / n
                        changed = true
                    }
                }
            }
            z = next
            if !changed { break }
        }
        // Cell centres: the grid starts half a cell in from the lowest return.
        self.init(
            origin: Vector3(x: Double(minX) + cellSize / 2, y: Double(minY) + cellSize / 2, z: 0), cellSize: cellSize,
            nx: nx, ny: ny, z: z)
    }
}
