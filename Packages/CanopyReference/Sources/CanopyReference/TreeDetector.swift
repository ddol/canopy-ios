import Foundation

/// Finds trees in aerial LiDAR: a canopy height model (CHM) from the points above the ground model, local maxima
/// with a window that grows with tree height, and crowns grown from those maxima by hill-climbing.
///
/// 3DEP's San Francisco tiles classify ground (2) and water (9) but leave vegetation unclassified (1), together with
/// anything else above ground; building footprints are masked out, so in the park almost everything left is tree.
public struct TreeDetector: Sendable {
    /// A tree found in the CHM, in the site frame.
    public struct Tree: Equatable, Sendable {
        /// Tree top, site frame (m).
        public var x: Double
        public var y: Double
        /// Ground under the top (NAVD88 m).
        public var ground: Double
        /// Top above ground (m).
        public var height: Double
        /// Radius of a circle with the crown's area (m).
        public var crownRadius: Double
        /// Points that hit the crown.
        public var pointCount: Int
        /// 0…1: how sure the detector is that this is one tree.
        public var confidence: Double
    }

    /// CHM cell size (m).
    public var cellSize = 0.5
    /// Lowest top that counts as a tree (m above ground).
    public var minimumHeight = 5.0
    /// Cells lower than this belong to no crown (m above ground).
    public var crownFloor = 2.0
    /// Window radius (m) for a top of height h: `windowBase + windowSlope · h`, clamped to `windowRange`.
    public var windowBase = 1.0
    public var windowSlope = 0.08
    public var windowRange: ClosedRange<Double> = 1.5...4.5
    /// LAS classes that can be vegetation.
    public var vegetationClasses: Set<UInt32> = [1, 3, 4, 5]
    /// Trees whose top is closer than this to the edge of the data are dropped: their crowns may be cut off.
    public var edgeMargin = 8.0

    public init() {}

    /// Heights of the highest canopy return above the ground on a grid in the site frame: the raw canopy height model,
    /// before pits are filled and it is smoothed. For drawing; `detect` builds its own.
    public struct CanopyHeightModel: Sendable {
        /// Site-frame x and y of the grid's south-west corner.
        public var origin: SIMD2<Double>
        public var cellSize: Double
        public var nx: Int
        public var ny: Int
        /// Row by row from the south-west, in metres; 0 where there is no canopy.
        public var heights: [Float]

        public init(origin: SIMD2<Double>, cellSize: Double, nx: Int, ny: Int, heights: [Float]) {
            self.origin = origin
            self.cellSize = cellSize
            self.nx = nx
            self.ny = ny
            self.heights = heights
        }
    }

    /// The raw canopy height model over the ground model's extent, or nil when that is too small or too large.
    public func canopyHeightModel(points: [PointBlock], ground: Heightfield) -> CanopyHeightModel? {
        let grid = Grid(extent: Self.extent(of: ground), cellSize: cellSize)
        guard grid.isUsable else { return nil }
        let (chm, _) = rawCanopy(points: points, ground: ground, grid: grid)
        return grid.model(chm)
    }

    /// `detect` and `canopyHeightModel` over the ground model's extent, building the canopy height model once.
    public func detectWithCanopy(
        points: [PointBlock], ground: Heightfield, buildings: [[SIMD2<Double>]] = []
    ) -> (trees: [Tree], canopy: CanopyHeightModel?) {
        let grid = Grid(extent: Self.extent(of: ground), cellSize: cellSize)
        guard grid.isUsable else { return ([], nil) }
        let (chm, hits) = rawCanopy(points: points, ground: ground, grid: grid)
        return (trees(chm: chm, hits: hits, grid: grid, ground: ground, buildings: buildings), grid.model(chm))
    }

    /// The cells of a canopy height model over an extent.
    struct Grid {
        var area: (x: ClosedRange<Double>, y: ClosedRange<Double>)
        var cellSize: Double
        var nx: Int
        var ny: Int

        init(extent area: (x: ClosedRange<Double>, y: ClosedRange<Double>), cellSize: Double) {
            self.area = area
            self.cellSize = cellSize
            nx = Int(((area.x.upperBound - area.x.lowerBound) / cellSize).rounded(.up)) + 1
            ny = Int(((area.y.upperBound - area.y.lowerBound) / cellSize).rounded(.up)) + 1
        }

        var isUsable: Bool { nx > 2 && ny > 2 && nx * ny < 50_000_000 }

