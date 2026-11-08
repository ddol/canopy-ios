import CanopyCapture
import CanopyDesign
import CanopyModel
import CanopyReference
import SceneKit
import SwiftUI
import simd

/// The map with no base map, drawn the way the Mac visualiser draws a site: Gerardus's ground grid, buildings as
/// their walls and roofs, streets and kerbs as lines, Gerardus's trees as a trunk and crown rings, and the census's
/// trees as the same figure in their status colour, all in 3D. Drag to move, two fingers to turn and tilt, pinch to
/// zoom, tap a tree to select it.
public struct WireframeRenderer: MapRenderer {
    public init() {}

    public func makeBody(
        layers: MapLayers, selection: Binding<UUID?>, viewport: MapViewport, focus: MapFocus?,
        onViewportChange: @escaping @MainActor (MapViewport) -> Void
    ) -> some View {
        WireframeMap(
            layers: layers, selection: selection, viewport: viewport, focus: focus, onViewportChange: onViewportChange
        )
        .overlay(alignment: .bottomLeading) {
            Text("Drag to move · Two fingers to turn, tilt and zoom · Tap a tree")
                .font(.caption2)
                .foregroundStyle(Color.canopyInkMuted)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxs)
                .background(.thinMaterial, in: Capsule())
                .padding(Spacing.s)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Wireframe map")
        .accessibilityIdentifier("wireframe-map")
    }
}

/// Site-frame metres to scene metres as one affine map: the georeference's site-to-map fit composed with the
/// scene's local frame, both linear over a few kilometres. Scene axes are ARKit's: x east, y up, z south.
struct SiteToScene: Sendable {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var offset: SIMD2<Float>
    var elevation: Float

    init(georeference: SiteGeoreference, scene: LocalFrame, elevation: Float) {
        func enu(_ x: Double, _ y: Double) -> SIMD2<Double> {
            let e = scene.enu(of: georeference.geo(x: x, y: y))
            return SIMD2(e.east, e.north)
        }
        let origin = enu(0, 0)
        let east = (enu(1000, 0) - origin) / 1000
        let north = (enu(0, 1000) - origin) / 1000
        a = SIMD2(Float(east.x), Float(east.y))
        b = SIMD2(Float(north.x), Float(north.y))
        offset = SIMD2(Float(origin.x), Float(origin.y))
        self.elevation = elevation
    }

    /// Scene point of a site-frame point.
    func place(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let enu = a * p.x + b * p.y + offset
        return SIMD3(enu.x, p.z - elevation, -enu.y)
    }
}

/// What the wireframe map draws of a census tree: its figure from what is measured, in its status colour.
enum WireframeTrees {
    static func form(_ marker: MapLayers.TreeMarker) -> TreeForm {
        var form =
            marker.dbh.map { TreeForm(dbh: DBH(diameter: Quantity($0, uncertainty: 0), method: .estimate)) }
            ?? TreeForm(trunkDiameter: 0.3, height: 8, crownHeight: 5, crownWidth: 5)
        if let height = marker.height {
            form.height = height
            form.crownHeight = height * 2 / 3
        }
        return form.clamped
    }

    /// How a batch of trees is drawn: by status, faint for a detection in a surveyed cell.
    struct Look: Hashable {
        var status: CountStatus
        var faint: Bool

        var color: UIColor { WireframeTrees.color(status, selected: false, inSurveyedCell: faint) }
    }

    static var selectedColor: UIColor { CanopyColor.survey.uiColor }

    /// A patch's fill: from the background (no trees) to the brand green (dense woodland).
    static func patchColor(_ density: Double) -> SIMD4<Float> {
        func rgba(_ color: UIColor) -> SIMD4<Float> {
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return SIMD4(Float(r), Float(g), Float(b), 1)
        }
        let t = Float(0.15 + 0.7 * min(max(density, 0), 1))
        let low = rgba(CanopyColor.surface100.uiColor)
        return low + (rgba(CanopyColor.brand.uiColor) - low) * t
    }

