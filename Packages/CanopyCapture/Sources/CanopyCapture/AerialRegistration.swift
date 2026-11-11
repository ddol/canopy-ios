import Foundation
import simd

/// Lines the aerial lidar points up with a trunk scan: the census position the points are placed by is GPS, metres
/// out, while the aerial returns off the trunk (and off a fork's stems, plainly) sit on the scan's bark. The shift on
/// the ground that puts the most of them on the scanned trunk is the registration; heights are left alone, a trunk
/// being much the same all the way up.
///
/// In a scan's frame (`ScanAlignment`): x east, y up, z south.
public struct AerialRegistration: Equatable, Sendable {
    /// What to add to the aerial points, x and z, in metres.
    public var shift: SIMD2<Double>
    /// How many of the aerial points beside the trunk sit on the scan once moved, and how many there were.
    public var matched: Int
    public var candidates: Int
    /// How many sat on it before moving.
    public var matchedBefore: Int

    /// How far the points are looked for round the trunk, and how far they may move, in metres.
    public static let searchRadius = 6.0
    /// The least matched points that make a registration.
    public static let minimumMatched = 6

    /// The shift that puts the most aerial points beside the trunk on the scanned mesh: tried every 20 cm up to
    /// `searchRadius` either way, then every 4 cm round the best. A point is on the mesh when it is within a cell of
    /// a mesh vertex. Points from half a metre above the ground to the top of the scan count, the ground and the
    /// crown above being nothing the scan shows. Nil when too few points match anywhere, or no shift matches clearly
    /// more than none.
    public static func register(
        _ points: [SIMD3<Float>], to mesh: Mesh, groundHeight: Double, radius: Double = searchRadius
    ) -> AerialRegistration? {
        guard let bounds = mesh.bounds else { return nil }
        let low = Float(groundHeight + 0.5)
        let high = bounds.max.y + 0.3
        // The scan's walls from above, without its ground.
        let walls = mesh.positions.filter { $0.y >= low && $0.y <= high }.map { SIMD2(Double($0.x), Double($0.z)) }
        guard walls.count >= 20 else { return nil }
        let reach = radius + Double(max(bounds.max.x - bounds.min.x, bounds.max.z - bounds.min.z))
        let candidates = points.filter { p in
            p.y >= low && p.y <= high && simd_length(SIMD2(Double(p.x), Double(p.z))) <= reach
        }.map { SIMD2(Double($0.x), Double($0.z)) }
        guard candidates.count >= minimumMatched else { return nil }

        func occupancy(_ cell: Double) -> Set<SIMD2<Int32>> {
            var set = Set<SIMD2<Int32>>()
            for w in walls {
                let k = SIMD2(Int32((w.x / cell).rounded(.down)), Int32((w.y / cell).rounded(.down)))
                for dx in Int32(-1)...1 {
                    for dy in Int32(-1)...1 { set.insert(k &+ SIMD2(dx, dy)) }
                }
            }
            return set
        }
        func score(_ shift: SIMD2<Double>, _ cells: Set<SIMD2<Int32>>, _ cell: Double) -> Int {
            candidates.reduce(0) { count, p in
                let q = (p + shift) / cell
                return count + (cells.contains(SIMD2(Int32(q.x.rounded(.down)), Int32(q.y.rounded(.down)))) ? 1 : 0)
            }
        }
        func search(around centre: SIMD2<Double>, reach: Double, step: Double, cell: Double) -> (SIMD2<Double>, Int) {
            let cells = occupancy(cell)
            let n = Int((reach / step).rounded())
            var best = (shift: centre, score: -1, distance: Double.infinity)
            for i in -n...n {
                for j in -n...n {
                    let shift = centre + SIMD2(Double(i), Double(j)) * step
                    let s = score(shift, cells, cell)
                    let d = simd_length(shift)
                    // The smallest shift among equals: no move without a reason.
                    if s > best.score || (s == best.score && d < best.distance) { best = (shift, s, d) }
                }
            }
            return (best.shift, best.score)
        }
        let coarse = search(around: .zero, reach: radius, step: 0.2, cell: 0.2)
        let fine = search(around: coarse.0, reach: 0.24, step: 0.04, cell: 0.05)
        let before = score(.zero, occupancy(0.05), 0.05)
        guard fine.1 >= minimumMatched, fine.1 >= before + max(3, before / 5) || simd_length(fine.0) < 0.05
        else { return nil }
        return AerialRegistration(
            shift: fine.0, matched: fine.1, candidates: candidates.count, matchedBefore: before)
    }
}