        func model(_ heights: [Float]) -> CanopyHeightModel {
            CanopyHeightModel(
                origin: SIMD2(area.x.lowerBound, area.y.lowerBound), cellSize: cellSize, nx: nx, ny: ny,
                heights: heights)
        }
    }

    static func extent(of ground: Heightfield) -> (x: ClosedRange<Double>, y: ClosedRange<Double>) {
        (
            x: ground.origin.x...(ground.origin.x + Double(ground.nx - 1) * ground.cellSize),
            y: ground.origin.y...(ground.origin.y + Double(ground.ny - 1) * ground.cellSize)
        )
    }

    /// The highest vegetation return above the ground in each cell, and how many returns each cell has.
    private func rawCanopy(points: [PointBlock], ground: Heightfield, grid: Grid) -> (chm: [Float], hits: [UInt16]) {
        let (area, nx, ny) = (grid.area, grid.nx, grid.ny)
        var chm = [Float](repeating: 0, count: nx * ny)
        var hits = [UInt16](repeating: 0, count: nx * ny)
        var groundCache = [Float](repeating: .nan, count: nx * ny)
        // Classes as bits: a set lookup per point is most of the time spent here.
        let mask = vegetationClasses.reduce(UInt64(0)) { $1 < 64 ? $0 | 1 << UInt64($1) : $0 }
        let wide = vegetationClasses.contains { $0 >= 64 }
        for block in points {
            let hasClass = block.classification.count == block.count
            for k in 0..<block.count {
                if hasClass {
                    let c = block.classification[k]
                    if c < 64 ? mask >> UInt64(c) & 1 == 0 : !(wide && vegetationClasses.contains(c)) { continue }
                }
                let px = Double(block.x[k])
                let py = Double(block.y[k])
                guard area.x.contains(px), area.y.contains(py) else { continue }
                let i = Int((px - area.x.lowerBound) / cellSize)
                let j = Int((py - area.y.lowerBound) / cellSize)
                let index = j * nx + i
                // The ground under the cell's centre, so a cell's height does not depend on which return came first.
                var g = groundCache[index]
                if g.isNaN {
                    guard
                        let h = ground.height(
                            x: area.x.lowerBound + (Double(i) + 0.5) * cellSize,
                            y: area.y.lowerBound + (Double(j) + 0.5) * cellSize)
                    else { continue }
                    g = Float(h)
                    groundCache[index] = g
                }
                let above = block.z[k] - g
                guard above > 0.5, above < 120 else { continue }
                if above > chm[index] { chm[index] = above }
                if hits[index] < .max { hits[index] += 1 }
            }
        }
        return (chm, hits)
    }

    /// - Parameters:
    ///   - points: aerial points in the site frame, with LAS classes.
    ///   - ground: the site's ground model.
    ///   - buildings: closed outlines (site x, y) to mask out.
    ///   - extent: the area to search, site frame (x range, y range); defaults to the ground model's extent.
    public func detect(
        points: [PointBlock], ground: Heightfield, buildings: [[SIMD2<Double>]] = [],
        extent: (x: ClosedRange<Double>, y: ClosedRange<Double>)? = nil
    ) -> [Tree] {
        let grid = Grid(extent: extent ?? Self.extent(of: ground), cellSize: cellSize)
        guard grid.isUsable else { return [] }
        // 1. Raw CHM: highest return above ground per cell, and hits per cell.
        let (chm, hits) = rawCanopy(points: points, ground: ground, grid: grid)
        return trees(chm: chm, hits: hits, grid: grid, ground: ground, buildings: buildings)
    }

