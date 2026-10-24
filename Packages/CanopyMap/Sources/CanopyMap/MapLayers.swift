import CanopyModel
import Foundation

/// Everything the map draws, as plain values. Renderers turn this into map content; it knows nothing about
/// MapKit, so a MapLibre renderer can draw the same layers.
public struct MapLayers: Equatable, Sendable {
    public struct Visibility: Equatable, Sendable {
        public var detected = true
        public var tags = true
        public var routes = true
        /// S2 L16 tile outlines.
        public var tiles = false

        public init(detected: Bool = true, tags: Bool = true, routes: Bool = true, tiles: Bool = false) {
            self.detected = detected
            self.tags = tags
            self.routes = routes
            self.tiles = tiles
        }
    }

    public struct TreeMarker: Identifiable, Hashable, Sendable {
        public var id: UUID
        public var location: GeoPoint
        /// The status to draw (`Tree.displayStatus`).
        public var status: CountStatus
        public var hazardCount: Int

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

    /// An S2 L16 tile's outline.
    public struct TileOutline: Identifiable, Hashable, Sendable {
        public var id: S2CellID
        public var corners: [GeoPoint]
    }

    public var trees: [TreeMarker]
    public var tags: [TagMarker]
    public var routes: [RouteLine]
    public var tiles: [TileOutline]
    /// Park outline: outer rings of the boundary polygons.
    public var boundary: [[GeoPoint]]
    public var visibility: Visibility

    public init(
        trees: [TreeMarker] = [],
        tags: [TagMarker] = [],
        routes: [RouteLine] = [],
        tiles: [TileOutline] = [],
        boundary: [[GeoPoint]] = [],
        visibility: Visibility = Visibility()
    ) {
        self.trees = trees
        self.tags = tags
        self.routes = routes
        self.tiles = tiles
        self.boundary = boundary
        self.visibility = visibility
    }

    /// Builds the layers from the census. Removed trees are left out; tiles are the L16 tiles holding a tree.
    ///
    /// Real aerial data gives thousands of detected trees, more than a map can draw as markers. With a `region`,
    /// detected trees are drawn only inside it (with a margin), at most `detectedLimit` of them, nearest the centre
    /// first; trees people have acted on are always drawn.
    public init(
        state: CensusState,
        routes: [Route] = [],
        boundary: [[GeoPoint]] = [],
        visibility: Visibility = Visibility(),
        region: MapViewport? = nil,
        detectedLimit: Int = 600
    ) {
        let hazards = Dictionary(grouping: state.tags.values, by: \.treeID).mapValues(\.count)
        var shown = state.trees.values
            .filter { $0.displayStatus != .removed }
            .filter { visibility.detected || $0.displayStatus != .detected }
        if let region {
            let padded = MapViewport(
                center: region.center, latitudeDelta: region.latitudeDelta * 1.3,
                longitudeDelta: region.longitudeDelta * 1.3)
            let detected = shown.filter { $0.displayStatus == .detected && padded.contains($0.position.geo) }
            let nearest = detected.sorted {
                region.squaredDistance(to: $0.position.geo) < region.squaredDistance(to: $1.position.geo)
            }
            .prefix(detectedLimit)
            shown = shown.filter { $0.displayStatus != .detected } + nearest
        }
        let trees =
            shown
            .sorted { ($0.position.geo.latitude, $0.id.uuidString) > ($1.position.geo.latitude, $1.id.uuidString) }
            .map { tree in
                TreeMarker(
                    id: tree.id, location: tree.position.geo, status: tree.displayStatus,
                    hazardCount: hazards[tree.id] ?? 0)
            }
        let tags =
            visibility.tags
            ? state.tags.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { tag in
                TagMarker(id: tag.id, treeID: tag.treeID, location: tag.point.position.geo, urgency: tag.urgency)
            } : []
        let tiles =
            visibility.tiles
            ? Set(state.trees.values.map(\.position.tile)).sorted().map { TileOutline(id: $0, corners: $0.vertices) }
            : []
        self.init(
            trees: trees,
            tags: tags,
            routes: visibility.routes ? routes.map { RouteLine(id: $0.id, name: $0.name, points: $0.points) } : [],
            tiles: tiles,
            boundary: boundary,
            visibility: visibility
        )
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

    /// The whole of Golden Gate Park, Panhandle included.
    public static let goldenGatePark = MapViewport(
        center: GeoPoint(latitude: 37.7694, longitude: -122.4770),
        latitudeDelta: 0.016,
        longitudeDelta: 0.072
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
