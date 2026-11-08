import CanopyCapture
import CanopyReference
import SceneKit
import simd

/// Batches geometry for SceneKit by layer, so a site with hundreds of walls needs only a few draw calls. `place`
/// takes a site-frame point (east, north, up) to scene coordinates.
struct VectorMesh {
    let place: @Sendable (SIMD3<Float>) -> SIMD3<Float>
    var vertices: [SCNVector3] = []
    var triangles: [UInt32] = []
    var edges: [UInt32] = []
    /// One colour per vertex when set (the ground, tinted by height); empty for a single-colour mesh.
    var colors: [SIMD4<Float>] = []

    init(place: @escaping @Sendable (SIMD3<Float>) -> SIMD3<Float>) {
        self.place = place
    }

    var isEmpty: Bool { vertices.isEmpty }

    mutating func add(_ line: LineFeature, layer: ReferenceLayer, wallSurfaces: Bool) {
        for face in VectorGeometry.faces(line, layer: layer, wallSurfaces: wallSurfaces) {
            let start = UInt32(vertices.count)
            vertices += face.vertices.map { SCNVector3(place($0)) }
            triangles += face.triangles.map { start + $0 }
            for i in face.vertices.indices {
                edges += [start + UInt32(i), start + UInt32((i + 1) % face.vertices.count)]
            }
        }
        if !line.closed {
            let start = UInt32(vertices.count)
            let points = line.vertices
            vertices += points.map { SCNVector3(place($0)) }
            for i in 1..<max(1, points.count) { edges += [start + UInt32(i - 1), start + UInt32(i)] }
        }
    }

    /// The roof of an extruded footprint or building part, when it has one.
    mutating func addLid(_ line: LineFeature, layer: ReferenceLayer, wallSurfaces: Bool) {
        guard let face = VectorGeometry.lid(line, layer: layer, wallSurfaces: wallSurfaces) else { return }
        let start = UInt32(vertices.count)
        vertices += face.vertices.map { SCNVector3(place($0)) }
        triangles += face.triangles.map { start + $0 }
        for i in face.vertices.indices {
            edges += [start + UInt32(i), start + UInt32((i + 1) % face.vertices.count)]
        }
    }

    /// A tree as the Mac visualiser draws it: the trunk up to the crown's base, and a ring of the crown's radius at
    /// its base and its top.
    mutating func add(_ tree: GerardusTree) {
        let form = tree.form
        let base = tree.base
        let crownBase = base + SIMD3(0, 0, Float(form.crownBase))
        let top = base + SIMD3(0, 0, Float(form.height))
        let start = UInt32(vertices.count)
        vertices += [base, crownBase].map { SCNVector3(place($0)) }
        edges += [start, start + 1]
        let radius = Float(form.crownWidth / 2)
        for centre in [crownBase, top] {
            let ringStart = UInt32(vertices.count)
            let count = 24
            for i in 0..<count {
                let angle = Float(i) / Float(count) * 2 * .pi
                let p = centre + SIMD3(cos(angle) * radius, sin(angle) * radius, 0)
                vertices.append(SCNVector3(place(p)))
            }
            for i in 0..<count {
                edges += [ringStart + UInt32(i), ringStart + UInt32((i + 1) % count)]
            }
        }
    }

    /// Lines already in scene coordinates, such as a census tree's figure.
    mutating func add(sceneSegments segments: [Wireframe.Segment]) {
        for segment in segments {
            let start = UInt32(vertices.count)
            vertices += [SCNVector3(segment.from), SCNVector3(segment.to)]
            edges += [start, start + 1]
        }
    }

    /// A run of points already in scene coordinates.
    mutating func add(scenePolyline points: [SIMD3<Float>], closed: Bool) {
        guard points.count >= 2 else { return }
        let start = UInt32(vertices.count)
        vertices += points.map { SCNVector3($0) }
        for i in 1..<points.count { edges += [start + UInt32(i - 1), start + UInt32(i)] }
        if closed, points.count >= 3 { edges += [start + UInt32(points.count - 1), start] }
    }

    /// The ground grid. With a `tint` the cells are coloured by height between the two colours over `range`,
    /// so a slope reads even without lighting.
    init(
        ground: Heightfield, place: @escaping @Sendable (SIMD3<Float>) -> SIMD3<Float>,
        tint: (low: SIMD4<Float>, high: SIMD4<Float>, range: ClosedRange<Float>)? = nil
    ) {
        self.init(place: place)
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
                    vertices.append(SCNVector3(place(p)))
                    if let tint {
                        let span = max(tint.range.upperBound - tint.range.lowerBound, 0.5)
                        let t = min(max((height - tint.range.lowerBound) / span, 0), 1)
                        colors.append(tint.low + (tint.high - tint.low) * t)
                    }
                }
                triangles += [0, 1, 2, 0, 2, 3].map { start + $0 }
                edges += [0, 1, 1, 2].map { start + $0 }
            }
        }
    }

    /// A node with the fill (when any) and the edges, unlit and double-sided. `fill` nil leaves the triangles out.
    func node(color: UIColor, fill: Bool = true, edgeColor: UIColor? = nil) -> SCNNode {
        let node = SCNNode()
        guard !vertices.isEmpty else { return node }
        let source = SCNGeometrySource(vertices: vertices)
        var colorSource: SCNGeometrySource?
        if colors.count == vertices.count {
            let data = colors.withUnsafeBytes { Data($0) }
            colorSource = SCNGeometrySource(
                data: data, semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
                componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                dataStride: MemoryLayout<SIMD4<Float>>.stride)
        }
        func geometry(_ indices: [UInt32], type: SCNGeometryPrimitiveType, tint: UIColor) -> SCNGeometry {
            let data = indices.withUnsafeBytes { Data($0) }
            let element = SCNGeometryElement(
                data: data, primitiveType: type,
                primitiveCount: indices.count / (type == .triangles ? 3 : 2), bytesPerIndex: 4)
            // Vertex colours multiply the diffuse, so a coloured fill takes white; its edges keep their tint.
            let coloured = type == .triangles && colorSource != nil
            let geometry = SCNGeometry(
                sources: coloured ? [source, colorSource!] : [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = coloured ? UIColor.white : tint
            material.lightingModel = .constant
            material.isDoubleSided = true
            geometry.materials = [material]
            return geometry
        }
        if fill, !triangles.isEmpty {
            node.addChildNode(SCNNode(geometry: geometry(triangles, type: .triangles, tint: color)))
        }
        if !edges.isEmpty {
            let edge = SCNNode(
                geometry: geometry(
                    edges, type: .line, tint: edgeColor ?? (fill ? color.withMultipliedBrightness(0.55) : color)))
            node.addChildNode(edge)
        }
        return node
    }
}