    /// Steps 2 to 6 of `detect`, on a raw canopy height model.
    private func trees(
        chm: [Float], hits: [UInt16], grid: Grid, ground: Heightfield, buildings: [[SIMD2<Double>]]
    ) -> [Tree] {
        let (area, nx, ny) = (grid.area, grid.nx, grid.ny)

        // 2. Fill single-cell pits (cells lower than most neighbours) and smooth with a 3 × 3 Gaussian.
        var filled = chm
        for j in 1..<(ny - 1) {
            for i in 1..<(nx - 1) {
                let c = chm[j * nx + i]
                let up = (j + 1) * nx + i
                let down = (j - 1) * nx + i
                let median = Self.median(
                    chm[down - 1], chm[down], chm[down + 1], chm[j * nx + i - 1], chm[j * nx + i + 1], chm[up - 1],
                    chm[up], chm[up + 1])
                if c < median - 1.5 { filled[j * nx + i] = median }
            }
        }
        var smooth = filled
        let kernel: [Float] = [1, 2, 1, 2, 4, 2, 1, 2, 1]
        for j in 1..<(ny - 1) {
            for i in 1..<(nx - 1) {
                var sum: Float = 0
                var k = 0
                for dj in -1...1 {
                    for di in -1...1 {
                        sum += filled[(j + dj) * nx + i + di] * kernel[k]
                        k += 1
                    }
                }
                smooth[j * nx + i] = sum / 16
            }
        }

        // 3. Building mask.
        var masked = [Bool](repeating: false, count: nx * ny)
        for outline in buildings where outline.count >= 3 {
            let xs = outline.map(\.x)
            let ys = outline.map(\.y)
            let i0 = max(0, Int(((xs.min()! - area.x.lowerBound) / cellSize).rounded(.down)) - 1)
            let i1 = min(nx - 1, Int(((xs.max()! - area.x.lowerBound) / cellSize).rounded(.up)) + 1)
            let j0 = max(0, Int(((ys.min()! - area.y.lowerBound) / cellSize).rounded(.down)) - 1)
            let j1 = min(ny - 1, Int(((ys.max()! - area.y.lowerBound) / cellSize).rounded(.up)) + 1)
            guard i0 <= i1, j0 <= j1 else { continue }
            for j in j0...j1 {
                for i in i0...i1 {
                    let p = SIMD2(
                        area.x.lowerBound + (Double(i) + 0.5) * cellSize,
                        area.y.lowerBound + (Double(j) + 0.5) * cellSize)
                    if Self.contains(outline, p) { masked[j * nx + i] = true }
                }
            }
        }

        // 4. Local maxima with a height-dependent window.
        let margin = Int((edgeMargin / cellSize).rounded(.up))
        var tops: [(i: Int, j: Int, h: Float)] = []
        for j in 1..<(ny - 1) {
            for i in 1..<(nx - 1) {
                let index = j * nx + i
                let h = smooth[index]
                guard Double(h) >= minimumHeight, !masked[index] else { continue }
                // Cheap rejection first: most cells have a higher immediate neighbour.
                if smooth[index - 1] > h || smooth[index + 1] > h || smooth[index - nx] > h || smooth[index + nx] > h
                    || smooth[index - nx - 1] > h || smooth[index - nx + 1] > h || smooth[index + nx - 1] > h
                    || smooth[index + nx + 1] > h
                {
                    continue
                }
                let window = min(
                    windowRange.upperBound, max(windowRange.lowerBound, windowBase + windowSlope * Double(h)))
                let r = Int((window / cellSize).rounded())
                var isTop = true
                search: for dj in -r...r {
                    let jj = j + dj
                    guard jj >= 0, jj < ny else { continue }
                    for di in -r...r where di * di + dj * dj <= r * r && (di != 0 || dj != 0) {
                        let ii = i + di
                        guard ii >= 0, ii < nx else { continue }
                        let other = smooth[jj * nx + ii]
                        // Ties go to the first cell in scan order.
                        if other > h || (other == h && (jj < j || (jj == j && ii < i))) {
                            isTop = false
                            break search
                        }
                    }
                }
                if isTop { tops.append((i, j, h)) }
            }
        }

        // 5. Crowns: each canopy cell climbs to its highest neighbour until it stops; the top it reaches (or the
        //    nearest kept top, for a suppressed local maximum) owns it.
        var owner = [Int32](repeating: -1, count: nx * ny)
        for (k, top) in tops.enumerated() { owner[top.j * nx + top.i] = Int32(k) }
        var path: [Int] = []
        func resolve(_ start: Int) -> Int32 {
            path.removeAll(keepingCapacity: true)
            var index = start
            while owner[index] == -1 {
                path.append(index)
                let i = index % nx
                let j = index / nx
                var best = index
                var bestH = smooth[index]
                for dj in -1...1 {
                    for di in -1...1 where di != 0 || dj != 0 {
                        let ii = i + di
                        let jj = j + dj
                        guard ii >= 0, ii < nx, jj >= 0, jj < ny else { continue }
                        let candidate = smooth[jj * nx + ii]
                        if candidate > bestH {
                            best = jj * nx + ii
                            bestH = candidate
                        }
                    }
                }
                if best == index {
                    // A local maximum the window suppressed: give it to the nearest kept top.
                    owner[index] = nearestTop(i: i, j: j)
                    break
                }
                index = best
            }
            let result = owner[index]
            for p in path { owner[p] = result }
            return result
        }
        // Tops bucketed on a coarse grid, so a suppressed maximum finds its nearest kept top quickly.
        let limit = Int((windowRange.upperBound * 1.5 / cellSize).rounded())
        let bucket = max(1, limit)
        let bx = nx / bucket + 1
        var buckets = [[Int32]](repeating: [], count: bx * (ny / bucket + 1))
        for (k, top) in tops.enumerated() { buckets[(top.j / bucket) * bx + top.i / bucket].append(Int32(k)) }
        func nearestTop(i: Int, j: Int) -> Int32 {
            var best: Int32 = -2
            var bestDistance = Int.max
            let ci = i / bucket
            let cj = j / bucket
            for dj in -1...1 {
                for di in -1...1 {
                    let bi = ci + di
                    let bj = cj + dj
                    guard bi >= 0, bj >= 0, bi < bx, bj <= ny / bucket else { continue }
                    for k in buckets[bj * bx + bi] {
                        let top = tops[Int(k)]
                        let d = (top.i - i) * (top.i - i) + (top.j - j) * (top.j - j)
                        if d < bestDistance {
                            bestDistance = d
                            best = k
                        }
                    }
                }
            }
            // Too far to be the same crown.
            return bestDistance <= limit * limit ? best : -2
        }
        var crownCells = [Int](repeating: 0, count: tops.count)
        var crownHits = [Int](repeating: 0, count: tops.count)
        for index in 0..<(nx * ny) where Double(smooth[index]) >= crownFloor && !masked[index] {
            let k = resolve(index)
            guard k >= 0 else { continue }
            crownCells[Int(k)] += 1
            crownHits[Int(k)] += Int(hits[index])
        }

        // 6. Trees.
        var trees: [Tree] = []
        for (k, top) in tops.enumerated() {
            guard top.i >= margin, top.j >= margin, top.i < nx - margin, top.j < ny - margin else { continue }
            let x = area.x.lowerBound + (Double(top.i) + 0.5) * cellSize
            let y = area.y.lowerBound + (Double(top.j) + 0.5) * cellSize
            guard let g = ground.height(x: x, y: y) else { continue }
            // Report the raw (unsmoothed) highest return near the top as the height.
            var raw: Float = top.h
            for dj in -1...1 {
                for di in -1...1 { raw = max(raw, chm[(top.j + dj) * nx + top.i + di]) }
            }
            let crownArea = Double(crownCells[k]) * cellSize * cellSize
            let crownRadius = (crownArea / .pi).squareRoot()
            guard crownRadius >= 1.0 else { continue }
            let height = Double(raw)
            let sizeScore = min(1, crownArea / 40)
            let heightScore = min(1, (height - minimumHeight) / 12)
            let density = Double(crownHits[k]) / max(crownArea, 1)
            let densityScore = min(1, density / 8)
            let confidence = min(0.99, 0.35 + 0.25 * sizeScore + 0.2 * heightScore + 0.2 * densityScore)
            trees.append(
                Tree(
                    x: x, y: y, ground: g, height: height, crownRadius: crownRadius, pointCount: crownHits[k],
                    confidence: (confidence * 100).rounded() / 100))
        }
        return trees
    }

