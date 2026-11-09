import CanopyCapture
import CanopyModel
import CanopyReference
import Foundation

/// Everything the map draws, as plain values. Renderers turn this into map content; it knows nothing about
/// MapKit, so a MapLibre renderer can draw the same layers.
public struct MapLayers: Equatable, Sendable {
    public struct Visibility: Equatable, Sendable {
        /// The statuses a tree can have on the map; removed trees are never drawn.
        public static let treeStatuses: [CountStatus] = [.detected, .proposed, .confirmed, .verified]

        /// Which trees to draw, by `Tree.displayStatus`.
        public var statuses: Set<CountStatus>
        public var tags = true
        public var routes = true
        /// S2 cell outlines: the level-16 tiles with trees or marked surveyed, and their level-13 parents.
        public var tiles = false
        /// Gerardus's vectors (building outlines and walls, streets, kerbs, Gerardus's trees) over the base map, and
        /// the loaded sites on the 3D map. Off unless the player turns them on: the map is for the census's trees.
        public var vectors = false
        /// The loaded sites' ground, on the 3D map.
        public var ground = true

        public init(
            statuses: Set<CountStatus> = Set(treeStatuses), tags: Bool = true, routes: Bool = true, tiles: Bool = false,
            vectors: Bool = false, ground: Bool = true
        ) {
            self.statuses = statuses
            self.tags = tags
            self.routes = routes
            self.tiles = tiles
            self.vectors = vectors
            self.ground = ground
        }
    }

    public struct TreeMarker: Identifiable, Hashable, Sendable {
        public var id: UUID
        public var location: GeoPoint
        /// The status to draw (`Tree.displayStatus`).
        public var status: CountStatus
        public var hazardCount: Int
        /// Measured trunk diameter and height, in metres, for the wireframe map's figures.
        public var dbh: Double?
        public var height: Double?
        public var lean: Lean?
        /// A detection in a cell the player has marked as surveyed: looked over without a verdict, drawn faint.
        public var inSurveyedCell = false

        public init(
            id: UUID, location: GeoPoint, status: CountStatus, hazardCount: Int, dbh: Double? = nil,
            height: Double? = nil, lean: Lean? = nil, inSurveyedCell: Bool = false
        ) {
            self.id = id
            self.location = location
            self.status = status
            self.hazardCount = hazardCount
            self.dbh = dbh
            self.height = height
            self.lean = lean
            self.inSurveyedCell = inSurveyedCell
        }

        public var symbol: TreeSymbol { TreeSymbol(status) }
    }

    public struct TagMarker: Identifiable, Hashable, Sendable {
        public var id: UUID
        public var treeID: UUID
        public var location: GeoPoint
        public var urgency: Tag.Urgency
    }

    public struct RouteLine: Identifiable, Hashable, Sendable {
        public var id: UUID
        public var name: String
        public var points: [GeoPoint]
    }

    /// An S2 cell's outline: a level-16 tile, or a level-13 cell (the server's unit) round the tiles.
    public struct TileOutline: Identifiable, Hashable, Sendable {
        public var id: S2CellID
        public var corners: [GeoPoint]
        /// Whether the player has marked the cell as surveyed (level-16 cells only).
        public var surveyed: Bool

        public init(id: S2CellID, corners: [GeoPoint]? = nil, surveyed: Bool = false) {
            self.id = id
            self.corners = corners ?? id.vertices
            self.surveyed = surveyed
        }

        public var level: Int { id.level }
    }

    /// Gerardus's own data for the areas loaded: canopy heights from the aerial point cloud, and vectors (outlines,
    /// walls, streets, trees) and the sites themselves. `WireframeRenderer` draws the sites in 3D in place of a base map; `MapKitRenderer` draws the vectors over
    /// Apple's. A class, so comparing layers does not compare every height.
    public final class Reference: Equatable, Sendable {
        public enum LineKind: Sendable {
            /// A building outline or part, closed.
            case building
            /// A wall seen from above: a box wall or a measured facade plane.
            case wall
            case road
            case path
            case kerb
            /// A street surface, closed: a driveway, parking space or marked area.
            case surface
            /// A tree's crown seen from above (Gerardus's TREES layer), closed.
            case tree
            case other
        }

