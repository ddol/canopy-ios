import CanopyCapture
import CanopyDesign
import CanopyModel
import SceneKit
import SwiftUI
import simd

/// What is drawn over a saved scan's triangles: the tree's rings, the DBH on record as a circle 1.37 m up, and
/// Gerardus's tree for the place. In the scan's frame (x east, y up, z south; see `ScanAlignment`).
struct ScanAlignmentOverlay: Equatable {
    var profile: TreeProfile
    var lean: Lean?
    var groundHeight: Double
    var selected: TreeSection.ID?
    /// The tree's DBH on record, in metres.
    var dbh: Double?
    var vectorForm: TreeForm?
    var vectorBase: SIMD3<Float>?
    /// The aerial lidar points round the tree.
    var cloud: CanopyCloud?
    /// The crown the points are set against, while it is being set: points inside it are drawn apart.
    var crown: CrownShape?

    var trunkBase: SIMD3<Float> { SIMD3(0, Float(groundHeight), 0) }
    /// What the camera turns about: the trunk's axis at breast height.
    var target: SIMD3<Float> { trunkBase + SIMD3(0, Float(DBH.standardHeight), 0) }
}

/// Aerial lidar points in a scan's frame, compared by identity: a few tens of thousands of points are not compared
/// point by point each time the view updates.
struct CanopyCloud: Equatable, Sendable {
    let id = UUID()
    let points: [SIMD3<Float>]

    static func == (a: CanopyCloud, b: CanopyCloud) -> Bool { a.id == b.id }
}

/// Where the align view's camera is: looking at `target` from `distance` metres, `elevation` radians above it, turned
/// `azimuth` radians from the south side (a larger azimuth carries the camera east, and turns the scene clockwise
/// as seen from above). The camera's up is always toward the sky, so the ground stays level and down however the
/// view is turned: there is no roll to get wrong. Scene axes are the scan's: x east, y up, z south.
nonisolated struct ScanOrbit: Equatable, Sendable {
    var target: SIMD3<Float>
    var distance: Float
    var elevation: Float
    var azimuth: Float = 0

    /// How far the camera may look down on the trunk (90°: from straight above) or up at it from below the point it
    /// turns about, in degrees. Straight down itself would leave the camera without a heading.
    static let elevations: ClosedRange<Float> = (-20 * .pi / 180)...(89 * .pi / 180)
    static let distances: ClosedRange<Float> = 0.25...150
    /// Radians the view turns for a point of finger travel.
    static let turnPerPoint: Float = 0.008

    /// 3.2 m from the trunk on its south side, a little above breast height, looking at it.
    static func home(_ target: SIMD3<Float>) -> ScanOrbit {
        ScanOrbit(target: target, distance: simd_length(SIMD2<Float>(0.8, 3.2)), elevation: atan2(0.8, 3.2))
    }

    /// `distance` metres off `target` on the south side, a little above it: to take in a whole crown.
    static func framing(_ target: SIMD3<Float>, distance: Float) -> ScanOrbit {
        ScanOrbit(
            target: target, distance: distance * simd_length(SIMD2<Float>(0.3, 1)), elevation: atan2(0.3, 1))
    }

    var position: SIMD3<Float> {
        target + SIMD3(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation)) * distance
    }

    /// The camera's transform: at `position`, looking at the target, its up toward the sky.
    var transform: simd_float4x4 {
        let back = simd_normalize(position - target)
        let right = SIMD3(cos(azimuth), 0, -sin(azimuth))
        let up = simd_cross(back, right)
        return simd_float4x4(
            SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(position, 1))
    }

    func clamped() -> ScanOrbit {
        var orbit = self
        orbit.elevation = min(max(elevation, Self.elevations.lowerBound), Self.elevations.upperBound)
        orbit.distance = min(max(distance, Self.distances.lowerBound), Self.distances.upperBound)
        return orbit
    }

    /// One finger dragged by `translation` points: round the trunk for a drag sideways (the scan turning with the
    /// finger, as if pushed round), over or under it for a drag down or up.
    func orbiting(by translation: CGPoint) -> ScanOrbit {
        var orbit = self
        orbit.azimuth -= Float(translation.x) * Self.turnPerPoint
        orbit.elevation += Float(translation.y) * Self.turnPerPoint
        return orbit.clamped()
    }

    /// Two fingers twisted `angle` radians, clockwise on screen positive: the scene turns with them about the upright
    /// pole through the target.
    func twisting(by angle: Float) -> ScanOrbit {
        var orbit = self
        orbit.azimuth += angle
        return orbit
    }

    /// Two fingers pinched to `scale` times their spacing: closer as they spread.
    func pinching(by scale: CGFloat) -> ScanOrbit {
        var orbit = self
        orbit.distance /= Float(max(scale, 0.01))
        return orbit.clamped()
    }

    /// Two fingers dragged by `translation` points in a view `height` points tall with a `fieldOfView`° vertical
    /// field: the scan follows them, sideways along the ground and up or down the trunk.
    func sliding(by translation: CGPoint, height: CGFloat, fieldOfView: Float) -> ScanOrbit {
        var orbit = self
        let metresPerPoint = distance * 2 * tan(fieldOfView / 2 * .pi / 180) / Float(max(height, 1))
        let right = SIMD3(cos(azimuth), 0, -sin(azimuth))
        orbit.target +=
            -right * Float(translation.x) * metresPerPoint
            + SIMD3(0, 1, 0) * Float(translation.y) * metresPerPoint
        return orbit
    }
}

