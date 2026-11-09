import CanopyModel
import CanopyReference
import Foundation

/// Just enough of the map service (`gerardus.map.v1alpha1`) for the app to sync with the stand-in: it keeps
/// submitted changesets (pending; nobody else is there to agree), counts imported trees, and has a shared map that is
/// empty or, for measuring the app with a city's worth of trees, a `SharedCity`. Field numbers follow `MapClient.swift`.
public final class StandInMap: @unchecked Sendable {
    private let lock = NSLock()
    private var changesets: [String: Data] = [:]
    private var trees: Set<String> = []
    private let city: SharedCity?

    public init(city: SharedCity? = nil) {
        self.city = city
    }

    public func answer(_ path: String, _ request: [UInt8]) -> GRPCReply {
        let fields = (try? ProtoReader.fields(ArraySlice(request))) ?? []
        let method = path.split(separator: "/").last.map(String.init) ?? path
        var w = ProtoWriter()
        switch method {
        case "SubmitChangeset":
            guard let changeset = fields.first(where: { $0.number == 1 }) else {
                return .status(3, "changeset is required")
            }
            let bytes = Data(changeset.bytes)
            let id = (try? ProtoReader.fields(changeset.bytes))?.first { $0.number == 1 }?.string ?? UUID().uuidString
            lock.withLock { changesets[id] = bytes }
            w.bytes(1, bytes)
        case "GetChangesets":
            let known = lock.withLock { changesets }
            for f in fields where f.number == 1 {
                if let bytes = known[f.string] { w.bytes(1, bytes) }
            }
        case "UploadBlob", "ListOpenChangesets":
            // Nothing pending.
            break
        case "GetTileSummaries":
            // Tiles with nothing in them are left out, as the server leaves them out.
            for f in fields where f.number == 1 {
                guard let city, let tile = S2CellID(token: f.string), city.tiles.contains(tile) else { continue }
                w.message(1) { summary in
                    summary.string(1, f.string)
                    summary.uint(2, UInt64(city.perTile))
                    summary.uint(8, SharedCity.sequence)
                    summary.message(10) { Self.timestamp(&$0, SharedCity.detectedAt) }
                }
            }
        case "GetPlayer":
            w.message(1) { p in
                p.string(1, "stand-in")
                p.string(2, "Player")
            }
        case "GetTile":
            let token = fields.first { $0.number == 1 }?.string ?? ""
            let trees = S2CellID(token: token).flatMap { city?.trees(in: $0) }
            for tree in trees ?? [] {
                w.message(1) { entity in
                    entity.enumValue(1, 1)
                    entity.string(2, tree.id.uuidString.lowercased())
                    entity.uint(3, 1)
                    entity.string(4, tree.fields)
                    entity.string(5, token)
                    entity.string(6, SharedCity.author)
                    entity.message(7) { Self.timestamp(&$0, SharedCity.detectedAt) }
                }
            }
            w.uint(2, trees == nil ? 0 : SharedCity.sequence)
        case "PullChanges":
            w.uint(2, fields.first { $0.number == 2 }?.uint ?? 0)
        case "ImportDetectedTrees":
            let ids = fields.filter { $0.number == 1 }.compactMap { f in
                (try? ProtoReader.fields(f.bytes))?.first { $0.number == 1 }?.string
            }
            let created = lock.withLock { ids.filter { trees.insert($0).inserted }.count }
            w.uint(2, UInt64(created))
            w.uint(3, UInt64(ids.count - created))
        default:
            return .status(GRPCStatusError.unimplemented, "\(method) is not implemented by the stand-in")
        }
        return .messages([w.data])
    }
}

extension StandInMap {
    static func timestamp(_ w: inout ProtoWriter, _ date: Date) {
        w.uint(1, UInt64(date.timeIntervalSince1970))
    }
}

/// A shared map with trees on it already, as the live server has after a park-wide detection: `count` detected trees
/// spread evenly over the level-16 tiles of a region (Golden Gate Park by default), every tile detected in full. Each
/// tile's trees are made the first time it is asked about, always the same for the same tile.
public final class SharedCity: @unchecked Sendable {
    public struct Tree: Sendable {
        public var id: UUID
        /// The entity's fields as the server sends them: CanopyModel's JSON, without the meta.
        public var fields: String
    }

    static let sequence: UInt64 = 1
    static let author = "gerardus:detector"
    static let detectedAt = Date(timeIntervalSince1970: 1_790_000_000)

