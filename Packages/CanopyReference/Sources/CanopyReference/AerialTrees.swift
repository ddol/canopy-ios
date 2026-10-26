import CanopyModel
import CryptoKit
import Foundation

/// Real tree candidates for an area: prepares the Gerardus site for an L16 tile (the tile and its 8 neighbours),
/// streams its 3DEP points, buildings and ground model, finds the trees and places them on the map.
public enum AerialTrees {
    /// A circle on the ground: the part of a site to load.
    public struct Area: Equatable, Sendable {
        public var centre: GeoPoint
        /// Metres.
        public var radius: Double

        public init(centre: GeoPoint, radius: Double) {
            self.centre = centre
            self.radius = radius
        }

        public func contains(_ point: GeoPoint) -> Bool {
            LocalFrame(origin: centre).enu(of: point).horizontalDistance <= radius
        }
    }

    /// The candidates found for one site, or the part of it in an area.
    public struct SiteResult: Sendable {
        public var site: Site
        public var candidates: [TreeCandidate]
        /// The L16 tiles the site covers.
        public var tiles: Set<S2CellID>
        /// The part of the site that was loaded; nil: all of it.
        public var area: Area?
        /// Who to credit, one line per source that was used: "U.S. Geological Survey, 3D Elevation Program (public
        /// domain)".
        public var attribution: [String]
        public var pointCount: Int
        /// For drawing the data itself: the site's georeference, the raw canopy height model, and the outlines and
        /// lines streamed with the points (DataSF footprints, and OpenStreetMap when it was asked for).
        public var georeference: SiteGeoreference?
        public var canopy: TreeDetector.CanopyHeightModel?
        public var lines: [LineFeature]
        /// OpenStreetMap was asked for and the server sent it; the candidates are then for checking only.
        public var usedOSM: Bool
        /// OpenStreetMap was asked for and the server refused: it sends OSM only to its admins.
        public var osmRefused: Bool
        /// The points came from the phone's cache rather than the server.
        public var fromCache = false
        /// How long each step took, in order: finding the site, its georeference, the points, detection, placing.
        public var timings: [Timing] = []

        public struct Timing: Equatable, Sendable {
            public var step: String
            public var seconds: Double

            public init(step: String, seconds: Double) {
                self.step = step
                self.seconds = seconds
            }
        }

        public init(
            site: Site, candidates: [TreeCandidate], tiles: Set<S2CellID>, area: Area? = nil, attribution: [String],
            pointCount: Int, georeference: SiteGeoreference? = nil, canopy: TreeDetector.CanopyHeightModel? = nil,
            lines: [LineFeature] = [], usedOSM: Bool = false, osmRefused: Bool = false
        ) {
            self.site = site
            self.candidates = candidates
            self.tiles = tiles
            self.area = area
            self.attribution = attribution
            self.pointCount = pointCount
            self.georeference = georeference
            self.canopy = canopy
            self.lines = lines
            self.usedOSM = usedOSM
            self.osmRefused = osmRefused
        }

        /// Whether the result answers for a point: in the site's tiles and the area. Candidates there can be
        /// replaced by `candidates`.
        public func covers(_ point: GeoPoint) -> Bool {
            tiles.contains(point.tile) && area?.contains(point) != false
        }
    }

    public enum Stage: Sendable, Equatable {
        /// The server is building the site's bundle.
        case preparing(Progress)
        case downloading(points: Int)
        /// Reading points kept on the phone from an earlier load.
        case readingSaved(points: Int)
        case detecting
        case placing
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// Preparing the site ran past its time limit. The server carries on, so the site is usually ready soon.
        case stillPreparing
        /// The site was prepared without aerial points: the server has no 3DEP data there.
        case noAerialData
        /// The stream went quiet past its time limit. After being idle, or after accepting a scan, the server builds
        /// the site's model on first asking and carries on, so asking again shortly usually works.
        case slowServer

        public var errorDescription: String? {
            switch self {
            case .stillPreparing: "The server is still preparing this area. Try again in a minute."
            case .noAerialData: "The server has no aerial LiDAR for this area, so there are no trees to find here."
            case .slowServer:
                "The server took too long to send this area. After being idle it builds the site first, which can "
                    + "take a minute or two. Try again shortly."
            }
        }
    }

    /// Classes that can be canopy in 3DEP: unclassified and the vegetation classes. Buildings (6), bridges (17),
    /// noise (7, 18), ground (2) and water (9) are left out.
    public static let canopyClasses: [UInt32] = [1, 3, 4, 5]

    /// How far past an area points are streamed, in metres, so the crowns of trees on its edge are whole.
    public static let areaMargin = 20.0

    /// How much wider than asked an area's points are downloaded and kept, in metres, so loading again after the map
    /// has moved a little (a zoom, a nudge) finds them on the phone. About an eighth more to download.
    public static let cachePadding: Float = 10