        public struct Line: Sendable {
            public var kind: LineKind
            public var points: [GeoPoint]
            public var closed: Bool
            /// The level-16 tile the line starts in, so a map drawing only some tiles in full can leave it out.
            public var tile: S2CellID?

            public init(kind: LineKind, points: [GeoPoint], closed: Bool) {
                self.kind = kind
                self.points = points
                self.closed = closed
                self.tile = points.first?.tile
            }
        }

        /// Canopy height above the ground on a north-up grid, row by row from the south-west, in metres.
        public struct Raster: Sendable {
            public var southWest: GeoPoint
            public var northEast: GeoPoint
            public var nx: Int
            public var ny: Int
            public var heights: [Float]

            public init(southWest: GeoPoint, northEast: GeoPoint, nx: Int, ny: Int, heights: [Float]) {
                self.southWest = southWest
                self.northEast = northEast
                self.nx = nx
                self.ny = ny
                self.heights = heights
            }
        }

        /// A loaded site's vectors as the server sent them, with the georeference that places them, for the
        /// wireframe map.
        public struct Site: Sendable {
            public var token: String
            public var vectors: VectorReference
            public var georeference: SiteGeoreference

            public init(token: String, vectors: VectorReference, georeference: SiteGeoreference) {
                self.token = token
                self.vectors = vectors
                self.georeference = georeference
            }
        }

        public let canopies: [Raster]
        public let lines: [Line]
        public let sites: [Site]

        public init(canopies: [Raster], lines: [Line], sites: [Site] = []) {
            self.canopies = canopies
            self.lines = lines
            self.sites = sites
        }

        /// Several loaded areas as one, or nil when there are none.
        public static func merged(_ references: [Reference]) -> Reference? {
            guard !references.isEmpty else { return nil }
            if references.count == 1 { return references[0] }
            return Reference(
                canopies: references.flatMap(\.canopies), lines: references.flatMap(\.lines),
                sites: references.flatMap(\.sites))
        }

        public static func == (lhs: Reference, rhs: Reference) -> Bool { lhs === rhs }
    }

    public var trees: [TreeMarker]
    public var tags: [TagMarker]
    public var routes: [RouteLine]
    public var tiles: [TileOutline]
    /// Park outline: outer rings of the boundary polygons.
    public var boundary: [[GeoPoint]]
    public var visibility: Visibility
    public var reference: Reference?
    /// Tree shapes the player adjusted by eye in AR, by wireframe id (`census:<uuid>` or a Gerardus feature id),
    /// so the wireframe map draws them the same.
    public var treeForms: [String: TreeForm]
    /// Profiles fitted ring by ring over scanned trunks in AR, by the same ids; drawn in place of a form.
    public var treeProfiles: [String: TreeProfile] = [:]
    /// Which level-16 tiles are drawn in full. Trees, tags and vectors are drawn only in those.
    public var detail = MapDetail.everything
    /// The tiles near the region not drawn in full that hold trees (or are marked surveyed), one patch each.
    public var summaries: [TileSummary] = []

    public init(
        trees: [TreeMarker] = [],
        tags: [TagMarker] = [],
        routes: [RouteLine] = [],
        tiles: [TileOutline] = [],
        boundary: [[GeoPoint]] = [],
        visibility: Visibility = Visibility(),
        reference: Reference? = nil,
        treeForms: [String: TreeForm] = [:]
    ) {
        self.trees = trees
        self.tags = tags
        self.routes = routes
        self.tiles = tiles
        self.boundary = boundary
        self.visibility = visibility
        self.reference = reference
        self.treeForms = treeForms
    }

    /// The wireframe id of a census tree, shared with the AR view's selection.
    public static func censusWireframeID(_ id: UUID) -> String { "census:" + id.uuidString }