/// The view's camera, for the controls: where the screen's right and "away" point on the ground, so a ring moves the
/// way the arrows say whichever side the player has turned the view to; and the orbit the gestures move.
@MainActor
final class ScanAlignmentCamera {
    fileprivate weak var view: SCNView?
    /// What the view turns about when it opens: the trunk at breast height.
    fileprivate var homeTarget: SIMD3<Float>?
    fileprivate var orbit: ScanOrbit?

    /// The screen's right and the direction into the screen, on the ground (scene x and z), each a unit vector.
    var groundAxes: (right: SIMD2<Float>, away: SIMD2<Float>) {
        guard let pov = view?.pointOfView else { return (SIMD2(1, 0), SIMD2(0, -1)) }
        return Self.groundAxes(right: pov.simdWorldRight, front: pov.simdWorldFront, up: pov.simdWorldUp)
    }

    /// `groundAxes` from the camera's own axes in the scene. Looking straight down, the view has no direction on the
    /// ground, so "away" is the screen's up instead.
    nonisolated static func groundAxes(
        right: SIMD3<Float>, front: SIMD3<Float>, up: SIMD3<Float>
    ) -> (right: SIMD2<Float>, away: SIMD2<Float>) {
        let flatRight = SIMD2(right.x, right.z)
        guard simd_length(flatRight) > 1e-3 else { return (SIMD2(1, 0), SIMD2(0, -1)) }
        let unitRight = simd_normalize(flatRight)
        // Into the screen when the view looks across the ground at all, else the screen's up; a quarter turn
        // anticlockwise from the right, seen from above (scene x east, z south), when neither shows.
        let away =
            [SIMD2(front.x, front.z), SIMD2(up.x, up.z)].first { simd_length($0) > 1e-3 }.map { simd_normalize($0) }
            ?? SIMD2(unitRight.y, -unitRight.x)
        return (unitRight, away)
    }

    /// Puts the camera where `orbit` says, gliding there when `animated`.
    fileprivate func place(_ next: ScanOrbit, animated: Bool = false) {
        orbit = next
        guard let pov = view?.pointOfView else { return }
        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.35
        }
        pov.simdTransform = next.transform
        if animated { SCNTransaction.commit() }
    }

    /// Back to where the view started.
    func reset() {
        guard let target = homeTarget ?? orbit?.target else { return }
        place(.home(target), animated: true)
    }

    /// Turns the view about `target` from `distance` metres away on the south side, a little above it: to take in a
    /// whole crown.
    func frame(_ target: SIMD3<Float>, distance: Float) {
        place(.framing(target, distance: distance), animated: true)
    }

    // MARK: Gestures

    /// Where the gesture under way started.
    private var start: ScanOrbit?
    private var twistStart: ScanOrbit?

    /// One finger: round and over the trunk. It stands still while two fingers are down, and carries on from where
    /// they left the view when one of them lifts.
    fileprivate func orbitGesture(_ recogniser: UIPanGestureRecognizer) {
        guard let orbit else { return }
        switch recogniser.state {
        case .began, .changed:
            guard twistStart == nil, recogniser.numberOfTouches < 2 else {
                start = nil
                return
            }
            guard let start else {
                start = orbit
                recogniser.setTranslation(.zero, in: recogniser.view)
                return
            }
            place(start.orbiting(by: recogniser.translation(in: recogniser.view)))
        default:
            start = nil
        }
    }

    /// Two fingers: pinch, twist and slide at once, each from where the fingers were when they last landed.
    fileprivate func twoFingers(
        pinch: UIPinchGestureRecognizer, twist: UIRotationGestureRecognizer, slide: UIPanGestureRecognizer
    ) {
        guard let orbit, let view else { return }
        let states = [pinch.state, twist.state, slide.state]
        if !states.contains(where: { $0 == .began || $0 == .changed }) {
            twistStart = nil
            return
        }
        if twistStart == nil {
            twistStart = orbit
            pinch.scale = 1
            twist.rotation = 0
            slide.setTranslation(.zero, in: view)
        }
        guard let from = twistStart else { return }
        let fov = Float(view.pointOfView?.camera?.fieldOfView ?? 50)
        // As on the 3D map, a small twist leaves the heading alone so a pinch does not turn the view by accident.
        let angle = Float(TwoFingerTurn.turn(twist.rotation))
        place(
            from.pinching(by: pinch.scale).twisting(by: angle)
                .sliding(by: slide.translation(in: view), height: view.bounds.height, fieldOfView: fov))
    }
}

