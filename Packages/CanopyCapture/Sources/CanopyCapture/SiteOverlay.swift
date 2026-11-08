import CanopyModel
import CanopyReference
import Foundation
import simd

/// Where a Gerardus site's frame (metres east, north and NAVD88 up from the site origin) lands in the AR session's
/// world frame (+x east, +y up, +z south, metres from where the session started, with gravity-and-heading alignment).
///
/// With a 3DEP registration the placement is the registration's pose, good to its sigma. Without one it is the GPS
/// fix: the session origin's WGS 84 position from the fix and the camera's offset, the site's georeference for the
/// horizontal, and the ground under the origin for the vertical. That is metres out, which is what eyeballing the
/// overlay against the real tree is for.
public struct ARSiteFrame: Sendable {
    enum Placement: Sendable {
        case registered(RegisteredScan)
        case gps(origin: LocalFrame, up: Double)
    }

    let placement: Placement
    public let georeference: SiteGeoreference

    /// Through a 3DEP registration. `georeference` is the drawn site's; the registration's own site is the usual
    /// one, and a neighbouring site is placed through the map positions both fits agree on.
    public init(registered: RegisteredScan, georeference: SiteGeoreference? = nil) {
        placement = .registered(registered)
        self.georeference = georeference ?? registered.georeference
    }

    /// Through a GPS fix.
    /// - Parameters:
    ///   - origin: the WGS 84 position of the AR session's origin.
    ///   - arGroundAtOrigin: the ARKit height (y) of the ground under the session origin.
    ///   - siteGroundAtOrigin: the site-frame height (z) of the ground there.
    public init(
        origin: GeoPoint, georeference: SiteGeoreference, arGroundAtOrigin: Float, siteGroundAtOrigin: Double
    ) {
        placement = .gps(origin: LocalFrame(origin: origin), up: Double(arGroundAtOrigin) - siteGroundAtOrigin)
        self.georeference = georeference
    }

    public var isRegistered: Bool {
        if case .registered = placement { true } else { false }
    }

    /// Where a site-frame point is in the AR world.
    public func arkit(_ site: SIMD3<Double>) -> SIMD3<Float> {
        switch placement {
        case .registered(let scan):
            let own = scan.georeference.site(of: georeference.geo(x: site.x, y: site.y))
            let t = scan.pose.translation
            let q = scan.pose.rotation
            let inverse = Quaternion(w: q.w, x: -q.x, y: -q.y, z: -q.z)
            let sensor = inverse.rotate(Vector3(x: own.x - t.x, y: own.y - t.y, z: site.z - t.z))
            return ScanRegistration.arkitPoint(fromSensor: SIMD3(Float(sensor.x), Float(sensor.y), Float(sensor.z)))
        case .gps(let origin, let up):
            let enu = origin.enu(of: georeference.geo(x: site.x, y: site.y))
            return SIMD3(Float(enu.east), Float(site.z + up), Float(-enu.north))
        }
    }

    /// Where an AR world point is in the site frame, horizontally.
    public func site(ofARKit point: SIMD3<Float>) -> SIMD2<Double> {
        switch placement {
        case .registered(let scan):
            let own = scan.site(ofARKit: point)
            return georeference.site(of: scan.georeference.geo(x: own.x, y: own.y))
        case .gps(let origin, _):
            let geo = origin.geoPoint(of: ENU(east: Double(point.x), north: Double(-point.z), up: 0)).point
            return georeference.site(of: geo)
        }
    }

    /// The site-frame height of the ground at a site-frame point, from the site's ground grid when it has one.
    public static func groundHeight(_ ground: Heightfield?, at site: SIMD2<Double>) -> Double? {
        ground?.height(x: site.x, y: site.y).flatMap { $0.isFinite ? $0 : nil }
    }

    public func arkit(_ site: SIMD3<Float>) -> SIMD3<Float> {
        arkit(SIMD3<Double>(Double(site.x), Double(site.y), Double(site.z)))
    }

    /// Where a map position is in the site frame, horizontally.
    public func site(of geo: GeoPoint) -> SIMD2<Double> {
        georeference.site(of: geo)
    }
}