    /// Builds the layers from the census. Removed trees are left out; tiles are the L16 tiles holding a tree or
    /// marked surveyed, with their L13 parents.
    ///
    /// Real aerial data gives thousands of detected trees, more than a map can draw. With a `region`, only the
    /// level-16 tiles nearest its centre are drawn in full (`MapDetail`): their trees, at most `detectedLimit`
    /// detected ones nearest the centre, and their tags. The player's own trees (`own`: those they added, measured or
    /// confirmed) are drawn wherever they are near the region, at most `ownLimit` of them outside the tiles drawn in
    /// full. The other tiles near the region that hold trees become `summaries`, shaded from the trees they hold by
    /// status (`CensusTiles.counts`) without looking at the trees; tiles in `detectedTiles` are marked as detected in
    /// full. Without a region everything is drawn. `censusTiles` is the census by tile when the caller keeps one; it is
    /// made here otherwise. `remoteTiles` are the server's counts for tiles (GetTileSummaries): a tile this phone holds
    /// no trees in is shaded from those.
    public init(
        state: CensusState,
        routes: [Route] = [],
        boundary: [[GeoPoint]] = [],
        visibility: Visibility = Visibility(),
        region: MapViewport? = nil,
        detectedLimit: Int = 600,
        reference: Reference? = nil,
        surveyed: Set<S2CellID> = [],
        treeForms: [String: TreeForm] = [:],
        treeProfiles: [String: TreeProfile] = [:],
        censusTiles: CensusTiles? = nil,
        remoteTiles: [S2CellID: TileSummary] = [:],
        own: Set<UUID> = [],
        ownLimit: Int = 200,
        detectedTiles: Set<S2CellID> = []
    ) {
        let detail = region.map(MapDetail.init(region:)) ?? .everything
        let index = censusTiles ?? CensusTiles(state)
        let hazards = Dictionary(grouping: state.tags.values, by: \.treeID).mapValues(\.count)
        let padded = region.map {
            MapViewport(
                center: $0.center, latitudeDelta: $0.latitudeDelta * 1.3, longitudeDelta: $0.longitudeDelta * 1.3)
        }
        /// Whether a tile not drawn in full is near enough the region for a patch.
        func near(_ tile: S2CellID) -> Bool { padded?.contains(tile.center) ?? false }
        /// The patch a tile not drawn in full counts towards.
        func patchID(_ tile: S2CellID) -> S2CellID {
            detail.summaryLevel < S2CellID.tileLevel ? tile.parent(level: detail.summaryLevel) : tile
        }
        func shows(_ tree: Tree) -> Bool {
            tree.displayStatus != .removed && visibility.statuses.contains(tree.displayStatus)
        }
        let shownStatuses = visibility.statuses.subtracting([.removed])
        let reviewedStatuses = shownStatuses.intersection([.proposed, .confirmed, .verified])

        /// A tree to draw, small enough to sort cheaply: thousands of whole trees are slow to sort, so each tree is
        /// looked up again only to make its marker.
        struct Shown {
            var id: UUID
            var location: GeoPoint
            var status: CountStatus
            var tile: S2CellID
        }
        func entry(_ tree: Tree, in tile: S2CellID) -> Shown {
            Shown(id: tree.id, location: tree.position.geo, status: tree.displayStatus, tile: tile)
        }
        var shown: [Shown] = []
        var patches: [S2CellID: TileSummary] = [:]
        /// Per patch: the tiles with trees in it, and how many of those are surveyed and detected in full.
        var patchTiles: [S2CellID: (all: Int, surveyed: Int, detected: Int)] = [:]
        func counted(_ tile: S2CellID, in id: S2CellID) {
            let counted = patchTiles[id] ?? (0, 0, 0)
            patchTiles[id] = (
                counted.all + 1, counted.surveyed + (surveyed.contains(tile) ? 1 : 0),
                counted.detected + (detectedTiles.contains(tile) ? 1 : 0)
            )
        }
        for (tile, counts) in index.counts {
            if detail.isDetailed(tile) {
                for id in index.trees[tile] ?? [] {
                    if let tree = state.trees[id], shows(tree) { shown.append(entry(tree, in: tile)) }
                }
                continue
            }
            guard near(tile) else { continue }
            let detected = shownStatuses.contains(.detected) ? counts.detected : 0
            let reviewed = counts.count(of: reviewedStatuses)
            guard detected + reviewed > 0 else { continue }
            let id = patchID(tile)
            var patch = patches[id] ?? TileSummary(id: id)
            patch.detected += detected
            patch.reviewed += reviewed
            patches[id] = patch
            counted(tile, in: id)
        }
        // Tiles the server holds trees in that this phone has not pulled: shaded from the server's counts.
        let showsDetected = shownStatuses.contains(.detected)
        let showsReviewed = !reviewedStatuses.isEmpty
        for (tile, remote) in remoteTiles where index.trees[tile] == nil && !detail.isDetailed(tile) && near(tile) {
            let detected = showsDetected ? remote.detected : 0
            let reviewed = showsReviewed ? remote.reviewed : 0
            guard detected + reviewed > 0 else { continue }
            let id = patchID(tile)
            var patch = patches[id] ?? TileSummary(id: id)
            patch.detected += detected
            patch.reviewed += reviewed
            patch.tags += remote.tags
            patches[id] = patch
            counted(tile, in: id)
        }
        for (id, counted) in patchTiles {
            patches[id]?.surveyed = counted.all > 0 && counted.surveyed == counted.all
            patches[id]?.detectedInFull = counted.all > 0 && counted.detected == counted.all
        }
        // A tile marked surveyed, or detected in full, with nothing left to show still gets its patch, so the mark
        // shows.
        if detail.summaryLevel == S2CellID.tileLevel {
            for tile in surveyed.union(detectedTiles) where !detail.isDetailed(tile) && near(tile) {
                var patch = patches[tile] ?? TileSummary(id: tile)
                if patch.trees == 0 {
                    patch.surveyed = surveyed.contains(tile)
                    patch.detectedInFull = detectedTiles.contains(tile)
                }
                patches[tile] = patch
            }
        }

        if let region {
            let detected = shown.filter { $0.status == .detected }
                .sorted { region.squaredDistance(to: $0.location) < region.squaredDistance(to: $1.location) }
                .prefix(detectedLimit)
            shown = shown.filter { $0.status != .detected } + detected
            // The player's own trees outside the tiles drawn in full: few, and what the map is mostly for.
            if let padded, !own.isEmpty {
                let mine = own.compactMap { state.trees[$0] }
                    .filter { shows($0) && padded.contains($0.position.geo) }
                    .map { entry($0, in: $0.position.tile) }
                    .filter { !detail.isDetailed($0.tile) }
                    .sorted { region.squaredDistance(to: $0.location) < region.squaredDistance(to: $1.location) }
                    .prefix(ownLimit)
                shown += mine
            }
        }
        let trees =
            shown
            // North first; the id only breaks ties, so its string is made only then.
            .sorted { a, b in
                a.location.latitude != b.location.latitude
                    ? a.location.latitude > b.location.latitude : a.id.uuidString > b.id.uuidString
            }
            .compactMap { shown -> TreeMarker? in
                guard let tree = state.trees[shown.id] else { return nil }
                return TreeMarker(
                    id: tree.id, location: shown.location, status: shown.status,
                    hazardCount: hazards[tree.id] ?? 0, dbh: tree.dbh?.diameter.value,
                    height: tree.height?.height.value, lean: tree.lean,
                    inSurveyedCell: shown.status == .detected && surveyed.contains(shown.tile))
            }

        var tags: [TagMarker] = []
        for tag in state.tags.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let tile = tag.point.position.tile
            if detail.isDetailed(tile) {
                if visibility.tags {
                    tags.append(
                        TagMarker(
                            id: tag.id, treeID: tag.treeID, location: tag.point.position.geo, urgency: tag.urgency))
                }
            } else if patches[patchID(tile)] != nil {
                patches[patchID(tile)]?.tags += 1
            }
        }

