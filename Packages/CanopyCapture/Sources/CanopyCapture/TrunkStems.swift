import CanopyModel
import Foundation
import simd

extension Mesh {
    /// Where the mesh's steep triangles cross the horizontal plane at `y`: the bark's walls, without the ground, the
    /// tops of roots or litter lying flat round the trunk, which a ring fitted through every triangle at the ground
    /// took in. A triangle is steep when its normal is within about 45° of horizontal (`maxUpward` of its length).
    public func wallSlice(atHeight y: Float, maxUpward: Float = 0.7) -> [SIMD2<Double>] {
        var seen = Set<UInt64>()
        var points: [SIMD2<Double>] = []
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let (i, j, k) = (indices[t], indices[t + 1], indices[t + 2])
            let (a, b, c) = (positions[Int(i)], positions[Int(j)], positions[Int(k)])
            // Quick out: the plane misses the triangle.
            guard min(a.y, b.y, c.y) < y, max(a.y, b.y, c.y) > y else { continue }
            let normal = simd_cross(b - a, c - a)
            let length = simd_length(normal)
            guard length > 0, abs(normal.y) <= maxUpward * length else { continue }
            for (m, n) in [(i, j), (j, k), (k, i)] {
                let p = positions[Int(m)]
                let q = positions[Int(n)]
                guard (p.y - y) * (q.y - y) < 0 else { continue }
                guard seen.insert(UInt64(min(m, n)) << 32 | UInt64(max(m, n))).inserted else { continue }
                let hit = p + (q - p) * ((y - p.y) / (q.y - p.y))
                points.append(SIMD2(Double(hit.x), Double(hit.z)))
            }
        }
        return points
    }

    /// `wallSlice` at five planes 2 cm apart round `height` (in the mesh's frame), pooled: what a trunk's rings are
    /// fitted to from a mesh.
    public func trunkSlices(atHeight height: Double) -> [SIMD2<Double>] {
        [-0.04, -0.02, 0, 0.02, 0.04].flatMap { wallSlice(atHeight: Float(height + $0)) }
    }
}

/// The trunks a horizontal slice of a scan crosses: one below a fork, two or more above it, and sometimes a post or a
/// shrub beside the tree. The slice's points are split where they are further apart than a gap, each piece is fitted
/// with a ring, and pieces of one trunk (a scan with holes in it) are put back together.
public enum TrunkStems {
    /// Points further apart than this are on different trunks, in metres.
    public static let gap = 0.08
    /// Fewer points than this are noise, not a trunk.
    public static let minimumPiece = 6

    /// The slice split into pieces whose points are no further than `gap` from the next.
    public static func pieces(_ points: [SIMD2<Double>], gap: Double = gap) -> [[SIMD2<Double>]] {
        guard !points.isEmpty else { return [] }
        func cell(_ p: SIMD2<Double>) -> SIMD2<Int> {
            SIMD2(Int((p.x / gap).rounded(.down)), Int((p.y / gap).rounded(.down)))
        }
        var grid: [SIMD2<Int>: [Int]] = [:]
        for (index, point) in points.enumerated() { grid[cell(point), default: []].append(index) }
        var parent = Array(points.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        let gap2 = gap * gap
        for (index, point) in points.enumerated() {
            let here = cell(point)
            for dx in -1...1 {
                for dy in -1...1 {
                    for other in grid[here &+ SIMD2(dx, dy)] ?? [] where other > index {
                        let d = points[other] - point
                        guard (d * d).sum() <= gap2 else { continue }
                        let (a, b) = (root(index), root(other))
                        if a != b { parent[a] = b }
                    }
                }
            }
        }
        var groups: [Int: [SIMD2<Double>]] = [:]
        for index in points.indices { groups[root(index), default: []].append(points[index]) }
        return groups.values.sorted { $0.count > $1.count }
    }

    /// A ring through each trunk the slice crosses, within `radius` of `centre` when given, largest first. A piece
    /// that cannot be fitted on its own (too short an arc) is joined to the nearest piece when together they fit; two
    /// whose rings overlap (each centre inside the other's ring) are one trunk seen in pieces.
    public static func rings(
        through slice: [SIMD2<Double>], near centre: SIMD2<Double>? = nil, within radius: Double = .infinity
    ) -> [FittedCircle] {
        var pieces = Self.pieces(
            slice.filter { centre == nil || simd_distance($0, centre!) <= radius }
        ).filter { $0.count >= minimumPiece }
        func fit(_ piece: [SIMD2<Double>]) -> FittedCircle? { try? TrunkCapture.ring(through: piece) }
        func middle(_ piece: [SIMD2<Double>]) -> SIMD2<Double> {
            piece.reduce(.zero, +) / Double(piece.count)
        }
        // At most one join per piece, so this ends.
        for _ in 0..<pieces.count {
            let fits = pieces.map(fit)
            var join: (Int, Int)?
            search: for i in pieces.indices {
                for j in pieces.indices where j > i {
                    if let a = fits[i], let b = fits[j], simd_distance(a.center, b.center) < max(a.radius, b.radius) {
                        join = (i, j)
                        break search
                    }
                }
            }
            if join == nil, let lost = pieces.indices.first(where: { fits[$0] == nil }), pieces.count > 1 {
                let nearest = pieces.indices.filter { $0 != lost }.min {
                    simd_distance(middle(pieces[$0]), middle(pieces[lost]))
                        < simd_distance(middle(pieces[$1]), middle(pieces[lost]))
                }!
                if fit(pieces[lost] + pieces[nearest]) != nil {
                    join = (min(lost, nearest), max(lost, nearest))
                } else {
                    pieces.remove(at: lost)
                    continue
                }
            }
            guard let (i, j) = join else { break }
            pieces[i] += pieces[j]
            pieces.remove(at: j)
        }
        return pieces.compactMap(fit).sorted { $0.radius > $1.radius }
    }

    /// The ring through the trunk nearest `centre` in the slice. Throws as a ring through the whole slice would when
    /// no piece of it fits, unless the whole slice does (a scan too sparse to split).
    public static func ring(through slice: [SIMD2<Double>], nearest centre: SIMD2<Double>) throws -> FittedCircle {
        let found = rings(through: slice)
        if let best = found.min(by: { simd_distance($0.center, centre) < simd_distance($1.center, centre) }) {
            return best
        }
        return try TrunkCapture.ring(through: slice)
    }
}