    static func color(_ status: CountStatus, selected: Bool, inSurveyedCell: Bool = false) -> UIColor {
        if selected { return selectedColor }
        switch status {
        case .detected:
            // A detection in a surveyed cell was looked over and left: faint.
            return inSurveyedCell
                ? CanopyColor.lineStrong.uiColor.withAlphaComponent(0.35) : CanopyColor.lineStrong.uiColor
        case .proposed: return StatusTone.proposed.foreground.uiColor
        case .confirmed: return CanopyColor.brand.uiColor
        case .verified: return CanopyColor.canopy.uiColor
        case .removed: return .clear
        }
    }
}

struct WireframeMap: UIViewRepresentable {
    let layers: MapLayers
    @Binding var selection: UUID?
    let viewport: MapViewport
    let focus: MapFocus?
    let onViewportChange: @MainActor (MapViewport) -> Void

    static let fieldOfView: CGFloat = 52
    static let distances: ClosedRange<Float> = 12...4000

    func makeCoordinator() -> Coordinator { Coordinator(anchor: viewport.center) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let coordinator = context.coordinator
        view.backgroundColor = CanopyColor.surface100.uiColor
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.scene = coordinator.scene
        view.pointOfView = coordinator.camera
        let move = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.move(_:)))
        move.maximumNumberOfTouches = 1
        let tilt = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.tilt(_:)))
        tilt.minimumNumberOfTouches = 2
        tilt.maximumNumberOfTouches = 2
        let turn = UIRotationGestureRecognizer(target: coordinator, action: #selector(Coordinator.turn(_:)))
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:)))
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
        for gesture in [move, tilt, turn, pinch, tap] as [UIGestureRecognizer] {
            gesture.delegate = coordinator
            view.addGestureRecognizer(gesture)
        }
        coordinator.view = view
        coordinator.onViewportChange = onViewportChange
        coordinator.onSelect = { selection = $0 }
        coordinator.look(at: viewport)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onViewportChange = onViewportChange
        coordinator.onSelect = { selection = $0 }
        coordinator.apply(layers, selection: selection)
        if let focus, coordinator.focusID != focus.id {
            coordinator.focusID = focus.id
            coordinator.look(at: focus.viewport)
            coordinator.report()
        }
    }

    /// Owns the scene: the camera rig; the loaded sites drawn in full, one node each, added and taken away as the
    /// tiles drawn in full change; the census's trees, batched into one mesh per colour; and the patches standing for
    /// the tiles not drawn in full.
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let scene = SCNScene()
        let camera = SCNNode()
        let siteRoot = SCNNode()
        /// Gerardus's trees, apart from the rest of the sites so an adjusted shape redraws only them.
        let siteTreeRoot = SCNNode()
        let treeRoot = SCNNode()
        let summaryRoot = SCNNode()
        let contextRoot = SCNNode()
        /// The scene's origin on the map.
        let anchor: LocalFrame
        weak var view: SCNView?
        var onViewportChange: @MainActor (MapViewport) -> Void = { _ in }
        var onSelect: @MainActor (UUID?) -> Void = { _ in }
        var focusID: UUID?

        /// Camera rig: looking at `target` from `distance` metres, `tilt` radians above the ground, turned
        /// `azimuth` radians from north-up (camera south of the target looking north).
        var target = SIMD3<Float>.zero
        var distance: Float = 300
        var tilt: Float = 55 * .pi / 180
        var azimuth: Float = 0
        private var targetAtStart = SIMD3<Float>.zero
        private var distanceAtStart: Float = 300
        private var tiltAtStart: Float = 0
        private var azimuthAtStart: Float = 0

        private var reference: MapLayers.Reference?
        private var elevation: Float = 0
        /// Every loaded site's ground, drawn or not, so heights are the same whichever tiles are drawn in full.
        private var grounds: [(SiteToScene, Heightfield)] = []
        private var groundRange: ClosedRange<Float> = 0...1
        /// Which site draws each feature: neighbouring sites overlap, and a feature is drawn once, by the first site
        /// in the reference that has it.
        private var owners: [String: String] = [:]
        /// The sites drawn, by key, with their trees apart so an adjusted shape redraws only those.
        private var siteNodes: [String: SCNNode] = [:]
        private var siteTreeNodes: [String: SCNNode] = [:]
        private var detail = MapDetail.everything
        private var trees: [MapLayers.TreeMarker] = []
        /// Where each drawn census tree stands, base and top in scene metres, for picking one by a tap.
        private(set) var pickable: [(id: UUID, base: SIMD3<Float>, top: SIMD3<Float>)] = []
        private var summaries: [TileSummary] = []
        /// The patches in the order their faces were added, two triangles each, for finding the one tapped.
        private var summaryFaces: [TileSummary] = []
        private var treeForms: [String: TreeForm] = [:]
        private var treeProfiles: [String: TreeProfile] = [:]
        private var selected: UUID?
        private var context: (routes: [MapLayers.RouteLine], boundary: [[GeoPoint]], tiles: [MapLayers.TileOutline])?

        init(anchor: GeoPoint) {
            self.anchor = LocalFrame(origin: anchor)
            super.init()
            camera.camera = SCNCamera()
            camera.camera?.zNear = 0.5
            camera.camera?.zFar = 12000
            camera.camera?.fieldOfView = WireframeMap.fieldOfView
            scene.rootNode.addChildNode(camera)
            scene.rootNode.addChildNode(siteRoot)
            scene.rootNode.addChildNode(siteTreeRoot)
            scene.rootNode.addChildNode(treeRoot)
            scene.rootNode.addChildNode(summaryRoot)
            scene.rootNode.addChildNode(contextRoot)
            placeCamera()
        }

        // MARK: Content

        func apply(_ layers: MapLayers, selection: UUID?) {
            let formsChanged = layers.treeForms != treeForms || layers.treeProfiles != treeProfiles
            treeForms = layers.treeForms
            treeProfiles = layers.treeProfiles
            let selectionChanged = selection != selected
            selected = selection
            if layers.reference !== reference {
                reference = layers.reference
                prepareSites()
                detail = layers.detail
                showSites(layers.detailedSites)
                rebuildTrees(layers.trees)
                rebuildSummaries(layers.summaries)
                rebuildContext(layers)
                return
            }
            if layers.detail != detail {
                detail = layers.detail
                showSites(layers.detailedSites)
            }
            if formsChanged { redrawSiteTrees() }
            if layers.trees != trees || formsChanged || selectionChanged { rebuildTrees(layers.trees) }
            if layers.summaries != summaries { rebuildSummaries(layers.summaries) }
            if context == nil || context!.routes != layers.routes || context!.boundary != layers.boundary
                || context!.tiles != layers.tiles
            {
                rebuildContext(layers)
            }
        }

        /// Takes down every site and works out, for the loaded reference, what drawing any of them needs: the height
        /// the scene is drawn about, every ground for placing points, the height range the ground is tinted over, and
        /// which site draws each feature.
        private func prepareSites() {
            for node in siteNodes.values { node.removeFromParentNode() }
            for node in siteTreeNodes.values { node.removeFromParentNode() }
            siteNodes = [:]
            siteTreeNodes = [:]
            grounds = []
            owners = [:]
            guard let reference, !reference.sites.isEmpty else { return }
            // Heights are drawn relative to the first site's ground, so the scene stays near y = 0.
            let first = reference.sites[0].vectors
            let heights = first.ground?.z.filter(\.isFinite).sorted() ?? []
            let featureHeights = first.features.compactMap { $0.line.vertices.first?.z }.sorted()
            elevation = heights.isEmpty ? (featureHeights.first ?? 0) : heights[heights.count / 2]
            // One height scale across the loaded sites, so a slope reads the same from one site to the next.
            let allHeights = reference.sites.flatMap { $0.vectors.ground?.z.filter(\.isFinite) ?? [] }
            let low = allHeights.min() ?? elevation
            groundRange = low...max(allHeights.max() ?? elevation + 1, low)
            for (index, site) in reference.sites.enumerated() {
                let key = Self.key(site, index: index)
                if let ground = site.vectors.ground {
                    grounds.append(
                        (SiteToScene(georeference: site.georeference, scene: anchor, elevation: elevation), ground))
                }
                for feature in site.vectors.features where owners[feature.line.featureID] == nil {
                    owners[feature.line.featureID] = key
                }
            }
        }

        /// A site's key: its token, or its place in the reference when it has none.
        private static func key(_ site: MapLayers.Reference.Site, index: Int) -> String {
            site.token.isEmpty ? "#\(index)" : site.token
        }

        /// Draws exactly these sites: adds the ones not drawn yet, takes away the rest.
        private func showSites(_ sites: [MapLayers.Reference.Site]) {
            guard let reference else { return }
            let indices = Dictionary(
                reference.sites.enumerated().map { (Self.key($1, index: $0), $0) }, uniquingKeysWith: { a, _ in a })
            let wanted = Dictionary(
                sites.compactMap { site in
                    reference.sites.firstIndex { $0.token == site.token }.map { (Self.key(site, index: $0), site) }
                }, uniquingKeysWith: { a, _ in a })
            for key in Array(siteNodes.keys) where wanted[key] == nil {
                siteNodes.removeValue(forKey: key)?.removeFromParentNode()
                siteTreeNodes.removeValue(forKey: key)?.removeFromParentNode()
            }
            for (key, site) in wanted where siteNodes[key] == nil {
                guard indices[key] != nil else { continue }
                let node = siteNode(site, key: key)
                siteRoot.addChildNode(node)
                siteNodes[key] = node
                let trees = siteTreesNode(site, key: key)
                siteTreeRoot.addChildNode(trees)
                siteTreeNodes[key] = trees
            }
        }

        private func transform(_ site: MapLayers.Reference.Site) -> SiteToScene {
            SiteToScene(georeference: site.georeference, scene: anchor, elevation: elevation)
        }

        /// A site's ground, buildings and streets, of the features it draws.
        private func siteNode(_ site: MapLayers.Reference.Site, key: String) -> SCNNode {
            let node = SCNNode()
            let transform = transform(site)
            let place: @Sendable (SIMD3<Float>) -> SIMD3<Float> = { transform.place($0) }
            if let ground = site.vectors.ground {
                node.addChildNode(
                    VectorMesh(
                        ground: ground, place: place,
                        tint: (low: Self.groundLow, high: Self.groundHigh, range: groundRange)
                    )
                    .node(color: .white, fill: true, edgeColor: CanopyColor.lineStrong.uiColor))
            }
            let features = site.vectors.features
            let hasBoxes = features.contains { $0.layer == .boxes || $0.layer == .buildings }
            let wallSurfaces = features.contains { $0.layer == .buildings && $0.line.kind == .wallSurface }
            var buildings = VectorMesh(place: place)
            var streets = VectorMesh(place: place)
            for feature in features where owners[feature.line.featureID] == key {
                let line = feature.line
                if line.kind == .sensor || line.kind == .correction { continue }
                // Box walls stand where the footprint would be extruded; the footprint still gives the roof.
                if hasBoxes, feature.layer == .footprints {
                    buildings.addLid(line, layer: feature.layer, wallSurfaces: wallSurfaces)
                    continue
                }
                switch feature.layer {
                case .trees:
                    break  // `siteTreesNode`
                case .footprints, .boxes, .buildings, .observed:
                    buildings.add(line, layer: feature.layer, wallSurfaces: wallSurfaces)
                    buildings.addLid(line, layer: feature.layer, wallSurfaces: wallSurfaces)
                default:
                    streets.add(line, layer: feature.layer, wallSurfaces: wallSurfaces)
                }
            }
            node.addChildNode(buildings.node(color: UIColor(red: 0.75, green: 0.69, blue: 0.55, alpha: 0.55)))
            node.addChildNode(streets.node(color: UIColor(red: 0.55, green: 0.55, blue: 0.45, alpha: 1)))
            return node
        }

        /// A site's Gerardus trees, each in the shape the player gave it in AR when they did.
        private func siteTreesNode(_ site: MapLayers.Reference.Site, key: String) -> SCNNode {
            let transform = transform(site)
            var trees = VectorMesh(place: { transform.place($0) })
            for feature in site.vectors.features where feature.layer == .trees && owners[feature.line.featureID] == key
            {
                guard var tree = GerardusTree(feature.line) else { continue }
                if let form = treeForms[tree.id] { tree.form = form }
                trees.add(tree)
            }
            return trees.node(color: UIColor(red: 0.42, green: 0.74, blue: 0.24, alpha: 1))
        }

        /// Draws the drawn sites' trees again, after a shape changed.
        private func redrawSiteTrees() {
            guard let reference else { return }
            for (index, site) in reference.sites.enumerated() {
                let key = Self.key(site, index: index)
                guard let old = siteTreeNodes[key] else { continue }
                old.removeFromParentNode()
                let node = siteTreesNode(site, key: key)
                siteTreeRoot.addChildNode(node)
                siteTreeNodes[key] = node
            }
        }

        /// Scene coordinates of a map point on the ground: the site ground where a loaded site has it, else y = 0.
        private func scenePoint(_ geo: GeoPoint) -> SIMD3<Float> {
            let enu = anchor.enu(of: geo)
            var y: Float = 0
            for (transform, ground) in grounds {
                // Back to that site's frame through the inverse of its linear map.
                let d = SIMD2(Float(enu.east), Float(enu.north)) - transform.offset
                let det = transform.a.x * transform.b.y - transform.a.y * transform.b.x
                guard abs(det) > 1e-9 else { continue }
                let x = (d.x * transform.b.y - d.y * transform.b.x) / det
                let yy = (transform.a.x * d.y - transform.a.y * d.x) / det
                if let h = ground.height(x: Double(x), y: Double(yy)), h.isFinite {
                    y = Float(h) - transform.elevation
                    break
                }
            }
            return SIMD3(Float(enu.east), y, Float(-enu.north))
        }

        /// The census's trees, batched into one mesh per colour so hundreds of them are a handful of draw calls, the
        /// selected one apart in the highlight colour.
        private func rebuildTrees(_ markers: [MapLayers.TreeMarker]) {
            trees = markers
            for node in treeRoot.childNodes { node.removeFromParentNode() }
            pickable = []
            var batches: [WireframeTrees.Look: VectorMesh] = [:]
            var highlighted = VectorMesh(place: { $0 })
            for marker in markers where marker.status != .removed {
                let base = scenePoint(marker.location)
                let key = MapLayers.censusWireframeID(marker.id)
                let profile = treeProfiles[key]
                let form = profile?.form ?? treeForms[key] ?? WireframeTrees.form(marker)
                let figure =
                    profile.map { WireframeTree.figure($0, lean: marker.lean, at: base, detail: 0.5) }
                    ?? WireframeTree.figure(form, lean: marker.lean, at: base, detail: 0.5)
                pickable.append((marker.id, base, base + SIMD3(0, Float(form.height), 0)))
                if marker.id == selected {
                    highlighted.add(sceneSegments: figure.all)
                } else {
                    let look = WireframeTrees.Look(status: marker.status, faint: marker.inSurveyedCell)
                    batches[look, default: VectorMesh(place: { $0 })].add(sceneSegments: figure.all)
                }
            }
            for (look, mesh) in batches {
                treeRoot.addChildNode(mesh.node(color: look.color, fill: false))
            }
            if !highlighted.isEmpty {
                treeRoot.addChildNode(highlighted.node(color: WireframeTrees.selectedColor, fill: false))
            }
        }

        /// The patches for the tiles not drawn in full: each filled in a tint from the background to the brand green
        /// by how many trees it holds, the surveyed ones outlined in green.
        private func rebuildSummaries(_ patches: [TileSummary]) {
            summaries = patches
            summaryFaces = []
            for node in summaryRoot.childNodes { node.removeFromParentNode() }
            guard !patches.isEmpty else { return }
            var fill = VectorMesh(place: { $0 })
            var surveyed = VectorMesh(place: { $0 })
            let lift = SIMD3<Float>(0, 0.15, 0)
            for patch in patches where patch.corners.count == 4 {
                let corners = patch.corners.map { scenePoint($0) + lift }
                let start = UInt32(fill.vertices.count)
                fill.vertices += corners.map { SCNVector3($0) }
                fill.colors += Array(repeating: WireframeTrees.patchColor(patch.density), count: 4)
                fill.triangles += [0, 1, 2, 0, 2, 3].map { start + $0 }
                fill.edges += [0, 1, 1, 2, 2, 3, 3, 0].map { start + $0 }
                summaryFaces.append(patch)
                if patch.surveyed {
                    surveyed.add(scenePolyline: corners.map { $0 + lift }, closed: true)
                }
            }
            let node = fill.node(
                color: .white, fill: true, edgeColor: CanopyColor.lineStrong.uiColor.withAlphaComponent(0.5))
            node.childNodes.first?.name = Self.patchFill
            summaryRoot.addChildNode(node)
            if !surveyed.isEmpty {
                summaryRoot.addChildNode(surveyed.node(color: CanopyColor.brand.uiColor, fill: false))
            }
        }

        static let patchFill = "patch-fill"

        private func rebuildContext(_ layers: MapLayers) {
            context = (layers.routes, layers.boundary, layers.tiles)
            for node in contextRoot.childNodes { node.removeFromParentNode() }
            var routes = VectorMesh(place: { $0 })
            for route in layers.routes {
                routes.add(scenePolyline: route.points.map { scenePoint($0) + SIMD3(0, 0.3, 0) }, closed: false)
            }
            contextRoot.addChildNode(routes.node(color: CanopyColor.brand.uiColor.withAlphaComponent(0.7), fill: false))
            var boundary = VectorMesh(place: { $0 })
            for ring in layers.boundary {
                boundary.add(scenePolyline: ring.map { scenePoint($0) + SIMD3(0, 0.2, 0) }, closed: true)
            }
            contextRoot.addChildNode(
                boundary.node(color: CanopyColor.brand.uiColor.withAlphaComponent(0.6), fill: false))
            // Cells: level-16 tiles low with short posts (surveyed ones in the brand green), level-13 cells a
            // little higher with tall posts, so both read from the ground and from above.
            var tiles = VectorMesh(place: { $0 })
            var surveyed = VectorMesh(place: { $0 })
            var cells13 = VectorMesh(place: { $0 })
            for tile in layers.tiles {
                let level13 = tile.level <= 13
                let lift = SIMD3<Float>(0, level13 ? 0.3 : 0.1, 0)
                let corners = tile.corners.map { scenePoint($0) + lift }
                let post = SIMD3<Float>(0, SiteWireframes.cellPostHeight(level: tile.level), 0)
                var segments = Wireframe.polyline(corners, closed: true)
                segments += corners.map { Wireframe.Segment(from: $0, to: $0 + post) }
                if level13 {
                    cells13.add(sceneSegments: segments)
                } else if tile.surveyed {
                    surveyed.add(sceneSegments: segments)
                } else {
                    tiles.add(sceneSegments: segments)
                }
            }
            contextRoot.addChildNode(tiles.node(color: CanopyColor.lineStrong.uiColor, fill: false))
            contextRoot.addChildNode(surveyed.node(color: CanopyColor.brand.uiColor, fill: false))
            contextRoot.addChildNode(cells13.node(color: CanopyColor.inkMuted.uiColor, fill: false))
        }

        /// Low ground and high ground, in the scene's own tints: a dull green low, a pale one high.
        static let groundLow = SIMD4<Float>(0.22, 0.32, 0.26, 1)
        static let groundHigh = SIMD4<Float>(0.72, 0.76, 0.62, 1)

        // MARK: Camera

        func look(at viewport: MapViewport) {
            target = scenePoint(viewport.center)
            let halfSpan = Float(viewport.cornerDistance / 2.squareRoot())
            distance = min(
                max(
                    halfSpan / Float(tan(WireframeMap.fieldOfView / 2 * .pi / 180)) * 1.1,
                    WireframeMap.distances.lowerBound),
                WireframeMap.distances.upperBound)
            placeCamera()
        }

        private func placeCamera() {
            let offset = SIMD3(sin(azimuth) * cos(tilt), sin(tilt), cos(azimuth) * cos(tilt)) * distance
            camera.position = SCNVector3(target + offset)
            camera.look(at: SCNVector3(target))
        }

        /// The region in view, from the target and the distance.
        var currentViewport: MapViewport {
            let centre = anchor.geoPoint(of: ENU(east: Double(target.x), north: Double(-target.z), up: 0)).point
            let halfSpan = Double(distance) * tan(WireframeMap.fieldOfView / 2 * .pi / 180)
            return MapViewport(center: centre, radius: halfSpan)
        }

        func report() {
            onViewportChange(currentViewport)
        }

        /// Ground metres per point at the target's depth.
        private var metresPerPoint: Float {
            let height = Float(view?.bounds.height ?? 800)
            return distance * 2 * Float(tan(WireframeMap.fieldOfView / 2 * .pi / 180)) / max(height, 1)
        }

        @objc func move(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            if gesture.state == .began { targetAtStart = target }
            let t = gesture.translation(in: view)
            let forward = SIMD3(-sin(azimuth), 0, -cos(azimuth))
            let right = SIMD3(cos(azimuth), 0, -sin(azimuth))
            let scale = metresPerPoint
            target = targetAtStart - right * Float(t.x) * scale + forward * Float(t.y) * scale
            placeCamera()
            if gesture.state == .ended || gesture.state == .cancelled { report() }
        }

        /// Two fingers up or down tilt the view, as on Apple's map.
        @objc func tilt(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            if gesture.state == .began { tiltAtStart = tilt }
            let t = gesture.translation(in: view)
            tilt = min(max(tiltAtStart + Float(t.y) * 0.006, 8 * .pi / 180), 88 * .pi / 180)
            placeCamera()
            if gesture.state == .ended || gesture.state == .cancelled { report() }
        }

        /// Two fingers turning turn the map round the target.
        @objc func turn(_ gesture: UIRotationGestureRecognizer) {
            if gesture.state == .began { azimuthAtStart = azimuth }
            azimuth = azimuthAtStart - Float(gesture.rotation)
            placeCamera()
            if gesture.state == .ended || gesture.state == .cancelled { report() }
        }

        /// Pinch, turn and tilt work together, as on Apple's map; a tap stands alone.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            !(gestureRecognizer is UITapGestureRecognizer) && !(other is UITapGestureRecognizer)
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { distanceAtStart = distance }
            distance = min(
                max(distanceAtStart / Float(gesture.scale), WireframeMap.distances.lowerBound),
                WireframeMap.distances.upperBound)
            placeCamera()
            if gesture.state == .ended || gesture.state == .cancelled { report() }
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            if let id = tree(at: point) {
                onSelect(id)
            } else if let patch = summary(at: point) {
                // A patch: go to where its tile is drawn in full.
                onSelect(nil)
                look(at: MapViewport(around: patch.id))
                report()
            } else {
                onSelect(nil)
            }
        }

        /// The census tree nearest a point in the view, within a finger's width of its trunk line.
        func tree(at point: CGPoint, within reach: CGFloat = 24) -> UUID? {
            guard let view else { return nil }
            var best: (id: UUID, distance: CGFloat)?
            for tree in pickable {
                let a = view.projectPoint(SCNVector3(tree.base))
                let b = view.projectPoint(SCNVector3(tree.top))
                // Behind the camera or past the far plane.
                guard (0...1).contains(a.z), (0...1).contains(b.z) else { continue }
                let d = Self.distance(
                    from: point, toSegment: CGPoint(x: CGFloat(a.x), y: CGFloat(a.y)),
                    CGPoint(x: CGFloat(b.x), y: CGFloat(b.y)))
                if d <= reach, d < (best?.distance ?? .infinity) { best = (tree.id, d) }
            }
            return best?.id
        }

        /// The patch under a point in the view.
        func summary(at point: CGPoint) -> TileSummary? {
            guard let view, !summaryFaces.isEmpty else { return nil }
            let hits = view.hitTest(
                point,
                options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .rootNode: summaryRoot])
            guard let hit = hits.first(where: { $0.node.name == Self.patchFill }) else { return nil }
            let index = hit.faceIndex / 2
            return summaryFaces.indices.contains(index) ? summaryFaces[index] : nil
        }

        static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let length2 = dx * dx + dy * dy
            let t = length2 > 0 ? min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / length2, 0), 1) : 0
            let x = a.x + t * dx - p.x
            let y = a.y + t * dy - p.y
            return (x * x + y * y).squareRoot()
        }
    }
}