    /// Finds the trees in the site for `tile`, or only in `area` (which should be centred in `tile`), so less data
    /// comes down. Buildings are masked out of detection with DataSF footprints. `osm` adds OpenStreetMap buildings:
    /// for checking only, since the shared tree layer takes nothing from OpenStreetMap (Gerardus ADR-0005, ADR-0008),
    /// and the candidates' source says so.
    ///
    /// With a `cache`, an area inside one loaded before from the same bundle costs one small call (or none, when the
    /// server cannot be reached) instead of megabytes, and the site georeference is fitted once.
    public static func load(
        tile: S2CellID, area: Area? = nil, osm: Bool = false, label: String, client: AlignClient,
        cache: ReferenceCache? = nil, voxelSize: Float = 1.0, detector: TreeDetector = TreeDetector(),
        progress: @Sendable (Stage) -> Void = { _ in }
    ) async throws -> SiteResult {
        let token = tile.parent(level: S2CellID.tileLevel).token
        var timings: [SiteResult.Timing] = []
        var lap = ContinuousClock.now
        func time(_ step: String) {
            let now = ContinuousClock.now
            let elapsed = (now - lap).components
            timings.append(.init(step: step, seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18))
            lap = now
        }
        let site: Site
        if let prepared = try await client.site(token, cache: cache) {
            site = prepared
        } else {
            do {
                site = try await client.preparedSite(token, label: label) { progress(.preparing($0)) }
            } catch GRPCTransportError.timedOut {
                throw Failure.stillPreparing
            }
        }
        // A server without 3DEP for the area prepares the site anyway, empty: say so rather than fail to place it.
        guard
            site.layerCounts[.aerialPoints, default: 0] > 0
                || site.sources.contains(where: { $0.layer == .aerialPoints })
        else { throw Failure.noAerialData }
        time("site")
        let georeference = try await SiteGeoreference.fetch(for: site, client: client, cache: cache)
        time("georeference")
        let centre = area.map { georeference.site(of: $0.centre) }
        func request(_ layers: [ReferenceLayer], classes: [UInt32]) -> StreamReferenceRequest {
            StreamReferenceRequest(
                l16Token: token, layers: layers, centre: centre.map { Vector3(x: $0.x, y: $0.y, z: 0) },
                radius: area.map { Float($0.radius + areaMargin) } ?? 0, voxelSize: voxelSize, aerialClasses: classes)
        }

        var blocks: [PointBlock] = []
        var ground: Heightfield?
        var lines: [LineFeature] = []
        var count = 0
        var layers: [ReferenceLayer] = [.aerialPoints, .footprints, .groundMesh]
        let saved = Flag()
        let stream = client.reference(
            request(layers, classes: canopyClasses), bundleID: site.bundleID, cache: cache, padding: cachePadding,
            fromCache: saved.set)
        do {
            for try await chunk in stream {
                switch chunk {
                case .points(_, let block):
                    blocks.append(block)
                    count += block.count
                    progress(saved.value ? .readingSaved(points: count) : .downloading(points: count))
                case .groundMesh(let field):
                    ground = field
                case .lines(_, let more):
                    lines += more
                default:
                    break
                }
            }
        } catch  where AlignClient.timedOut(error) {
            // The server went quiet past the time limit, usually while it derives the site's ground model.
            throw Failure.slowServer
        }
        // OpenStreetMap on its own call: the server refuses a whole stream that names it for anyone but its admins, and
        // detection must work either way.
        var osmRefused = false
        if osm {
            do {
                for try await chunk in client.reference(
                    request([.osm], classes: []), bundleID: site.bundleID, cache: cache)
                {
                    if case .lines(_, let more) = chunk { lines += more }
                }
                layers.append(.osm)
            } catch let error as GRPCStatusError where error.code == GRPCStatusError.permissionDenied {
                osmRefused = true
            }
        }
        let usedOSM = layers.contains(.osm)
        if ground == nil {
            // Older servers have no ground layer: build one from the ground and water returns.
            var groundBlocks: [PointBlock] = []
            for try await chunk in client.reference(
                request([.aerialPoints], classes: [2, 9]), bundleID: site.bundleID, cache: cache)
            {
                if case .points(_, let block) = chunk { groundBlocks.append(block) }
            }
            ground = Heightfield(groundPoints: groundBlocks, cellSize: 1)
        }
        guard let ground else { throw GRPCTransportError.noResponse }

        time("points")
        progress(.detecting)
        let buildings = lines.filter { $0.kind == .building && $0.points.count >= 3 }.map(\.points)
        let (trees, canopy) = detector.detectWithCanopy(points: blocks, ground: ground, buildings: buildings)
        time("detection")
        progress(.placing)
        let aerialSource = site.sources.first { $0.layer == .aerialPoints }
        let source =
            (aerialSource.map { "\($0.name) (\($0.licence))" } ?? "Gerardus aerial points")
            + (usedOSM ? "; buildings masked with OpenStreetMap, for checking only" : "")
        // The bundle is the bounding box of its 9 tiles, which reaches past them; a site answers for its tiles only, so
        // loading the neighbouring site later neither duplicates nor drops a tree.
        var result = SiteResult(
            site: site, candidates: [], tiles: Set(site.coveringL16Tokens.compactMap(S2CellID.init(token:))),
            area: area,
            attribution: site.sources.filter { layers.contains($0.layer) }.map { source in
                let licence = source.licence == "public-domain" ? "public domain" : source.licence
                return "\(source.attribution.isEmpty ? source.name : source.attribution) (\(licence))"
            },
            pointCount: count,
            georeference: georeference,
            canopy: canopy,
            lines: lines,
            usedOSM: usedOSM,
            osmRefused: osmRefused
        )
        result.fromCache = saved.value
        result.candidates = candidates(trees, georeference: georeference, source: source).filter {
            result.covers($0.location)
        }
        time("placing")
        result.timings = timings
        return result
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

/// A flag set from another task.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool { lock.withLock { stored } }

    @Sendable func set(_ value: Bool) { lock.withLock { stored = value } }
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
