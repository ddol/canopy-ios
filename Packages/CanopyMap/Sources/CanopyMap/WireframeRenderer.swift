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

    static func color(_ status: CountStatus, selected: Bool) -> UIColor {
        if selected { return CanopyColor.survey.uiColor }
        switch status {
        case .detected: return CanopyColor.lineStrong.uiColor
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

    /// Owns the scene: the camera rig, the site nodes (rebuilt when the loaded reference changes) and the census
    /// tree nodes (rebuilt when the trees change, recoloured when the selection does).
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let scene = SCNScene()
        let camera = SCNNode()
        let siteRoot = SCNNode()
        let treeRoot = SCNNode()
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
        private var grounds: [(SiteToScene, Heightfield)] = []
        private var trees: [MapLayers.TreeMarker] = []
        private var treeNodes: [UUID: SCNNode] = [:]
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
            scene.rootNode.addChildNode(treeRoot)
            scene.rootNode.addChildNode(contextRoot)
            placeCamera()
        }

        // MARK: Content

        func apply(_ layers: MapLayers, selection: UUID?) {
            if layers.reference !== reference {
                reference = layers.reference
                rebuildSites()
                rebuildTrees(layers.trees)
                rebuildContext(layers)
            } else {
                if layers.trees != trees { rebuildTrees(layers.trees) }
                if context == nil || context!.routes != layers.routes || context!.boundary != layers.boundary
                    || context!.tiles != layers.tiles
                {
                    rebuildContext(layers)
                }
            }
            if selection != selected {
                let was = selected
                selected = selection
                for id in [was, selection].compactMap({ $0 }) {
                    guard let marker = trees.first(where: { $0.id == id }) else { continue }
                    treeNodes[id]?.childNodes.first?.geometry?.firstMaterial?.diffuse.contents =
                        WireframeTrees.color(marker.status, selected: id == selection)
                }
            }
        }

        private func rebuildSites() {
            for node in siteRoot.childNodes { node.removeFromParentNode() }
            grounds = []
            guard let reference, !reference.sites.isEmpty else { return }
            // Heights are drawn relative to the first site's ground, so the scene stays near y = 0.
            let first = reference.sites[0].vectors
            let heights = first.ground?.z.filter(\.isFinite).sorted() ?? []
            let featureHeights = first.features.compactMap { $0.line.vertices.first?.z }.sorted()
            elevation = heights.isEmpty ? (featureHeights.first ?? 0) : heights[heights.count / 2]
            // One height scale across the loaded sites, so a slope reads the same from one site to the next.
            let allHeights = reference.sites.flatMap { $0.vectors.ground?.z.filter(\.isFinite) ?? [] }
            let low = allHeights.min() ?? elevation
            let high = allHeights.max() ?? elevation + 1
            var seen: Set<String> = []
            for site in reference.sites {
                let transform = SiteToScene(georeference: site.georeference, scene: anchor, elevation: elevation)
                let place: @Sendable (SIMD3<Float>) -> SIMD3<Float> = { transform.place($0) }
                if let ground = site.vectors.ground {
                    grounds.append((transform, ground))
                    siteRoot.addChildNode(
                        VectorMesh(
                            ground: ground, place: place,
                            tint: (low: Self.groundLow, high: Self.groundHigh, range: low...high)
                        )
                        .node(color: .white, fill: true, edgeColor: CanopyColor.lineStrong.uiColor))
                }
                let features = site.vectors.features
                let hasBoxes = features.contains { $0.layer == .boxes || $0.layer == .buildings }
                let wallSurfaces = features.contains { $0.layer == .buildings && $0.line.kind == .wallSurface }
                var buildings = VectorMesh(place: place)
                var streets = VectorMesh(place: place)
                var trees = VectorMesh(place: place)
                for feature in features where seen.insert(feature.line.featureID).inserted {
                    let line = feature.line
                    if line.kind == .sensor || line.kind == .correction { continue }
                    // Box walls stand where the footprint would be extruded; the footprint still gives the roof.
                    if hasBoxes, feature.layer == .footprints {
                        buildings.addLid(line, layer: feature.layer, wallSurfaces: wallSurfaces)
                        continue
                    }
                    switch feature.layer {
                    case .trees:
                        if let tree = GerardusTree(line) { trees.add(tree) }
                    case .footprints, .boxes, .buildings, .observed:
                        buildings.add(line, layer: feature.layer, wallSurfaces: wallSurfaces)
                        buildings.addLid(line, layer: feature.layer, wallSurfaces: wallSurfaces)
                    default:
                        streets.add(line, layer: feature.layer, wallSurfaces: wallSurfaces)
                    }
                }
                siteRoot.addChildNode(
                    buildings.node(color: UIColor(red: 0.75, green: 0.69, blue: 0.55, alpha: 0.55)))
                siteRoot.addChildNode(streets.node(color: UIColor(red: 0.55, green: 0.55, blue: 0.45, alpha: 1)))
                siteRoot.addChildNode(trees.node(color: UIColor(red: 0.42, green: 0.74, blue: 0.24, alpha: 1)))
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

        private func rebuildTrees(_ markers: [MapLayers.TreeMarker]) {
            trees = markers
            for node in treeRoot.childNodes { node.removeFromParentNode() }
            treeNodes = [:]
            for marker in markers where marker.status != .removed {
                let base = scenePoint(marker.location)
                let form = WireframeTrees.form(marker)
                let figure = WireframeTree.figure(form, lean: marker.lean, at: base, detail: 0.5)
                var mesh = VectorMesh(place: { $0 })
                mesh.add(sceneSegments: figure.all)
                let node = mesh.node(color: WireframeTrees.color(marker.status, selected: marker.id == selected))
                node.name = marker.id.uuidString
                // An unseen box round the tree, so a tap on it finds it; lines alone are too thin to hit.
                let width = CGFloat(max(form.crownWidth, 1))
                let box = SCNBox(width: width, height: CGFloat(form.height), length: width, chamferRadius: 0)
                let hidden = SCNMaterial()
                hidden.colorBufferWriteMask = []
                hidden.writesToDepthBuffer = false
                box.materials = [hidden]
                let hit = SCNNode(geometry: box)
                hit.name = marker.id.uuidString
                hit.position = SCNVector3(base + SIMD3(0, Float(form.height / 2), 0))
                node.addChildNode(hit)
                treeRoot.addChildNode(node)
                treeNodes[marker.id] = node
            }
        }

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
            var tiles = VectorMesh(place: { $0 })
            for tile in layers.tiles {
                tiles.add(scenePolyline: tile.corners.map { scenePoint($0) + SIMD3(0, 0.1, 0) }, closed: true)
            }
            contextRoot.addChildNode(tiles.node(color: CanopyColor.lineStrong.uiColor, fill: false))
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
            let hits = view.hitTest(
                point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])
            let id = hits.lazy.compactMap { hit -> UUID? in
                var node: SCNNode? = hit.node
                while let n = node {
                    if let name = n.name, let id = UUID(uuidString: name), self.treeNodes[id] != nil { return id }
                    node = n.parent
                }
                return nil
            }.first
            onSelect(id)
        }
    }
}