    /// The region's level-16 tiles.
    public let tiles: Set<S2CellID>
    public let perTile: Int
    private let lock = NSLock()
    private var made: [S2CellID: [Tree]] = [:]

    public init(count: Int, region: (south: Double, west: Double, north: Double, east: Double) = SharedCity.park) {
        var tiles: Set<S2CellID> = []
        let step = 30.0
        let latitudeStep = step / 110_574
        let longitudeStep = step / (111_320 * cos((region.south + region.north) / 2 * .pi / 180))
        var latitude = region.south
        while latitude <= region.north {
            var longitude = region.west
            while longitude <= region.east {
                tiles.insert(GeoPoint(latitude: latitude, longitude: longitude).tile)
                longitude += longitudeStep
            }
            latitude += latitudeStep
        }
        self.tiles = tiles
        perTile = max(1, Int((Double(count) / Double(max(tiles.count, 1))).rounded(.up)))
    }

    /// Golden Gate Park's bounding box, Panhandle included.
    public static let park = (south: 37.7646, west: -122.5110, north: 37.7742, east: -122.4430)

    public var count: Int { tiles.count * perTile }

    /// A tile's trees, or nil for a tile outside the region.
    public func trees(in tile: S2CellID) -> [Tree]? {
        guard tiles.contains(tile) else { return nil }
        if let trees = lock.withLock({ made[tile] }) { return trees }
        let trees = Self.make(perTile, in: tile)
        lock.withLock { made[tile] = trees }
        return trees
    }

    /// `count` trees at places in the tile from a generator seeded by the tile, so a tile always has the same ones.
    static func make(_ count: Int, in tile: S2CellID) -> [Tree] {
        var random = SeededRandom(seed: tile.rawValue)
        let corners = tile.vertices
        let south = corners.map(\.latitude).min()!
        let north = corners.map(\.latitude).max()!
        let west = corners.map(\.longitude).min()!
        let east = corners.map(\.longitude).max()!
        var trees: [Tree] = []
        while trees.count < count {
            let point = GeoPoint(
                latitude: south + (north - south) * random.unit(), longitude: west + (east - west) * random.unit())
            guard point.tile == tile else { continue }
            let (high, low) = (random.next(), random.next())
            var uuid = UUID().uuid
            withUnsafeMutableBytes(of: &uuid) { raw in
                raw.storeBytes(of: high, toByteOffset: 0, as: UInt64.self)
                raw.storeBytes(of: low, toByteOffset: 8, as: UInt64.self)
            }
            let id = UUID(uuid: uuid)
            let tree = TreeCandidate(
                id: id, location: point, height: 6 + 20 * random.unit(), crownRadius: 2 + 4 * random.unit(),
                confidence: 0.8, isSynthetic: false
            ).makeTree()
            var fields = (try? JSONValue(encoding: tree).objectValue) ?? [:]
            fields["meta"] = nil
            fields["proposedStatus"] = nil
            fields["s2_l19_token"] = .string(tree.position.chunk.token)
            let json = (try? CanopyJSON.encoder.encode(JSONValue.object(fields))) ?? Data("{}".utf8)
            trees.append(Tree(id: id, fields: String(decoding: json, as: UTF8.self)))
        }
        return trees
    }
}

/// SplitMix64: small, fast and the same everywhere.
struct SeededRandom {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

extension StandInServer {
    /// A server answering the align service for a synthetic site and the map service in memory, as `canopy-harness
    /// serve` runs it for the app.
    public convenience init(align: StandInAlign, map: StandInMap, profile: NetworkProfile = .loopback) {
        self.init(profile: profile) { path, request in
            path.contains("gerardus.map.") ? map.answer(path, request) : align.answer(path, request)
        }
    }

    /// The status page (`GET /`) a Gerardus server answers, which the app's connection test reads.
    static func statusPage(started: Date) -> Data {
        let page: [String: Any] = [
            "status": "ok", "service": "gerardus", "server_version": "canopy-harness",
            "api_version": "gerardus.align.v1alpha1", "started_at": ISO8601DateFormatter().string(from: started),
            "uptime_s": Int(Date().timeIntervalSince(started)), "available_layers": ["aerial", "footprints", "ground"],
        ]
        return (try? JSONSerialization.data(withJSONObject: page, options: [.sortedKeys])) ?? Data()
    }
}