/// A twist smaller than this, in radians (about 6°), leaves the view's heading alone, so a pinch does not turn it by
/// accident; past it the view turns with the fingers, less this much, so it starts turning smoothly.
enum TwoFingerTurn {
    static let threshold: CGFloat = 0.1

    static func turn(_ angle: CGFloat) -> CGFloat {
        abs(angle) <= threshold ? 0 : angle - (angle > 0 ? threshold : -threshold)
    }
}

/// A scan's triangles ready to draw: a normal at each vertex from the faces round it, since the evidence holds none,
/// and each edge once. A real scan runs to 100,000 triangles and more, so this is worked out off the main thread when
/// the scan opens.
nonisolated struct ScanSurface: Sendable {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var triangles: [UInt32]
    /// Two indices per edge.
    var edges: [UInt32]

    init(_ mesh: Mesh) {
        positions = mesh.positions
        triangles = mesh.indices
        var normals = [SIMD3<Float>](repeating: .zero, count: mesh.positions.count)
        var edges: [UInt32] = []
        var seen = Set<UInt64>(minimumCapacity: mesh.indices.count / 2)
        func edge(_ p: UInt32, _ q: UInt32) {
            guard seen.insert(UInt64(min(p, q)) << 32 | UInt64(max(p, q))).inserted else { return }
            edges.append(p)
            edges.append(q)
        }
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let (i, j, k) = (mesh.indices[t], mesh.indices[t + 1], mesh.indices[t + 2])
            let a = mesh.positions[Int(i)]
            let normal = simd_cross(mesh.positions[Int(j)] - a, mesh.positions[Int(k)] - a)
            normals[Int(i)] += normal
            normals[Int(j)] += normal
            normals[Int(k)] += normal
            edge(i, j)
            edge(j, k)
            edge(k, i)
        }
        self.normals = normals.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
        self.edges = edges
    }

    var isEmpty: Bool { triangles.isEmpty }
}

