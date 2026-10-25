import CanopyDesign
import CanopyReference
import SceneKit
import SwiftUI

/// Gerardus vector geometry with depth testing and a freely orbitable camera. All coordinates are site ENU;
/// no basemap, guessed roofs, raw scans or GPS-to-height conversion is involved.
public struct VectorMapView: View {
    let reference: VectorReference
    @State private var hidden: Set<VectorGroup> = []
    @State private var reset = UUID()

    public init(reference: VectorReference) { self.reference = reference }

    public var body: some View {
        VectorSceneView(reference: reference, hidden: hidden, reset: reset)
            .accessibilityLabel("3D vector map. Drag to orbit, pinch to zoom, two-finger drag to pan.")
            .accessibilityIdentifier("vector-scene")
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reference.site.label.isEmpty ? reference.site.l16Token : reference.site.label).font(.headline)
                    Text(summary).font(.caption).accessibilityIdentifier("vector-summary")
                    Text("Drag to orbit · Pinch to zoom · Two fingers to pan").font(.caption2)
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
            }
            .overlay(alignment: .bottomTrailing) {
                HStack {
                    Menu("3D layers", systemImage: "square.3.layers.3d") {
                        ForEach(VectorGroup.allCases, id: \.self) { group in
                            Toggle(
                                group.rawValue,
                                isOn: Binding(
                                    get: { !hidden.contains(group) },
                                    set: { if $0 { hidden.remove(group) } else { hidden.insert(group) } }))
                        }
                    }
                    Button("Reset view", systemImage: "arrow.counterclockwise") { reset = UUID() }
                }
                .font(.footnote)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
            }
    }

    private var summary: String {
        let walls = reference.features.filter { $0.layer == .boxes }.count
        let measured = reference.features.filter { $0.line.kind == .wallPlane }.count
        let roofs = reference.features.filter { $0.line.kind == .roofPlane }.count
        let footprints = reference.features.filter { $0.layer == .footprints }.count
        let buildings = walls > 0 ? "\(walls) box walls" : "\(footprints) building outlines"
        return "\(buildings) · \(measured) measured wall planes · "
            + (roofs == 0 ? "No LoD2 roofs" : "\(roofs) roof planes")
    }
}

private enum VectorGroup: String, CaseIterable {
    case buildings = "Buildings"
    case observed = "Measured facades"
    case streets = "Streets and kerbs"
    case ground = "Ground"

    var color: UIColor {
        switch self {
        case .buildings: UIColor(red: 0.75, green: 0.69, blue: 0.55, alpha: 1)
        case .observed: UIColor(red: 0.23, green: 0.56, blue: 0.45, alpha: 1)
        case .streets: UIColor(red: 0.48, green: 0.48, blue: 0.37, alpha: 1)
        case .ground: UIColor(red: 0.90, green: 0.91, blue: 0.85, alpha: 1)
        }
    }
}

private struct VectorSceneView: UIViewRepresentable {
    let reference: VectorReference
    let hidden: Set<VectorGroup>
    let reset: UUID

    final class Coordinator {
        var reset: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.96, green: 0.96, blue: 0.92, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.inertiaEnabled = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.minimumVerticalAngle = 8
        view.defaultCameraController.maximumVerticalAngle = 85
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if context.coordinator.reset != reset {
            context.coordinator.reset = reset
            view.scene = makeScene()
            let camera = view.scene?.rootNode.childNode(withName: "camera", recursively: false)
            view.pointOfView = camera
            view.defaultCameraController.target = SCNVector3Zero
        }
        for group in VectorGroup.allCases {
            view.scene?.rootNode.childNode(withName: group.rawValue, recursively: false)?.isHidden = hidden.contains(
                group)
        }
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        let heights = reference.ground?.z.filter(\.isFinite).sorted() ?? []
        let featureHeights = reference.features.flatMap { $0.line.vertices.map(\.z) }.sorted()
        let elevation = heights.isEmpty ? (featureHeights.first ?? 0) : heights[heights.count / 2]
        var groups: [VectorGroup: VectorMesh] = [:]
        let hasBoxes = reference.features.contains { $0.layer == .boxes || $0.layer == .buildings }
        for feature in reference.features {
            let line = feature.line
            // Box walls already encode the shifted outline and measured heights.
            if hasBoxes, feature.layer == .footprints { continue }
            // Sensor/correction arrows are registration diagnostics rather than building geometry.
            if line.kind == .sensor || line.kind == .correction { continue }
            let group: VectorGroup =
                switch feature.layer {
                case .footprints, .boxes, .buildings: .buildings
                case .observed: .observed
                default: .streets
                }
            var mesh = groups[group] ?? VectorMesh()
            mesh.add(line, layer: feature.layer, elevation: elevation)
            groups[group] = mesh
        }
        if let ground = reference.ground { groups[.ground] = VectorMesh(ground: ground, elevation: elevation) }
        for group in VectorGroup.allCases {
            let node = groups[group]?.node(color: group.color) ?? SCNNode()
            node.name = group.rawValue
            scene.rootNode.addChildNode(node)
        }
        let camera = SCNNode()
        camera.name = "camera"
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 2500
        camera.camera?.fieldOfView = 52
        camera.position = SCNVector3(240, 240, 290)
        camera.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(camera)
        return scene
    }
}

