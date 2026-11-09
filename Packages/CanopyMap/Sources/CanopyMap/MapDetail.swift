import CanopyModel
import Foundation

/// How much of the map is drawn in full. A park-wide view holds thousands of trees and every loaded site's vectors,
/// and drawing them all stalls either renderer, so only the level-16 tiles nearest the centre are drawn in full
/// (trees, tags, Gerardus's vectors), and only while the view is close enough to read them. Every other tile with
/// something in it is drawn as one patch, coloured by how many trees it holds (`TileSummary`), so the map still shows
/// where the trees are and which tiles hold any.
public struct MapDetail: Equatable, Sendable {
    /// At most this many level-16 tiles are drawn in full: the ones nearest the centre.
    public static let detailedTileLimit = 16
    /// With more level-16 tiles than this in view, none is drawn in full.
    public static let tilesInViewLimit = 36
    /// With more level-16 tiles than this in view, the patches are whole level-13 cells (64 tiles each), so a city-wide
    /// view draws dozens of patches rather than thousands.
    public static let level16SummaryLimit = 800

    /// The level-16 tiles drawn in full; nil when everything is (no region known).
    public let detailed: Set<S2CellID>?
    /// About how many level-16 tiles the region spans.
    public let tilesInView: Int
    /// The level of the summary patches: 16, or 13 for a region spanning more than `level16SummaryLimit` tiles.
    public let summaryLevel: Int

    /// Everything in full, as when no region is known.
    public static let everything = MapDetail(detailed: nil, tilesInView: 0, summaryLevel: S2CellID.tileLevel)

    public init(detailed: Set<S2CellID>?, tilesInView: Int, summaryLevel: Int) {
        self.detailed = detailed
        self.tilesInView = tilesInView
        self.summaryLevel = summaryLevel
    }

    /// The detail for a region: the tiles it spans, counted exactly while there are few enough to matter, and the
    /// nearest `detailedTileLimit` of them drawn in full when there are no more than `tilesInViewLimit`.
    public init(region: MapViewport) {
        let edge = Self.tileEdge(at: region.center)
        let estimate = Int((region.widthMetres * region.heightMetres / (edge * edge)).rounded(.up))
        guard estimate <= Self.tilesInViewLimit * 3 else {
            self.init(
                detailed: [], tilesInView: estimate,
                summaryLevel: estimate > Self.level16SummaryLimit ? 13 : S2CellID.tileLevel)
            return
        }
        let tiles = Self.tiles(in: region, step: edge / 3)
        let nearest = tiles.sorted { a, b in
            let da = region.squaredDistance(to: a.center)
            let db = region.squaredDistance(to: b.center)
            return da != db ? da < db : a < b
        }
        self.init(
            detailed: tiles.count <= Self.tilesInViewLimit ? Set(nearest.prefix(Self.detailedTileLimit)) : [],
            tilesInView: tiles.count, summaryLevel: S2CellID.tileLevel)
    }

    /// Whether a level-16 tile is drawn in full.
    public func isDetailed(_ tile: S2CellID) -> Bool {
        detailed?.contains(tile) ?? true
    }

    /// Whether anything at all is drawn in full.
    public var drawsAnyDetail: Bool { detailed.map { !$0.isEmpty } ?? true }

    /// The square root of a level-16 tile's area where `point` is, in metres: tiles vary a little in size and shape
    /// across the globe, so the count of tiles in view is worked out from the tile under the centre.
    static func tileEdge(at point: GeoPoint) -> Double {
        let tile = point.tile
        let frame = LocalFrame(origin: tile.center)
        let corners = tile.vertices.map { frame.enu(of: $0) }
        var twice = 0.0
        for (a, b) in zip(corners, corners.dropFirst() + corners.prefix(1)) {
            twice += a.east * b.north - b.east * a.north
        }
        return max(abs(twice / 2), 1).squareRoot()
    }

    /// The level-16 tiles a region touches, from a grid of points `step` metres apart across it, edges included.
    static func tiles(in region: MapViewport, step: Double) -> Set<S2CellID> {
        cells(in: region, level: S2CellID.tileLevel, step: step)
    }

    /// The cells of a level a region touches, from a grid of points `step` metres apart across it, edges included:
    /// a step well under the cell's size finds them all.
    public static func cells(in region: MapViewport, level: Int, step: Double) -> Set<S2CellID> {
        let columns = max(1, Int((region.widthMetres / step).rounded(.up)))
        let rows = max(1, Int((region.heightMetres / step).rounded(.up)))
        var tiles: Set<S2CellID> = []
        for row in 0...rows {
            for column in 0...columns {
                let point = GeoPoint(
                    latitude: region.center.latitude + (Double(row) / Double(rows) - 0.5) * region.latitudeDelta,
                    longitude: region.center.longitude + (Double(column) / Double(columns) - 0.5)
                        * region.longitudeDelta)
                tiles.insert(S2CellID(point, level: level))
            }
        }
        return tiles
    }
}