/// A tree as Gerardus sends it in its TREES layer: a segment from the trunk's base to the crown's base (both at the
/// base for a Street Tree List entry, which has no heights) with `dbh_m`, `height_m`, `crown_base_m` and
/// `crown_radius_m` tags when known. The defaults are the Mac visualiser's: a crown 2 m in radius, as tall as it is
/// wide, on whatever trunk there is.
public struct GerardusTree: Equatable, Sendable {
    public var id: String
    /// Trunk base, site frame.
    public var base: SIMD3<Float>
    public var form: TreeForm
    public var species: String?
    public var commonName: String?
    /// Which tags the server had, so the panel can say what is measured and what is a default.
    public var measured: Set<String>

    public static let defaultCrownRadius = 2.0
    public static let defaultTrunkDiameter = 0.3

    public init?(_ line: LineFeature) {
        guard line.kind == .tree, let base = line.vertices.first, let trunkTop = line.vertices.last else {
            return nil
        }
        func number(_ key: String) -> Double? {
            line.tags[key].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        let radius = number("crown_radius_m") ?? Self.defaultCrownRadius
        let trunkHeight = Double(trunkTop.z - base.z)
        let crownBase = number("crown_base_m") ?? (trunkHeight > 0.5 ? trunkHeight : 0)
        let height = number("height_m") ?? crownBase + 2 * radius
        id = line.featureID
        self.base = base
        form =
            TreeForm(
                trunkDiameter: number("dbh_m") ?? Self.defaultTrunkDiameter,
                height: height, crownHeight: max(height - crownBase, 0), crownWidth: 2 * radius
            ).clamped
        species = line.tags["species"].flatMap { $0.isEmpty ? nil : $0 }
        commonName = line.tags["common_name"].flatMap { $0.isEmpty ? nil : $0 }
        measured = Set(["dbh_m", "height_m", "crown_base_m", "crown_radius_m"].filter { number($0) != nil })
    }
}

/// Gerardus's site vectors as wireframe items in the AR world: trees as the Mac visualiser's figure, buildings as
/// the outlines of their faces, streets as their lines. Nothing is extruded that the server did not extrude.
public enum SiteWireframes {
    public enum Layer: String, CaseIterable, Sendable {
        case trees
        case buildings
        case streets
        /// S2 cells on the ground: level 16 (the sites and the census's tiles) and level 13 (the server's cells).
        case cells

        public var label: String {
            switch self {
            case .trees: "Trees"
            case .buildings: "Buildings"
            case .streets: "Streets and kerbs"
            case .cells: "S2 cells (L13, L16)"
            }
        }

        /// Whether the layer is drawn from a site's features; the cells are drawn from the map alone.
        public var isSiteLayer: Bool { self != .cells }
    }

    /// Posts at a cell's corners, in metres: short for a level-16 cell, tall for a level-13 one.
    public static func cellPostHeight(level: Int) -> Float { level <= 13 ? 6 : 1.5 }

    /// The cells drawn round a point: the level-16 cells within `radius` of it (sampled on a grid), and their
    /// level-13 parents.
    public static func cells(
        around centre: GeoPoint, radius: Double = 250
    ) -> (level16: [S2CellID], level13: [S2CellID]) {
        let frame = LocalFrame(origin: centre)
        var level16: Set<S2CellID> = []
        let step = 50.0
        var east = -radius
        while east <= radius {
            var north = -radius
            while north <= radius {
                if (east * east + north * north).squareRoot() <= radius {
                    level16.insert(frame.geoPoint(of: ENU(east: east, north: north, up: 0)).point.tile)
                }
                north += step
            }
            east += step
        }
        let level13 = Set(level16.map { $0.parent(level: 13) })
        return (level16.sorted(), level13.sorted())
    }

    /// A cell as a wireframe: its outline a little above the ground and a post at each corner. `place` gives the AR
    /// world point on the ground under a map point.
    public static func cellItem(_ cell: S2CellID, place: (GeoPoint) -> SIMD3<Float>) -> WireframeItem {
        let lift = SIMD3<Float>(0, 0.15, 0)
        let corners = cell.vertices.map { place($0) + lift }
        var segments = Wireframe.polyline(corners, closed: true)
        let post = SIMD3<Float>(0, cellPostHeight(level: cell.level), 0)
        segments += corners.map { Wireframe.Segment(from: $0, to: $0 + post) }
        return WireframeItem(id: "cell:" + cell.token, segments: segments)
    }

    /// How far from the centre features are drawn, in metres.
    public static let radius: Float = 150
    /// Ring segments and uprights are scaled down by this for the site's trees.
    public static let treeDetail: Float = 0.5

