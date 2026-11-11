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

/// The view's camera, for the controls: where the screen's right and "away" point on the ground, so a ring moves the
/// way the arrows say whichever side the player has turned the view to.
@MainActor
final class ScanAlignmentCamera {
    fileprivate weak var view: SCNView?
    fileprivate var home: SCNNode?
    /// What the view turns about when it opens: the trunk at breast height.
    fileprivate var homeTarget: SIMD3<Float>?

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

    /// Back to where the view started.
    func reset() {
        guard let view, let home else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.3
        view.pointOfView = home
        let target = homeTarget ?? SIMD3(view.defaultCameraController.target)
        view.defaultCameraController.target = SCNVector3(target)
        home.simdTransform = ScanAlignmentSceneView.homeTransform(target: target)
        SCNTransaction.commit()
    }

    /// Turns the view about `target` from `distance` metres away on the south side, a little above it: to take in a
    /// whole crown.
    func frame(_ target: SIMD3<Float>, distance: Float) {
        guard let view, let pov = view.pointOfView else { return }
        let node = SCNNode()
        node.simdPosition = target + SIMD3(0, distance * 0.3, distance)
        node.simdLook(at: target)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.4
        view.defaultCameraController.target = SCNVector3(target)
        pov.simdTransform = node.simdTransform
        SCNTransaction.commit()
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

/// The scan's triangles in 3D with the overlay over them. SceneKit's turntable camera orbits the trunk: drag to turn
/// round it and up or down, pinch to zoom, two fingers to slide. Tapping near a ring picks it.
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
        pov.simdTransform = Self.homeTransform(target: overlay.target)
        scene.rootNode.addChildNode(pov)
        view.pointOfView = pov
        view.allowsCameraControl = true
        view.cameraControlConfiguration.autoSwitchToFreeCamera = false
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.defaultCameraController.target = SCNVector3(overlay.target)
        camera.view = view
        camera.home = pov
        camera.homeTarget = overlay.target

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

    /// 3.2 m from the trunk on its south side, a little above breast height, looking at it.
    static func homeTransform(target: SIMD3<Float>) -> simd_float4x4 {
        let node = SCNNode()
        node.simdPosition = target + SIMD3(0, 0.8, 3.2)
        node.simdLook(at: target)
        return node.simdTransform
    }

    @MainActor
    final class Coordinator: NSObject {
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
