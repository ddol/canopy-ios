import CanopyModel
import CanopyReference
import Foundation

/// How well a load found the synthetic site's trees: each tree found is matched to the nearest unmatched true trunk
/// close enough to be the same tree.
public struct DetectionScore: Codable, Equatable, Sendable, CustomStringConvertible {
    /// True trees the load answers for.
    public var truth: Int
    public var found: Int
    public var matched: Int
    /// Mean distance from a matched top to its trunk (m).
    public var meanOffset: Double
    /// Mean of found height − true height for matched trees (m).
    public var heightBias: Double

    public var recall: Double { truth == 0 ? 1 : Double(matched) / Double(truth) }
    public var precision: Double { found == 0 ? 1 : Double(matched) / Double(found) }

    public var description: String {
        String(
            format: "%d of %d trees found (recall %.3f), %d found (precision %.3f), offset %.2f m, height bias %+.2f m",
            matched, truth, recall, found, precision, meanOffset, heightBias)
    }

    /// Scores candidates against the trees of `site` that `covers` answers for (`SiteResult.covers`) and that stand
    /// at least `edge` metres inside the data, where a crown is whole.
    public init(
        candidates: [TreeCandidate], site: SyntheticSite, edge: Double = 8,
        covers: (GeoPoint) -> Bool = { _ in true }
    ) {
        let found = candidates.map { site.site($0.location) }
        let heights = candidates.map(\.height)
        let truth = site.trees.filter { tree in
            abs(tree.x) < site.half - edge && abs(tree.y) < site.half - edge
                && covers(site.geo(SIMD2(tree.x, tree.y)))
        }
        self.truth = truth.count
        self.found = found.count
        // Closest pairs first, so a tree found between two trunks goes to the nearer one.
        var pairs: [(distance: Double, found: Int, truth: Int)] = []
        let bucket = 10.0
        var grid: [SIMD2<Int>: [Int]] = [:]
        for (k, t) in truth.enumerated() {
            grid[SIMD2(Int((t.x / bucket).rounded(.down)), Int((t.y / bucket).rounded(.down))), default: []].append(k)
        }
        for (f, p) in found.enumerated() {
            let cell = SIMD2(Int((p.x / bucket).rounded(.down)), Int((p.y / bucket).rounded(.down)))
            for dj in -1...1 {
                for di in -1...1 {
                    for k in grid[cell &+ SIMD2(di, dj)] ?? [] {
                        let t = truth[k]
                        let d = ((p.x - t.x) * (p.x - t.x) + (p.y - t.y) * (p.y - t.y)).squareRoot()
                        if d <= 1 + 0.5 * t.crownRadius { pairs.append((d, f, k)) }
                    }
                }
            }
        }
        pairs.sort { $0.distance < $1.distance }
        var usedFound = Set<Int>()
        var usedTruth = Set<Int>()
        var offsets = 0.0
        var bias = 0.0
        for pair in pairs where !usedFound.contains(pair.found) && !usedTruth.contains(pair.truth) {
            usedFound.insert(pair.found)
            usedTruth.insert(pair.truth)
            offsets += pair.distance
            bias += (heights[pair.found] ?? 0) - truth[pair.truth].height
        }
        matched = usedTruth.count
        meanOffset = matched == 0 ? 0 : offsets / Double(matched)
        heightBias = matched == 0 ? 0 : bias / Double(matched)
    }
}