        var tiles: [TileOutline] = []
        if visibility.tiles {
            let level16 = Set(index.trees.keys).union(surveyed).filter { detail.isDetailed($0) || near($0) }
            tiles = Set(level16.map { $0.parent(level: 13) }).sorted().map { TileOutline(id: $0) }
            tiles += level16.sorted().map { TileOutline(id: $0, surveyed: surveyed.contains($0)) }
        }
        self.init(
            trees: trees,
            tags: tags,
            routes: visibility.routes ? routes.map { RouteLine(id: $0.id, name: $0.name, points: $0.points) } : [],
            tiles: tiles,
            boundary: boundary,
            visibility: visibility,
            // Gerardus's vectors and sites only when the player shows them.
            reference: visibility.vectors ? reference : nil,
            treeForms: treeForms
        )
        self.treeProfiles = treeProfiles
        self.detail = detail
        self.summaries = patches.values.filter { $0.trees > 0 || $0.surveyed || $0.detectedInFull }
            .sorted { $0.id < $1.id }
    }

    /// The patch under a point, if one is drawn there.
    public func summary(at point: GeoPoint) -> TileSummary? {
        guard !summaries.isEmpty else { return nil }
        let id = S2CellID(point, level: detail.summaryLevel)
        return summaries.first { $0.id == id }
    }

    /// The vector lines to draw: those starting in a tile drawn in full.
    public var detailedLines: [Reference.Line] {
        guard let reference else { return [] }
        guard detail.detailed != nil else { return reference.lines }
        return reference.lines.filter { $0.tile.map(detail.isDetailed) ?? true }
    }

    /// The loaded sites to draw in full: those whose own tile is.
    public var detailedSites: [Reference.Site] {
        guard let reference else { return [] }
        return reference.sites.filter { S2CellID(token: $0.token).map(detail.isDetailed) ?? true }
    }
}