/// Batch geometry by layer, so a site with hundreds of walls needs only a few draw calls.
private struct VectorMesh {
    var vertices: [SCNVector3] = []
    var triangles: [UInt32] = []
    var edges: [UInt32] = []

    init() {}

    mutating func add(_ line: LineFeature, layer: ReferenceLayer, elevation: Float) {
        for face in VectorGeometry.faces(line, layer: layer) {
            let start = UInt32(vertices.count)
            vertices += face.vertices.map { SCNVector3(VectorGeometry.scenePoint($0, elevation: elevation)) }
            triangles += face.triangles.map { start + $0 }
            for i in face.vertices.indices {
                edges += [start + UInt32(i), start + UInt32((i + 1) % face.vertices.count)]
            }
        }
        if !line.closed {
            let start = UInt32(vertices.count)
            let points = line.vertices
            vertices += points.map { SCNVector3(VectorGeometry.scenePoint($0, elevation: elevation)) }
            for i in 1..<max(1, points.count) { edges += [start + UInt32(i - 1), start + UInt32(i)] }
        }
    }

    init(ground: Heightfield, elevation: Float) {
        self.init()
        // A few thousand grid cells, preserving the site's actual slope. Missing returns stay holes.
        let step = max(1, Int(ceil(4 / ground.cellSize)))
        for j in stride(from: 0, to: max(0, ground.ny - step), by: step) {
            for i in stride(from: 0, to: max(0, ground.nx - step), by: step) {
                let cells = [(i, j), (i + step, j), (i + step, j + step), (i, j + step)]
                let z = cells.map { ground.z[$0.1 * ground.nx + $0.0] }
                guard z.allSatisfy(\.isFinite) else { continue }
                let start = UInt32(vertices.count)
                for ((x, y), height) in zip(cells, z) {
                    let p = SIMD3(
                        Float(ground.origin.x + Double(x) * ground.cellSize),
                        Float(ground.origin.y + Double(y) * ground.cellSize), height)
                    vertices.append(SCNVector3(VectorGeometry.scenePoint(p, elevation: elevation)))
                }
                triangles += [0, 1, 2, 0, 2, 3].map { start + $0 }
                edges += [0, 1, 1, 2].map { start + $0 }
            }
        }
    }

    func node(color: UIColor) -> SCNNode {
        let node = SCNNode()
        guard !vertices.isEmpty else { return node }
        let source = SCNGeometrySource(vertices: vertices)
        func geometry(_ indices: [UInt32], type: SCNGeometryPrimitiveType, tint: UIColor) -> SCNGeometry {
            let data = indices.withUnsafeBytes { Data($0) }
            let element = SCNGeometryElement(
                data: data, primitiveType: type,
                primitiveCount: indices.count / (type == .triangles ? 3 : 2), bytesPerIndex: 4)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = tint
            material.lightingModel = .constant
            material.isDoubleSided = true
            geometry.materials = [material]
            return geometry
        }
        if !triangles.isEmpty {
            node.addChildNode(SCNNode(geometry: geometry(triangles, type: .triangles, tint: color)))
        }
        if !edges.isEmpty {
            let edge = SCNNode(geometry: geometry(edges, type: .line, tint: color.withMultipliedBrightness(0.55)))
            node.addChildNode(edge)
        }
        return node
    }
}

extension UIColor {
    fileprivate func withMultipliedBrightness(_ factor: CGFloat) -> UIColor {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * factor, green: g * factor, blue: b * factor, alpha: a)
    }
}