    /// The median of eight values (the mean of the middle two), by a sorting network: no array, no allocation.
    static func median(
        _ a0: Float, _ a1: Float, _ a2: Float, _ a3: Float, _ a4: Float, _ a5: Float, _ a6: Float, _ a7: Float
    ) -> Float {
        var v = (a0, a1, a2, a3, a4, a5, a6, a7)
        @inline(__always) func order(_ a: inout Float, _ b: inout Float) {
            if b < a { swap(&a, &b) }
        }
        // Batcher's odd-even merge sort for eight: 19 comparisons.
        order(&v.0, &v.1)
        order(&v.2, &v.3)
        order(&v.4, &v.5)
        order(&v.6, &v.7)
        order(&v.0, &v.2)
        order(&v.1, &v.3)
        order(&v.4, &v.6)
        order(&v.5, &v.7)
        order(&v.1, &v.2)
        order(&v.5, &v.6)
        order(&v.0, &v.4)
        order(&v.1, &v.5)
        order(&v.2, &v.6)
        order(&v.3, &v.7)
        order(&v.2, &v.4)
        order(&v.3, &v.5)
        order(&v.1, &v.2)
        order(&v.3, &v.4)
        order(&v.5, &v.6)
        return (v.3 + v.4) / 2
    }

    static func contains(_ ring: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i]
            let b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