/// How a tree is drawn. Shape carries the status as well as colour: faint dot, dashed ring, ring, solid.
public enum TreeSymbol: Equatable, Sendable {
    /// Detected by aerial LiDAR: a small faint dot.
    case faintDot
    /// Waiting for agreement: a dashed ring.
    case dashedRing
    /// Confirmed: a ring.
    case ring
    /// Verified: a solid dot.
    case solid
    /// Removed: not drawn.
    case hidden

    public init(_ status: CountStatus) {
        switch status {
        case .detected: self = .faintDot
        case .proposed: self = .dashedRing
        case .confirmed: self = .ring
        case .verified: self = .solid
        case .removed: self = .hidden
        }
    }
}

/// A map region: centre and span in degrees.
public struct MapViewport: Equatable, Sendable {
    public var center: GeoPoint
    public var latitudeDelta: Double
    public var longitudeDelta: Double

    public init(center: GeoPoint, latitudeDelta: Double, longitudeDelta: Double) {
        self.center = center
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    /// The square region round a circle of `radius` metres.
    public init(center: GeoPoint, radius: Double) {
        self.init(
            center: center, latitudeDelta: 2 * radius / 110_574,
            longitudeDelta: 2 * radius / (111_320 * cos(center.latitude * .pi / 180)))
    }

    /// The whole of Golden Gate Park, Panhandle included.
    public static let goldenGatePark = MapViewport(
        center: GeoPoint(latitude: 37.7694, longitude: -122.4770),
        latitudeDelta: 0.016,
        longitudeDelta: 0.072
    )

    /// San Francisco: Lands End and the Presidio to the Bay, the Golden Gate to the county line.
    public static let sanFrancisco = MapViewport(
        center: GeoPoint(latitude: 37.7680, longitude: -122.4350),
        latitudeDelta: 0.130,
        longitudeDelta: 0.162
    )

    public func contains(_ point: GeoPoint) -> Bool {
        abs(point.latitude - center.latitude) <= latitudeDelta / 2
            && abs(point.longitude - center.longitude) <= longitudeDelta / 2
    }

    /// Metres from the centre to a corner: the radius of the smallest circle round the region.
    public var cornerDistance: Double {
        let corner = GeoPoint(
            latitude: center.latitude + latitudeDelta / 2, longitude: center.longitude + longitudeDelta / 2)
        return LocalFrame(origin: center).enu(of: corner).horizontalDistance
    }

    /// Squared distance from the centre in degrees, longitude scaled by cos(latitude); for ordering only.
    func squaredDistance(to point: GeoPoint) -> Double {
        let dLat = point.latitude - center.latitude
        let dLng = (point.longitude - center.longitude) * cos(center.latitude * .pi / 180)
        return dLat * dLat + dLng * dLng
    }
}