    /// The trees in a site's features.
    public static func trees(in features: [VectorReference.Feature]) -> [GerardusTree] {
        features.filter { $0.layer == .trees }.compactMap { GerardusTree($0.line) }
    }

    /// A tree's wireframe standing at `base` (AR world), selectable by a box round its crown and trunk.
    public static func treeItem(
        id: String, form: TreeForm, lean: Lean? = nil, at base: SIMD3<Float>, detail: Float = treeDetail
    ) -> WireframeItem {
        let figure = WireframeTree.figure(form, lean: lean, at: base, detail: detail)
        let form = form.clamped
        let width = Float(max(form.crownWidth, form.trunkDiameter, 0.6))
        return WireframeItem(
            id: id, segments: figure.all,
            pickBox: PickBox(
                centre: base + SIMD3(0, Float(form.height / 2), 0), size: SIMD3(width, Float(form.height), width)))
    }

    /// The items of one layer within `radius` of `centre` (site frame), placed through `frame`. `forms` overrides a
    /// tree's shape by its id, for the ones the player has adjusted.
    public static func items(
        _ features: [VectorReference.Feature], layer: Layer, frame: ARSiteFrame, centre: SIMD2<Float>,
        radius: Float = radius, forms: [String: TreeForm] = [:]
    ) -> [WireframeItem] {
        func near(_ line: LineFeature) -> Bool {
            guard let first = line.vertices.first else { return false }
            return simd_distance(SIMD2(first.x, first.y), centre) <= radius
        }
        switch layer {
        case .trees:
            return features.filter { $0.layer == .trees && near($0.line) }.compactMap { feature in
                guard let tree = GerardusTree(feature.line) else { return nil }
                return treeItem(id: tree.id, form: forms[tree.id] ?? tree.form, at: frame.arkit(tree.base))
            }
        case .buildings:
            // Box walls and wall surfaces already stand where the outlines would be extruded.
            let hasWalls = features.contains { $0.layer == .boxes || $0.layer == .buildings }
            let wallSurfaces = features.contains { $0.layer == .buildings && $0.line.kind == .wallSurface }
            return features.compactMap { feature -> WireframeItem? in
                let line = feature.line
                switch feature.layer {
                case .footprints:
                    // Walls stand where the outline would be extruded; the footprint still gives the roofline.
                    if hasWalls {
                        guard near(line), line.closed, line.height.isFinite, line.height > 0 else { return nil }
                        let top = line.vertices.map { frame.arkit($0) + SIMD3(0, line.height, 0) }
                        return WireframeItem(id: line.featureID, segments: Wireframe.polyline(top, closed: true))
                    }
                case .boxes, .buildings: break
                case .observed: if line.kind != .wallPlane && line.kind != .facade { return nil }
                default: return nil
                }
                guard near(line) else { return nil }
                var segments = Wireframe.polyline(line.vertices.map(frame.arkit), closed: line.closed)
                // An older server's parts and plain footprints carry a height to extrude; walls never do again.
                let extrudes = feature.layer == .footprints || (line.kind == .buildingPart && !wallSurfaces)
                let height =
                    line.kind == .buildingPart
                    ? (line.tags["height"].flatMap(Float.init) ?? line.height)
                        - (line.tags["min_height"].flatMap(Float.init) ?? 0)
                    : line.height
                if extrudes, line.closed, height.isFinite, height > 0 {
                    let up = SIMD3<Float>(0, height, 0)
                    let bottom = line.vertices.map(frame.arkit)
                    segments += Wireframe.polyline(bottom.map { $0 + up }, closed: true)
                    segments += bottom.map { Wireframe.Segment(from: $0, to: $0 + up) }
                }
                return segments.isEmpty ? nil : WireframeItem(id: line.featureID, segments: segments)
            }
        case .streets:
            return features.compactMap { feature -> WireframeItem? in
                let line = feature.line
                switch feature.layer {
                case .cityStreets, .kerbs, .streetUse, .laneMarkings, .streetFurniture: break
                case .observed: if line.kind != .pole { return nil }
                default: return nil
                }
                guard near(line) else { return nil }
                let segments = Wireframe.polyline(line.vertices.map(frame.arkit), closed: line.closed)
                return segments.isEmpty ? nil : WireframeItem(id: line.featureID, segments: segments)
            }
        case .cells:
            // Not a site layer: see `cellItem`.
            return []
        }
    }
}