/// One patch on the map standing for a tile (level 16) or cell (level 13) that is not drawn in full: how many trees it
/// holds, by what players have done with them, and how many hazard tags.
public struct TileSummary: Identifiable, Hashable, Sendable {
    public var id: S2CellID
    public var corners: [GeoPoint]
    /// Trees no one has acted on.
    public var detected: Int
    /// Trees proposed, confirmed or verified.
    public var reviewed: Int
    public var tags: Int
    /// Whether the player marked the tile surveyed (for a level-13 cell: every tile in it with trees).
    public var surveyed: Bool
    /// Whether the tile's trees were detected over the whole tile (`AppModel.detectedTiles`; for a level-13 cell: every
    /// tile in it with trees), so the map marks it apart from tiles detected in part or not at all.
    public var detectedInFull: Bool
    public var areaHectares: Double

    /// Trees per hectare that colour a patch fully: denser woodland than that reads the same.
    public static let fullDensity = 120.0

    public init(
        id: S2CellID, corners: [GeoPoint]? = nil, detected: Int = 0, reviewed: Int = 0, tags: Int = 0,
        surveyed: Bool = false, detectedInFull: Bool = false, areaHectares: Double? = nil
    ) {
        self.id = id
        self.corners = corners ?? id.vertices
        self.detected = detected
        self.reviewed = reviewed
        self.tags = tags
        self.surveyed = surveyed
        self.detectedInFull = detectedInFull
        self.areaHectares = areaHectares ?? Self.area(of: self.corners) / 10_000
    }

    public var trees: Int { detected + reviewed }

    /// From 0 (empty) to 1 (`fullDensity` trees per hectare or more), on a square-root scale so sparse tiles still
    /// show. The same on every tile and at either level, so a patch reads the same wherever the map is.
    public var density: Double {
        guard areaHectares > 0, trees > 0 else { return 0 }
        return min(1, (Double(trees) / areaHectares / Self.fullDensity).squareRoot())
    }

    /// A ring's area in square metres, about its first corner.
    static func area(of corners: [GeoPoint]) -> Double {
        guard let first = corners.first, corners.count >= 3 else { return 0 }
        let frame = LocalFrame(origin: first)
        let points = corners.map { frame.enu(of: $0) }
        var twice = 0.0
        for (a, b) in zip(points, points.dropFirst() + points.prefix(1)) {
            twice += a.east * b.north - b.east * a.north
        }
        return abs(twice / 2)
    }
}

/// The census's trees by level-16 tile, and how many of each status every tile holds. Placing a point in its tile takes
/// a little trigonometry, and a city's worth of trees is tens of thousands; the map is drawn far more often than the
/// census changes, so the app makes this once per census, off the main actor, and the map reuses it: a tile not drawn
/// in full is shaded from its counts without looking at its trees.
public struct CensusTiles: Sendable {
    public let trees: [S2CellID: [UUID]]
    /// Per tile, its trees by the status the map draws them in (`Tree.displayStatus`).
    public let counts: [S2CellID: StatusCounts]
    /// The whole census by that status.
    public let total: StatusCounts

    public init(_ state: CensusState) {
        var trees: [S2CellID: [UUID]] = [:]
        var counts: [S2CellID: StatusCounts] = [:]
        var total = StatusCounts()
        for tree in state.trees.values {
            let tile = tree.position.tile
            trees[tile, default: []].append(tree.id)
            counts[tile, default: StatusCounts()][tree.displayStatus] += 1
            total[tree.displayStatus] += 1
        }
        self.trees = trees
        self.counts = counts
        self.total = total
    }
}

/// How many trees have each status.
public struct StatusCounts: Equatable, Sendable {
    public var detected = 0
    public var proposed = 0
    public var confirmed = 0
    public var verified = 0
    public var removed = 0

    public init() {}

    public subscript(status: CountStatus) -> Int {
        get {
            switch status {
            case .detected: detected
            case .proposed: proposed
            case .confirmed: confirmed
            case .verified: verified
            case .removed: removed
            }
        }
        set {
            switch status {
            case .detected: detected = newValue
            case .proposed: proposed = newValue
            case .confirmed: confirmed = newValue
            case .verified: verified = newValue
            case .removed: removed = newValue
            }
        }
    }

    /// The trees with any of `statuses`.
    public func count(of statuses: Set<CountStatus>) -> Int {
        statuses.reduce(0) { $0 + self[$1] }
    }
}

extension MapViewport {
    /// East to west across the region at its centre, in metres.
    public var widthMetres: Double { longitudeDelta * 111_320 * cos(center.latitude * .pi / 180) }
    /// South to north, in metres.
    public var heightMetres: Double { latitudeDelta * 110_574 }

    /// A region round an S2 cell: the cell with `margin` times its size about it, so tapping a patch zooms to where
    /// that tile is drawn in full.
    public init(around cell: S2CellID, margin: Double = 2.5) {
        let edge = TileSummary.area(of: cell.vertices).squareRoot()
        self.init(center: cell.center, radius: max(edge, 1) * margin / 2)
    }
}
