import Foundation
import simd

/// Keeps the most detailed version of every part of the scene around a subject while the player walks round it.
///
/// ARKit keeps refining its reconstruction: as you walk around a trunk, the side you scanned first is re-meshed
/// from further away and loses detail, and mesh anchors are merged or dropped. The accumulator splits each anchor's
/// triangles inside a region of interest into small cells (in the anchor's own coordinates) and keeps, for every
/// cell, the version with the most triangles it has seen. A coarser update does not replace a finer one, and cells
/// missing from a later update are kept, so detail that was captured stays captured.
///
/// Geometry is kept in anchor coordinates and placed with each anchor's latest transform, so when ARKit corrects
/// drift by moving an anchor, the kept detail moves with it.
public struct MeshAccumulator: Sendable {
    public let center: SIMD3<Float>
    /// Horizontal radius of the region of interest, in metres.
    public let radius: Float
    /// How far below and above `center` the region reaches, in metres.
    public let below: Float
    public let above: Float
    /// Cell edge, in metres.
    public var cellSize: Float = 0.1
    /// A new version of a cell replaces the kept one only if it has at least this share of its triangles.
    public var keepRatio: Float = 0.8

    private struct CellKey: Hashable, Sendable {
        var anchor: UUID
        var cell: SIMD3<Int32>
    }

    private struct Cell: Sendable {
        /// Three anchor-space corners per triangle.
        var corners: [SIMD3<Float>]
        var triangleCount: Int { corners.count / 3 }
    }

    private var cells: [CellKey: Cell] = [:]
    private var transforms: [UUID: simd_float4x4] = [:]
    private var floorPoints: [UUID: [SIMD3<Float>]] = [:]
    /// How many anchor updates have been added.
    public private(set) var updateCount = 0

    public init(center: SIMD3<Float>, radius: Float, below: Float, above: Float) {
        self.center = center
        self.radius = radius
        self.below = below
        self.above = above
    }

    /// Adds one version of an anchor's geometry.
    ///
    /// - Parameters:
    ///   - mesh: the anchor's geometry in anchor coordinates.
    ///   - transform: the anchor's current anchor-to-world transform.
    ///   - floor: anchor-space points on faces ARKit classified as floor, if any.
    public mutating func add(_ mesh: Mesh, anchor: UUID, transform: simd_float4x4, floor: [SIMD3<Float>] = []) {
        updateCount += 1
        transforms[anchor] = transform
        floorPoints[anchor] = floor.filter { contains(world(transform, $0)) }

        var grouped: [SIMD3<Int32>: [SIMD3<Float>]] = [:]
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let a = mesh.positions[Int(mesh.indices[t])]
            let b = mesh.positions[Int(mesh.indices[t + 1])]
            let c = mesh.positions[Int(mesh.indices[t + 2])]
            guard contains(world(transform, a)), contains(world(transform, b)), contains(world(transform, c)) else {
                continue
            }
            grouped[cellIndex((a + b + c) / 3), default: []] += [a, b, c]
        }
        for (cell, corners) in grouped {
            let key = CellKey(anchor: anchor, cell: cell)
            if let kept = cells[key], Float(corners.count / 3) < keepRatio * Float(kept.triangleCount) {
                continue  // a coarser re-mesh of something already captured in more detail
            }
            cells[key] = Cell(corners: corners)
        }
    }

    public var isEmpty: Bool { cells.isEmpty }

    /// Triangles kept across all anchors (before overlaps between anchors are resolved).
    public var triangleCount: Int { cells.values.reduce(0) { $0 + $1.triangleCount } }

    /// The kept geometry as one mesh in world coordinates, with shared corners welded. Where anchors overlap, each
    /// cell of space comes from the anchor with the most triangles there, so surfaces are not doubled.
    public func mesh() -> Mesh {
        // Group each anchor's cells by the world cell their centre falls in, then take, for every world cell, all
        // the cells of the anchor with the most triangles there (ties go to the lower anchor id, so the result
        // does not depend on the order things arrived in).
        var groups: [SIMD3<Int32>: [UUID: (count: Int, keys: [CellKey])]] = [:]
        for (key, cell) in cells {
            guard let transform = transforms[key.anchor] else { continue }
            let centre = (SIMD3<Float>(key.cell) + 0.5) * cellSize
            let worldCell = cellIndex(world(transform, centre))
            groups[worldCell, default: [:]][key.anchor, default: (0, [])].count += cell.triangleCount
            groups[worldCell, default: [:]][key.anchor, default: (0, [])].keys.append(key)
        }
        var chosen: [CellKey] = []
        for byAnchor in groups.values {
            let best = byAnchor.max { a, b in
                a.value.count < b.value.count
                    || (a.value.count == b.value.count && a.key.uuidString > b.key.uuidString)
            }
            chosen += best?.value.keys ?? []
        }

        var mesh = Mesh.empty
        var welded: [SIMD3<Int32>: UInt32] = [:]
        let weld: Float = 2000  // 0.5 mm
        for key in chosen.sorted(by: Self.order) {
            guard let cell = cells[key], let transform = transforms[key.anchor] else { continue }
            for corner in cell.corners {
                let p = world(transform, corner)
                let q = SIMD3<Int32>((p * weld).rounded(.toNearestOrEven))
                if let index = welded[q] {
                    mesh.indices.append(index)
                } else {
                    let index = UInt32(mesh.positions.count)
                    welded[q] = index
                    mesh.positions.append(p)
                    mesh.indices.append(index)
                }
            }
        }
        return mesh
    }

    /// World heights of the floor-classified points inside the region, from each anchor's latest update.
    public func floorHeights() -> [Float] {
        floorPoints.flatMap { anchor, points in
            transforms[anchor].map { transform in points.map { world(transform, $0).y } } ?? []
        }
    }

    // MARK: Helpers

    private func world(_ transform: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let w = transform * SIMD4(p, 1)
        return SIMD3(w.x, w.y, w.z)
    }

    private func contains(_ p: SIMD3<Float>) -> Bool {
        let d = p - center
        return d.x * d.x + d.z * d.z <= radius * radius && d.y >= -below && d.y <= above
    }

    private func cellIndex(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>((p / cellSize).rounded(.down))
    }

    /// A stable order, so the same cells always give the same mesh (and the same evidence hash).
    private static func order(_ a: CellKey, _ b: CellKey) -> Bool {
        if a.anchor != b.anchor { return a.anchor.uuidString < b.anchor.uuidString }
        if a.cell.x != b.cell.x { return a.cell.x < b.cell.x }
        if a.cell.y != b.cell.y { return a.cell.y < b.cell.y }
        return a.cell.z < b.cell.z
    }
}
