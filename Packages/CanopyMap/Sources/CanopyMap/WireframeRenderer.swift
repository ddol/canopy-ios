import CanopyCapture
import CanopyDesign
import CanopyModel
import CanopyReference
import SceneKit
import SwiftUI
import simd

/// The map with no base map, drawn the way the Mac visualiser draws a site: Gerardus's ground grid, the buildings it
/// reconstructed with their walls and roofs, streets and kerbs as lines, Gerardus's trees as a trunk and crown rings,
/// and the census's trees as the same figure in their status colour, all in 3D. It moves as Apple's map does: drag to
/// move, pinch to zoom, twist to turn, two fingers up or down to tilt, double-tap to zoom in, two-finger tap to zoom
/// out, tap a tree to select it.
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
            Text("Pinch to zoom · Twist to turn · Two fingers up or down to tilt · Tap a tree")
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

    /// The census's trees as one mesh per look, and where each stands for picking by a tap: the work of drawing them,
    /// done off the main actor. The meshes are plain arrays of values.
    struct Batches: @unchecked Sendable {
        var meshes: [Look: VectorMesh] = [:]
        var pickable: [(id: UUID, base: SIMD3<Float>, top: SIMD3<Float>)] = []
    }

    /// Rings of 16 sides; 8 for detected trees when hundreds are drawn, which halves a neighbourhood's lines.
    static func detail(_ marker: MapLayers.TreeMarker, among count: Int) -> Float {
        marker.status == .detected && count > 400 ? 0.25 : 0.5
    }

    /// A census tree's figure standing at `base`, from its fitted profile, the shape the player gave it, or its
    /// measurements, and its height.
    static func figure(
        _ marker: MapLayers.TreeMarker, at base: SIMD3<Float>, forms: [String: TreeForm],
        profiles: [String: TreeProfile], detail: Float
    ) -> (figure: WireframeTree.Figure, height: Double) {
        let key = MapLayers.censusWireframeID(marker.id)
        let profile = profiles[key]
        let form = profile?.form ?? forms[key] ?? Self.form(marker)
        let figure =
            profile.map { WireframeTree.figure($0, lean: marker.lean, at: base, detail: detail) }
            ?? WireframeTree.figure(form, lean: marker.lean, at: base, detail: detail)
        return (figure, form.height)
    }

    /// Every tree but the removed ones, batched by look. `place` puts a map point on the scene's ground.
    static func batches(
        _ markers: [MapLayers.TreeMarker], forms: [String: TreeForm], profiles: [String: TreeProfile],
        place: (GeoPoint) -> SIMD3<Float>
    ) -> Batches {
        var batches = Batches()
        for marker in markers where marker.status != .removed {
            let base = place(marker.location)
            let (figure, height) = Self.figure(
                marker, at: base, forms: forms, profiles: profiles, detail: detail(marker, among: markers.count))
            batches.pickable.append((marker.id, base, base + SIMD3(0, Float(height), 0)))
            let look = Look(status: marker.status, faint: marker.inSurveyedCell)
            batches.meshes[look, default: VectorMesh(place: { $0 })].add(sceneSegments: figure.all)
        }
        return batches
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

    func makeCoordinator() -> Coordinator { Coordinator(anchor: viewport.center) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let coordinator = context.coordinator
        view.backgroundColor = CanopyColor.surface100.uiColor
        #if targetEnvironment(simulator)
            // The simulator draws with the Mac's GPU, which on an Intel Mac is small and shared: draw less there.
            view.antialiasingMode = .none
            view.preferredFramesPerSecond = 30
        #else
            view.antialiasingMode = .multisampling4X
        #endif
        view.allowsCameraControl = false
        view.scene = coordinator.scene
        view.pointOfView = coordinator.camera
        let touch = MapTouchGesture(target: coordinator, action: #selector(Coordinator.touch(_:)))
        let zoomIn = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.zoomIn(_:)))
        zoomIn.numberOfTapsRequired = 2
        let zoomOut = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.zoomOut(_:)))
        zoomOut.numberOfTouchesRequired = 2
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: zoomIn)
        for gesture in [touch, zoomIn, zoomOut, tap] as [UIGestureRecognizer] {
            gesture.delegate = coordinator
            view.addGestureRecognizer(gesture)
        }
        coordinator.view = view
        coordinator.onViewportChange = onViewportChange
        coordinator.onSelect = { selection = $0 }
        coordinator.look(at: viewport)
        // Say where the map opens once SwiftUI has finished this update, so it knows how much to draw in full: until
        // a region is known everything is.
        DispatchQueue.main.async { coordinator.report() }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onViewportChange = onViewportChange
        coordinator.onSelect = { selection = $0 }
        MapTiming.measure("apply 3D") { coordinator.apply(layers, selection: selection) }
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
        /// The selected tree, drawn again over its batch in the highlight colour, so selecting redraws only it.
        let highlightRoot = SCNNode()
        let summaryRoot = SCNNode()
        let contextRoot = SCNNode()
        /// The scene's origin on the map.
        let anchor: LocalFrame
        weak var view: SCNView?
        var onViewportChange: @MainActor (MapViewport) -> Void = { _ in }
        var onSelect: @MainActor (UUID?) -> Void = { _ in }
        var focusID: UUID?

        /// Where the camera is (`CameraRig`).
        var rig = CameraRig(
            target: .zero, distance: 300, tilt: 55 * .pi / 180, azimuth: 0, size: CGSize(width: 390, height: 700))
        /// Where the gesture under way started: the rig, the fingers, and the ground point between them, which
        /// stays under the fingers as they move. Started again whenever a finger lands or lifts.
        private var gestureStart: (rig: CameraRig, points: [CGPoint], anchor: SIMD3<Float>?, fingers: Int)?
        private var intent = TwoFingerIntent.undecided
        /// The last tenth of a second of a one-finger drag, for the glide after it.
        private var samples: [(time: CFTimeInterval, point: CGPoint)] = []
        private var glide: CADisplayLink?
        private var glideVelocity = CGPoint.zero
        private var glideTime: CFTimeInterval = 0

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
        /// The sites to draw, and those whose geometry is being made off the main actor; a site made for an older
        /// reference (`siteGeneration`) or no longer wanted is dropped when it arrives.
        private var wantedSites: Set<String> = []
        private var siteBuilds: [String: Task<Void, Never>] = [:]
        private var siteGeneration = 0
        /// The trees being made off the main actor; only the latest (`treeGeneration`) is drawn.
        private var treeBuild: Task<Void, Never>?
        private var treeGeneration = 0
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
        /// Which of the sites' parts are shown: the ground, and the vectors (buildings, streets, Gerardus's trees).
        private var visibility = MapLayers.Visibility()
        private var context: (routes: [MapLayers.RouteLine], boundary: [[GeoPoint]], tiles: [MapLayers.TileOutline])?

        init(anchor: GeoPoint) {
            self.anchor = LocalFrame(origin: anchor)
            super.init()
            camera.camera = SCNCamera()
            camera.camera?.zNear = 0.1
            camera.camera?.zFar = 60000
            camera.camera?.automaticallyAdjustsZRange = true
            camera.camera?.fieldOfView = CGFloat(rig.fieldOfView)
            scene.rootNode.addChildNode(camera)
            scene.rootNode.addChildNode(siteRoot)
            scene.rootNode.addChildNode(siteTreeRoot)
            scene.rootNode.addChildNode(treeRoot)
            scene.rootNode.addChildNode(highlightRoot)
            scene.rootNode.addChildNode(summaryRoot)
            scene.rootNode.addChildNode(contextRoot)
            placeCamera()
        }

        // MARK: Content

        func apply(_ layers: MapLayers, selection: UUID?) {
            if layers.visibility != visibility {
                visibility = layers.visibility
                for node in siteNodes.values { applyVisibility(to: node) }
                siteTreeRoot.isHidden = !visibility.vectors
            }
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
            if layers.trees != trees || formsChanged {
                rebuildTrees(layers.trees)
            } else if selectionChanged {
                drawHighlight()
            }
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
            siteGeneration += 1
            for build in siteBuilds.values { build.cancel() }
            siteBuilds = [:]
            wantedSites = []
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

        /// Draws exactly these sites: takes away the rest at once, and adds the ones not drawn yet as their geometry,
        /// made off the main actor (a site's buildings and ground are tens of thousands of vertices), arrives.
        private func showSites(_ sites: [MapLayers.Reference.Site]) {
            guard let reference else { return }
            let wanted = Dictionary(
                sites.compactMap { site in
                    reference.sites.firstIndex { $0.token == site.token }.map { (Self.key(site, index: $0), site) }
                }, uniquingKeysWith: { a, _ in a })
            wantedSites = Set(wanted.keys)
            for key in Array(siteNodes.keys) where wanted[key] == nil {
                siteNodes.removeValue(forKey: key)?.removeFromParentNode()
                siteTreeNodes.removeValue(forKey: key)?.removeFromParentNode()
            }
            for key in Array(siteBuilds.keys) where wanted[key] == nil {
                siteBuilds.removeValue(forKey: key)?.cancel()
            }
            let generation = siteGeneration
            let owners = owners
            let groundRange = groundRange
            let forms = treeForms
            for (key, site) in wanted where siteNodes[key] == nil && siteBuilds[key] == nil {
                let transform = transform(site)
                siteBuilds[key] = Task { [weak self] in
                    let meshes = await Task.detached(priority: .userInitiated) {
                        Self.siteMeshes(
                            site, key: key, owners: owners, transform: transform, groundRange: groundRange, forms: forms
                        )
                    }.value
                    guard let self, generation == self.siteGeneration, !Task.isCancelled else { return }
                    self.siteBuilds[key] = nil
                    guard self.wantedSites.contains(key), self.siteNodes[key] == nil else { return }
                    MapTiming.measure("3D site") { self.install(meshes, key: key) }
                }
            }
        }

        private func install(_ meshes: SiteMeshes, key: String) {
            let node = SCNNode()
            if let ground = meshes.ground {
                let mesh = ground.node(color: .white, fill: true, edgeColor: CanopyColor.lineStrong.uiColor)
                mesh.name = Part.ground.rawValue
                node.addChildNode(mesh)
            }
            let buildings = SCNNode()
            buildings.name = Part.buildings.rawValue
            buildings.addChildNode(meshes.walls.node(color: Self.wallColor))
            buildings.addChildNode(meshes.roofs.node(color: Self.roofColor))
            node.addChildNode(buildings)
            let streetNode = meshes.streets.node(color: UIColor(red: 0.55, green: 0.55, blue: 0.45, alpha: 1))
            streetNode.name = Part.streets.rawValue
            node.addChildNode(streetNode)
            applyVisibility(to: node)
            siteRoot.addChildNode(node)
            siteNodes[key] = node
            let trees = meshes.trees.node(color: Self.siteTreeColor)
            siteTreeRoot.addChildNode(trees)
            siteTreeNodes[key] = trees
        }

        private func transform(_ site: MapLayers.Reference.Site) -> SiteToScene {
            SiteToScene(georeference: site.georeference, scene: anchor, elevation: elevation)
        }

        /// A site's geometry, of the features it draws: its ground, its buildings (the ones Gerardus reconstructed, roofs
        /// apart from walls (`SiteBuildings`); DataSF's boxes are never drawn over them), its streets, and its Gerardus
        /// trees.
        struct SiteMeshes: @unchecked Sendable {
            var ground: VectorMesh?
            var walls: VectorMesh
            var roofs: VectorMesh
            var streets: VectorMesh
            var trees: VectorMesh
        }

        nonisolated static func siteMeshes(
            _ site: MapLayers.Reference.Site, key: String, owners: [String: String], transform: SiteToScene,
            groundRange: ClosedRange<Float>, forms: [String: TreeForm]
        ) -> SiteMeshes {
            let place: @Sendable (SIMD3<Float>) -> SIMD3<Float> = { transform.place($0) }
            let ground = site.vectors.ground.map {
                VectorMesh(ground: $0, place: place, tint: (low: groundLow, high: groundHigh, range: groundRange))
            }
            let features = site.vectors.features
            let reconstructed = SiteBuildings.reconstructed(features)
            let wallSurfaces = features.contains { $0.layer == .buildings && $0.line.kind == .wallSurface }
            var walls = VectorMesh(place: place)
            var roofs = VectorMesh(place: place)
            var streets = VectorMesh(place: place)
            for feature in features where owners[feature.line.featureID] == key {
                let line = feature.line
                if line.kind == .sensor || line.kind == .correction || feature.layer == .trees { continue }
                if let drawn = SiteBuildings.drawn(feature, reconstructed: reconstructed) {
                    switch drawn {
                    case .asSent where line.kind == .roofPlane:
                        roofs.add(line, layer: feature.layer, wallSurfaces: wallSurfaces)
                    case .asSent:
                        walls.add(line, layer: feature.layer, wallSurfaces: wallSurfaces)
                        walls.addLid(line, layer: feature.layer, wallSurfaces: wallSurfaces)
                    case .outline:
                        walls.add(outline: line)
                    }
                    continue
                }
                switch feature.layer {
                case .boxes, .footprints, .buildings:
                    continue
                case .observed where line.kind != .pole:
                    continue
                default:
                    streets.add(line, layer: feature.layer, wallSurfaces: wallSurfaces)
                }
            }
            return SiteMeshes(
                ground: ground, walls: walls, roofs: roofs, streets: streets,
                trees: siteTrees(site, key: key, owners: owners, transform: transform, forms: forms))
        }

        /// The parts of a site's node, by name, so the map's layer switches show and hide them.
        enum Part: String {
            case ground, buildings, streets
        }

        static let wallColor = UIColor(red: 0.75, green: 0.69, blue: 0.55, alpha: 0.6)
        static let roofColor = UIColor(red: 0.78, green: 0.52, blue: 0.42, alpha: 0.85)
        static let siteTreeColor = UIColor(red: 0.42, green: 0.74, blue: 0.24, alpha: 1)

        /// Shows a site's ground with the ground switch, and its buildings and streets with the vectors switch.
        private func applyVisibility(to node: SCNNode) {
            node.childNode(withName: Part.ground.rawValue, recursively: false)?.isHidden = !visibility.ground
            for part in [Part.buildings, .streets] {
                node.childNode(withName: part.rawValue, recursively: false)?.isHidden = !visibility.vectors
            }
        }

        /// A site's Gerardus trees, each in the shape the player gave it in AR when they did.
        nonisolated static func siteTrees(
            _ site: MapLayers.Reference.Site, key: String, owners: [String: String], transform: SiteToScene,
            forms: [String: TreeForm]
        ) -> VectorMesh {
            var trees = VectorMesh(place: { transform.place($0) })
            for feature in site.vectors.features where feature.layer == .trees && owners[feature.line.featureID] == key
            {
                guard var tree = GerardusTree(feature.line) else { continue }
                if let form = forms[tree.id] { tree.form = form }
                trees.add(tree)
            }
            return trees
        }

        /// Draws the drawn sites' trees again, after a shape changed.
        private func redrawSiteTrees() {
            guard let reference else { return }
            for (index, site) in reference.sites.enumerated() {
                let key = Self.key(site, index: index)
                guard let old = siteTreeNodes[key] else { continue }
                old.removeFromParentNode()
                let node = Self.siteTrees(
                    site, key: key, owners: owners, transform: transform(site), forms: treeForms
                ).node(color: Self.siteTreeColor)
                siteTreeRoot.addChildNode(node)
                siteTreeNodes[key] = node
            }
        }

        /// Scene coordinates of a map point on the ground: the site ground where a loaded site has it, else y = 0.
        private func scenePoint(_ geo: GeoPoint) -> SIMD3<Float> {
            Self.scenePoint(geo, anchor: anchor, grounds: grounds)
        }

        nonisolated static func scenePoint(
            _ geo: GeoPoint, anchor: LocalFrame, grounds: [(SiteToScene, Heightfield)]
        ) -> SIMD3<Float> {
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

        /// The census's trees, batched into one mesh per colour so hundreds of them are a handful of draw calls. The
        /// figures are made off the main actor (a neighbourhood of detected trees is a quarter of a million vertices), and
        /// the trees drawn before stay until they arrive.
        private func rebuildTrees(_ markers: [MapLayers.TreeMarker]) {
            trees = markers
            treeGeneration += 1
            let generation = treeGeneration
            let anchor = anchor
            let grounds = grounds
            let forms = treeForms
            let profiles = treeProfiles
            treeBuild?.cancel()
            treeBuild = Task { [weak self] in
                let batches = await Task.detached(priority: .userInitiated) {
                    WireframeTrees.batches(markers, forms: forms, profiles: profiles) {
                        Self.scenePoint($0, anchor: anchor, grounds: grounds)
                    }
                }.value
                guard let self, generation == self.treeGeneration, !Task.isCancelled else { return }
                MapTiming.measure("3D trees") { self.install(batches) }
            }
        }

        private func install(_ batches: WireframeTrees.Batches) {
            for node in treeRoot.childNodes { node.removeFromParentNode() }
            pickable = batches.pickable
            for (look, mesh) in batches.meshes {
                treeRoot.addChildNode(mesh.node(color: look.color, fill: false))
            }
            drawHighlight()
        }

        /// The selected tree in the highlight colour, over everything else.
        private func drawHighlight() {
            for node in highlightRoot.childNodes { node.removeFromParentNode() }
            guard let selected, let marker = trees.first(where: { $0.id == selected }), marker.status != .removed
            else { return }
            let (figure, _) = WireframeTrees.figure(
                marker, at: scenePoint(marker.location), forms: treeForms, profiles: treeProfiles, detail: 0.5)
            var mesh = VectorMesh(place: { $0 })
            mesh.add(sceneSegments: figure.all)
            let node = mesh.node(color: WireframeTrees.selectedColor, fill: false)
            node.enumerateHierarchy { child, _ in
                child.renderingOrder = 10
                child.geometry?.firstMaterial?.readsFromDepthBuffer = false
            }
            highlightRoot.addChildNode(node)
        }

        /// The patches for the tiles not drawn in full: each filled in a tint from the background to the brand green
        /// by how many trees it holds, the surveyed ones outlined in green and those detected in full in dark ink.
        private func rebuildSummaries(_ patches: [TileSummary]) {
            summaries = patches
            summaryFaces = []
            for node in summaryRoot.childNodes { node.removeFromParentNode() }
            guard !patches.isEmpty else { return }
            var fill = VectorMesh(place: { $0 })
            var surveyed = VectorMesh(place: { $0 })
            var detected = VectorMesh(place: { $0 })
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
                } else if patch.detectedInFull {
                    detected.add(scenePolyline: corners.map { $0 + lift }, closed: true)
                }
            }
            let node = fill.node(
                color: .white, fill: true, edgeColor: CanopyColor.lineStrong.uiColor.withAlphaComponent(0.5))
            node.childNodes.first?.name = Self.patchFill
            summaryRoot.addChildNode(node)
            if !surveyed.isEmpty {
                summaryRoot.addChildNode(surveyed.node(color: CanopyColor.brand.uiColor, fill: false))
            }
            if !detected.isEmpty {
                summaryRoot.addChildNode(
                    detected.node(color: CanopyColor.ink.uiColor.withAlphaComponent(0.7), fill: false))
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
        nonisolated static let groundLow = SIMD4<Float>(0.22, 0.32, 0.26, 1)
        nonisolated static let groundHigh = SIMD4<Float>(0.72, 0.76, 0.62, 1)

        // MARK: Camera

        func look(at viewport: MapViewport) {
            stopGliding()
            rig.target = scenePoint(viewport.center)
            let halfSpan = Float(viewport.cornerDistance / 2.squareRoot())
            rig.distance = halfSpan / tan(rig.fieldOfView / 2 * .pi / 180) * 1.1
            rig = rig.clamped()
            placeCamera()
        }

        private func placeCamera() {
            if let size = view?.bounds.size, size.width > 0 { rig.size = size }
            camera.position = SCNVector3(rig.position)
            camera.look(at: SCNVector3(rig.target))
        }

        /// The region in view, from the target and the distance.
        var currentViewport: MapViewport {
            let target = rig.target
            let centre = anchor.geoPoint(of: ENU(east: Double(target.x), north: Double(-target.z), up: 0)).point
            let halfSpan = Double(rig.distance) * tan(Double(rig.fieldOfView) / 2 * .pi / 180)
            return MapViewport(center: centre, radius: halfSpan)
        }

        func report() {
            onViewportChange(currentViewport)
        }

        // MARK: Gestures, as on Apple's map

        /// One finger drags the map, and it glides on when let go. Two fingers pinch to zoom and twist to turn about
        /// the point between them, which stays under them as they move; both moving up or down together tilt it.
        @objc func touch(_ gesture: MapTouchGesture) {
            let points = gesture.points
            switch gesture.state {
            case .began:
                stopGliding()
                samples = []
                // From where the fingers touched, not where they had moved to by the time it began: the map catches
                // up with them, and the ground under each stays under it.
                begin(gesture.origins.count == points.count ? gesture.origins : points, fingers: gesture.fingers)
                follow(points)
            case .changed:
                if gestureStart?.fingers != gesture.fingers {
                    begin(gesture.origins.count == points.count ? gesture.origins : points, fingers: gesture.fingers)
                }
                follow(points)
                if points.count == 1 { remember(points[0]) } else { samples = [] }
            case .ended, .cancelled:
                let velocity = gesture.state == .ended ? releaseVelocity() : .zero
                gestureStart = nil
                if hypot(velocity.x, velocity.y) > 150 {
                    startGliding(velocity)
                } else {
                    report()
                }
            default:
                break
            }
        }

        private func begin(_ points: [CGPoint], fingers: Int) {
            if let size = view?.bounds.size, size.width > 0 { rig.size = size }
            gestureStart = (rig, points, rig.ground(at: TwoFingerIntent.centroid(points)), fingers)
            intent = .undecided
        }

        private func follow(_ points: [CGPoint]) {
            guard let start = gestureStart, !points.isEmpty, !start.points.isEmpty else { return }
            if points.count == 1 || start.points.count == 1 {
                rig = Self.drag(start.rig, anchor: start.anchor, from: start.points[0], to: points[0])
            } else {
                if intent == .undecided { intent = TwoFingerIntent.classify(from: start.points, to: points) }
                switch intent {
                case .undecided: return
                case .tilt: rig = Self.tilt(start.rig, from: start.points, to: points)
                case .transform: rig = Self.transform(start.rig, anchor: start.anchor, from: start.points, to: points)
                }
            }
            placeCamera()
        }

        /// The rig after a finger dragged from `start` to `now`: the ground point first touched (`anchor`) stays under
        /// the finger. Near the horizon, where that point is too far off to follow, the map slides by the ground's
        /// scale at the target instead.
        nonisolated static func drag(
            _ rig: CameraRig, anchor: SIMD3<Float>?, from start: CGPoint, to now: CGPoint
        ) -> CameraRig {
            if let anchor, rig.ground(at: now) != nil { return rig.keeping(anchor, under: now) }
            let forward = SIMD3<Float>(-sin(rig.azimuth), 0, -cos(rig.azimuth))
            let right = SIMD3<Float>(cos(rig.azimuth), 0, -sin(rig.azimuth))
            let scale = rig.metresPerPoint
            var moved = rig
            moved.target += -right * Float(now.x - start.x) * scale + forward * Float(now.y - start.y) * scale
            return moved
        }

        /// The rig after two fingers moved up or down together: up tilts the view towards the horizon.
        nonisolated static func tilt(_ rig: CameraRig, from start: [CGPoint], to now: [CGPoint]) -> CameraRig {
            var tilted = rig
            tilted.tilt += Float(TwoFingerIntent.centroid(now).y - TwoFingerIntent.centroid(start).y) * 0.006
            return tilted.clamped()
        }

        /// The rig after two fingers pinched, twisted and moved: zoomed by how much their spacing changed, turned as
        /// far as they turned past a small threshold (`TwoFingerIntent.turn`), with the ground point first between them
        /// (`anchor`) still between them.
        nonisolated static func transform(
            _ rig: CameraRig, anchor: SIMD3<Float>?, from start: [CGPoint], to now: [CGPoint]
        ) -> CameraRig {
            var moved = rig
            let before = TwoFingerIntent.spacing(start)
            let after = TwoFingerIntent.spacing(now)
            if before > 1, after > 1 { moved.distance = rig.distance * Float(before / after) }
            moved.azimuth = rig.azimuth + Float(TwoFingerIntent.turn(TwoFingerIntent.angle(from: start, to: now)))
            moved = moved.clamped()
            if let anchor { moved = moved.keeping(anchor, under: TwoFingerIntent.centroid(now)) }
            return moved
        }

        /// Double tap: in by half, keeping the tapped point where it is.
        @objc func zoomIn(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            rig.size = view.bounds.size
            var next = rig
            next.distance /= 2
            next = next.clamped()
            if let anchor = rig.ground(at: point) { next = next.keeping(anchor, under: point) }
            animate(to: next)
        }

        /// Two-finger tap: out by double.
        @objc func zoomOut(_ gesture: UITapGestureRecognizer) {
            var next = rig
            next.distance *= 2
            animate(to: next.clamped())
        }

        private func animate(to next: CameraRig) {
            stopGliding()
            rig = next
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.3
            placeCamera()
            SCNTransaction.commit()
            report()
        }

        private func remember(_ point: CGPoint) {
            let now = CACurrentMediaTime()
            samples.append((now, point))
            samples.removeAll { now - $0.time > 0.1 }
        }

        /// How fast the finger was moving as it lifted, in points a second; nothing when it had stopped.
        private func releaseVelocity() -> CGPoint {
            guard let first = samples.first, let last = samples.last, last.time - first.time > 0.01,
                CACurrentMediaTime() - last.time < 0.08
            else { return .zero }
            let seconds = CGFloat(last.time - first.time)
            return CGPoint(x: (last.point.x - first.point.x) / seconds, y: (last.point.y - first.point.y) / seconds)
        }

        private func startGliding(_ velocity: CGPoint) {
            stopGliding()
            glideVelocity = velocity
            glideTime = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(glideStep(_:)))
            link.add(to: .main, forMode: .common)
            glide = link
        }

        /// The map gliding on after a flick, slowing as Apple's map does, until a finger stops it.
        @objc private func glideStep(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            let seconds = CGFloat(now - glideTime)
            glideTime = now
            let step = CGPoint(x: glideVelocity.x * seconds, y: glideVelocity.y * seconds)
            rig = Self.drag(rig, anchor: nil, from: .zero, to: step)
            placeCamera()
            let slowing = exp(-seconds / 0.325)
            glideVelocity = CGPoint(x: glideVelocity.x * slowing, y: glideVelocity.y * slowing)
            if hypot(glideVelocity.x, glideVelocity.y) < 20 {
                stopGliding()
                report()
            }
        }

        private func stopGliding() {
            guard let glide else { return }
            glide.invalidate()
            self.glide = nil
        }

        /// A finger landing stops a glide, as on Apple's map.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            MainActor.assumeIsolated { stopGliding() }
            return true
        }

        /// The map gesture and the taps each stand alone.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            false
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
