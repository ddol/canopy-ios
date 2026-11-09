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

    var trunkBase: SIMD3<Float> { SIMD3(0, Float(groundHeight), 0) }
    /// What the camera turns about: the trunk's axis at breast height.
    var target: SIMD3<Float> { trunkBase + SIMD3(0, Float(DBH.standardHeight), 0) }
}

/// The view's camera, for the controls: where the screen's right and "away" point on the ground, so a ring moves the
/// way the arrows say whichever side the player has turned the view to.
@MainActor
final class ScanAlignmentCamera {
    fileprivate weak var view: SCNView?
    fileprivate var home: SCNNode?

    /// The screen's right and the direction into the screen, on the ground (scene x and z), each a unit vector.
    var groundAxes: (right: SIMD2<Float>, away: SIMD2<Float>) {
        guard let pov = view?.pointOfView else { return (SIMD2(1, 0), SIMD2(0, -1)) }
        let right = SIMD2(pov.simdWorldRight.x, pov.simdWorldRight.z)
        let front = SIMD2(pov.simdWorldFront.x, pov.simdWorldFront.z)
        guard simd_length(right) > 1e-3 else { return (SIMD2(1, 0), SIMD2(0, -1)) }
        let away = simd_length(front) > 1e-3 ? simd_normalize(front) : SIMD2(-right.y, right.x)
        return (simd_normalize(right), away)
    }

    /// Back to where the view started.
    func reset() {
        guard let view, let home else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.3
        view.pointOfView = home
        home.simdTransform = ScanAlignmentSceneView.homeTransform(target: SIMD3(view.defaultCameraController.target))
        SCNTransaction.commit()
    }
}

/// The scan's triangles in 3D with the overlay over them. SceneKit's turntable camera orbits the trunk: drag to turn
/// round it and up or down, pinch to zoom, two fingers to slide. Tapping near a ring picks it.
///
/// The 3D map's `CameraRig` is not used: it keeps the ground under a finger and starts 12 m up, which suits a park,
/// not a metre of trunk turned in the hand.
struct ScanAlignmentSceneView: UIViewRepresentable {
    let mesh: Mesh
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
        scene.rootNode.addChildNode(Self.scanNode(mesh))
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
        return nodes
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

    /// The scan as shaded triangles (normals from the faces, since the evidence holds none) with their edges drawn
    /// over them.
    static func scanNode(_ mesh: Mesh) -> SCNNode {
        let node = SCNNode()
        guard !mesh.isEmpty else { return node }
        var normals = [SIMD3<Float>](repeating: .zero, count: mesh.positions.count)
        var edges: [UInt32] = []
        var seen = Set<UInt64>()
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let corners = [mesh.indices[t], mesh.indices[t + 1], mesh.indices[t + 2]]
            let a = mesh.positions[Int(corners[0])]
            let b = mesh.positions[Int(corners[1])]
            let c = mesh.positions[Int(corners[2])]
            let normal = simd_cross(b - a, c - a)
            for corner in corners {
                normals[Int(corner)] += normal
            }
            for (p, q) in [(corners[0], corners[1]), (corners[1], corners[2]), (corners[2], corners[0])] {
                if seen.insert(UInt64(min(p, q)) << 32 | UInt64(max(p, q))).inserted {
                    edges += [p, q]
                }
            }
        }
        let vertices = SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0) })
        let normalSource = SCNGeometrySource(
            normals: normals.map { simd_length($0) > 0 ? SCNVector3(simd_normalize($0)) : SCNVector3(0, 1, 0) })
        let fill = SCNGeometry(
            sources: [vertices, normalSource],
            elements: [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)])
        let surface = SCNMaterial()
        surface.diffuse.contents = UIColor(red: 0.74, green: 0.77, blue: 0.70, alpha: 1)
        surface.lightingModel = .lambert
        surface.isDoubleSided = true
        fill.materials = [surface]
        node.addChildNode(SCNNode(geometry: fill))

        let wire = SCNGeometry(
            sources: [vertices], elements: [SCNGeometryElement(indices: edges, primitiveType: .line)])
        let edge = SCNMaterial()
        edge.diffuse.contents = UIColor(white: 0.25, alpha: 0.45)
        edge.lightingModel = .constant
        wire.materials = [edge]
        let wireNode = SCNNode(geometry: wire)
        wireNode.renderingOrder = 1
        node.addChildNode(wireNode)
        return node
    }
}