/// The scan's triangles in 3D with the overlay over them. The camera orbits the trunk (`ScanOrbit`): drag to turn round
/// it and over or under it, pinch to zoom, twist two fingers to turn it about its upright, and drag two fingers to
/// slide it. Tapping near a ring picks it.
///
/// The 3D map's `CameraRig` is not used: it keeps the ground under a finger and starts 12 m up, which suits a park,
/// not a metre of trunk turned in the hand.
struct ScanAlignmentSceneView: UIViewRepresentable {
    let surface: ScanSurface
    let overlay: ScanAlignmentOverlay
    let camera: ScanAlignmentCamera
    var onPick: (TreeSection.ID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        view.scene = scene
        view.backgroundColor = CanopyColor.surface100.uiColor
        #if targetEnvironment(simulator)
            // The simulator draws with the Mac's GPU, small and shared on an Intel Mac: draw less there, as the 3D
            // map does.
            view.antialiasingMode = .none
            view.preferredFramesPerSecond = 30
        #else
            view.antialiasingMode = .multisampling4X
        #endif
        view.autoenablesDefaultLighting = true
        scene.rootNode.addChildNode(Self.scanNode(surface))
        let overlayNode = SCNNode()
        scene.rootNode.addChildNode(overlayNode)
        context.coordinator.overlayNode = overlayNode

        let pov = SCNNode()
        pov.camera = SCNCamera()
        pov.camera?.zNear = 0.02
        pov.camera?.zFar = 400
        pov.camera?.fieldOfView = 50
        scene.rootNode.addChildNode(pov)
        view.pointOfView = pov
        // The camera is the app's own orbit (`ScanOrbit`), not SceneKit's camera controller: that one rolls the view
        // about its line of sight for a twist and fights a camera moved from outside it, which turned the ground over.
        view.allowsCameraControl = false
        camera.view = view
        camera.homeTarget = overlay.target
        camera.place(.home(overlay.target))
        let coordinator = context.coordinator
        coordinator.camera = camera
        let orbit = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.orbited(_:)))
        orbit.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.twoFingers(_:)))
        let twist = UIRotationGestureRecognizer(target: coordinator, action: #selector(Coordinator.twoFingers(_:)))
        let slide = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.twoFingers(_:)))
        slide.minimumNumberOfTouches = 2
        coordinator.pinch = pinch
        coordinator.twist = twist
        coordinator.slide = slide
        for recogniser in [orbit, pinch, twist, slide] as [UIGestureRecognizer] {
            recogniser.delegate = coordinator
            view.addGestureRecognizer(recogniser)
        }

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.update(overlay, in: view)
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "align-scene"
        view.accessibilityLabel = "Scan and rings in 3D"
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.update(overlay, in: view)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPick: (TreeSection.ID) -> Void
        var overlayNode: SCNNode?
        private var drawn: ScanAlignmentOverlay?

        init(onPick: @escaping (TreeSection.ID) -> Void) {
            self.onPick = onPick
        }

        func update(_ overlay: ScanAlignmentOverlay, in view: SCNView) {
            guard overlay != drawn, let node = overlayNode else { return }
            drawn = overlay
            for child in node.childNodes {
                child.removeFromParentNode()
            }
            for child in ScanAlignmentSceneView.overlayNodes(overlay) {
                node.addChildNode(child)
            }
        }

        weak var camera: ScanAlignmentCamera?
        weak var pinch: UIPinchGestureRecognizer?
        weak var twist: UIRotationGestureRecognizer?
        weak var slide: UIPanGestureRecognizer?

        @objc func orbited(_ recogniser: UIPanGestureRecognizer) {
            camera?.orbitGesture(recogniser)
        }

        @objc func twoFingers(_ recogniser: UIGestureRecognizer) {
            guard let pinch, let twist, let slide else { return }
            camera?.twoFingers(pinch: pinch, twist: twist, slide: slide)
        }

        /// Pinch, twist and two-finger slide go together, as on a map.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        /// Picks the ring whose outline, on screen, passes nearest the tap, within a finger's width.
        @objc func tapped(_ recogniser: UITapGestureRecognizer) {
            guard let view = recogniser.view as? SCNView, let overlay = drawn else { return }
            let tap = recogniser.location(in: view)
            var best: (id: TreeSection.ID, distance: CGFloat)?
            for section in overlay.profile.sections {
                let centre = WireframeTree.centre(of: section, lean: overlay.lean, at: overlay.trunkBase)
                for i in 0..<24 {
                    let angle = Float(i) / 24 * 2 * .pi
                    let point = centre + SIMD3(cos(angle), 0, sin(angle)) * Float(section.radius)
                    let projected = view.projectPoint(SCNVector3(point))
                    guard projected.z > 0, projected.z < 1 else { continue }
                    let distance = hypot(CGFloat(projected.x) - tap.x, CGFloat(projected.y) - tap.y)
                    if distance < (best?.distance ?? 44) { best = (section.id, distance) }
                }
            }
            if let best { onPick(best.id) }
        }
    }

    // MARK: Geometry

    static let dbhColor = SIMD4<Float>(1, 1, 1, 1)
    static let vectorColor = SIMD4<Float>(0.78, 0.55, 0.98, 1)

    static func ringColor(_ source: TreeSection.Source) -> SIMD4<Float> {
        switch source {
        case .eye: CaptureSession.trunkColor
        case .scan: CaptureSession.scanRingColor
        case .camera: CaptureSession.cameraRingColor
        case .confirmed: CaptureSession.confirmedRingColor
        }
    }

    static func overlayNodes(_ overlay: ScanAlignmentOverlay) -> [SCNNode] {
        let width = WireframeTree.lineWidth
        let figure = WireframeTree.figure(
            overlay.profile, lean: overlay.lean, at: overlay.trunkBase, highlight: overlay.selected, marking: true)
        var nodes = [
            lines(figure.trunk, color: CaptureSession.trunkColor, width: width),
            lines(figure.crown, color: CaptureSession.crownColor, width: width),
        ]
        for source in TreeSection.Source.allCases {
            nodes.append(lines(figure.marked[source] ?? [], color: ringColor(source), width: width * 1.5))
        }
        nodes.append(lines(figure.highlighted, color: CaptureSession.highlightColor, width: width * 2.5))
        if let dbh = overlay.dbh {
            nodes.append(
                lines(
                    Wireframe.ring(centre: overlay.target, radius: Float(dbh / 2), count: 64), color: dbhColor,
                    width: width))
        }
        if let form = overlay.vectorForm, let base = overlay.vectorBase {
            var segments = WireframeTree.figure(form, at: base).all
            // A cross on the ground at its base, to set on the trunk.
            segments += [
                Wireframe.Segment(from: base - SIMD3(0.3, 0, 0), to: base + SIMD3(0.3, 0, 0)),
                Wireframe.Segment(from: base - SIMD3(0, 0, 0.3), to: base + SIMD3(0, 0, 0.3)),
            ]
            nodes.append(lines(segments, color: vectorColor, width: width))
        }
        if let cloud = overlay.cloud, !cloud.points.isEmpty {
            nodes.append(pointsNode(cloud.points, crown: overlay.crown, groundHeight: overlay.groundHeight))
        }
        return nodes
    }

    static let pointColor = SIMD4<Float>(0.62, 0.66, 0.72, 0.8)
    static let insideColor = SIMD4<Float>(0.45, 0.85, 0.40, 1)

    /// The aerial points as dots a few pixels across, those inside the crown being set in green.
    static func pointsNode(_ points: [SIMD3<Float>], crown: CrownShape?, groundHeight: Double) -> SCNNode {
        let colours = points.map { point in
            crown.map { $0.distance(to: point, groundHeight: groundHeight) <= 0.25 } == true
                ? insideColor : pointColor
        }
        let geometry = SCNGeometry(
            sources: [
                source(points, semantic: .vertex),
                SCNGeometrySource(
                    data: colours.withUnsafeBytes { Data($0) }, semantic: .color, vectorCount: colours.count,
                    usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size,
                    dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride),
            ],
            elements: [
                {
                    let element = SCNGeometryElement(
                        indices: Array(0..<UInt32(points.count)), primitiveType: .point)
                    element.pointSize = 4
                    element.minimumPointScreenSpaceRadius = 1.5
                    element.maximumPointScreenSpaceRadius = 4
                    return element
                }()
            ])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.accessibilityLabel = "Aerial points"
        return node
    }

    /// Lines as thin tubes: drawn where they are, and faintly through the scan, so a ring inside the trunk still
    /// shows.
    static func lines(_ segments: [Wireframe.Segment], color: SIMD4<Float>, width: Float) -> SCNNode {
        let node = SCNNode()
        let mesh = WireframeTree.mesh(segments, width: width)
        guard !mesh.isEmpty else { return node }
        let colour = UIColor(
            red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: CGFloat(color.w))
        let solid = SCNNode(geometry: geometry(mesh, material: material(colour)))
        let ghostMaterial = material(colour.withAlphaComponent(0.3))
        ghostMaterial.readsFromDepthBuffer = false
        let ghost = SCNNode(geometry: geometry(mesh, material: ghostMaterial))
        ghost.renderingOrder = 10
        node.addChildNode(solid)
        node.addChildNode(ghost)
        return node
    }

    static func material(_ colour: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = colour
        material.lightingModel = .constant
        material.isDoubleSided = true
        return material
    }

    static func geometry(_ mesh: Mesh, material: SCNMaterial) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0) })
        let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [material]
        return geometry
    }

    /// The scan as shaded triangles with their edges drawn over them.
    static func scanNode(_ scan: ScanSurface) -> SCNNode {
        let node = SCNNode()
        guard !scan.isEmpty else { return node }
        let vertices = source(scan.positions, semantic: .vertex)
        let fill = SCNGeometry(
            sources: [vertices, source(scan.normals, semantic: .normal)],
            elements: [SCNGeometryElement(indices: scan.triangles, primitiveType: .triangles)])
        let surface = SCNMaterial()
        surface.diffuse.contents = UIColor(red: 0.74, green: 0.77, blue: 0.70, alpha: 1)
        surface.lightingModel = .lambert
        surface.isDoubleSided = true
        fill.materials = [surface]
        node.addChildNode(SCNNode(geometry: fill))

        let wire = SCNGeometry(
            sources: [vertices], elements: [SCNGeometryElement(indices: scan.edges, primitiveType: .line)])
        let edge = SCNMaterial()
        edge.diffuse.contents = UIColor(white: 0.25, alpha: 0.45)
        edge.lightingModel = .constant
        wire.materials = [edge]
        let wireNode = SCNNode(geometry: wire)
        wireNode.renderingOrder = 1
        node.addChildNode(wireNode)
        return node
    }

    /// A geometry source straight from the vectors' bytes, with no copy into `SCNVector3`s first.
    static func source(_ vectors: [SIMD3<Float>], semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        SCNGeometrySource(
            data: vectors.withUnsafeBytes { Data($0) }, semantic: semantic, vectorCount: vectors.count,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
    }
}
