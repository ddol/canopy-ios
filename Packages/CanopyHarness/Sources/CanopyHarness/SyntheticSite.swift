import CanopyModel
import CanopyReference
import CryptoKit
import Foundation

/// A prepared Gerardus site made up from known trees, so loading and detection can be checked against the truth.
///
/// It looks like a park site at 1 m voxels: undulating ground, a lake with an island, groves of broadleaf and conifer
/// crowns with returns inside them, scattered single trees, and buildings whose roofs are partly left unclassified, as
/// 3DEP's San Francisco tiles leave them. Everything is in a site frame that, like the real one, is slightly scaled,
/// rotated and shifted from local east-north-up (the datum shift), so the client has to fit it from `PoseFromHint`.
/// The same seed always gives the same site.
public struct SyntheticSite: Sendable {
    public struct Tree: Equatable, Sendable {
        /// Trunk, site frame (m).
        public var x: Double
        public var y: Double
        /// Top above the ground (m).
        public var height: Double
        public var crownRadius: Double
        /// Where the crown starts, above the ground (m).
        public var crownBase: Double
        public var conifer: Bool
    }

    public struct Building: Sendable {
        /// Site frame, counter-clockwise, not repeating the first vertex.
        public var outline: [SIMD2<Double>]
        public var height: Double
    }

    /// Points as columns, as the server stores them.
    public struct Points: Sendable {
        public var x: [Float] = []
        public var y: [Float] = []
        public var z: [Float] = []
        public var classification: [UInt8] = []
        public var intensity: [UInt16] = []

        public var count: Int { x.count }

        mutating func append(_ x: Double, _ y: Double, _ z: Double, _ c: UInt8, _ i: UInt16) {
            self.x.append(Float(x))
            self.y.append(Float(y))
            self.z.append(Float(z))
            classification.append(c)
            intensity.append(i)
        }
    }

    /// The map from local east-north metres at the tile centre to the site frame: `site = scale · R(angle) · enu +
    /// shift`. The real server's is NAD83(2011) on a projection; this one is close in size.
    public struct Datum: Sendable {
        public var scale = 1.000_006_8
        public var angle = 0.000_42
        public var shift = SIMD2(1.57, -0.16)

        public func site(east: Double, north: Double) -> SIMD2<Double> {
            SIMD2(
                scale * (cos(angle) * east - sin(angle) * north), scale * (sin(angle) * east + cos(angle) * north))
                + shift
        }

        public func enu(_ site: SIMD2<Double>) -> (east: Double, north: Double) {
            let p = (site - shift) / scale
            return (cos(angle) * p.x + sin(angle) * p.y, -sin(angle) * p.x + cos(angle) * p.y)
        }
    }

    /// The L16 tile the site is for.
    public let token: String
    /// The tile's centre: the site frame's origin.
    public let origin: GeoPoint
    /// The tile and its eight neighbours.
    public let covering: [String]
    public let datum: Datum
    /// Half the side of the square the data covers, centred on the origin (m).
    public let half: Double
    /// The ground model at 1 m, NaN over water.
    public let ground: Heightfield
    public let trees: [Tree]
    public let buildings: [Building]
    /// Every return at 1 m voxels, all classes.
    public let points: Points
    /// Changes whenever the seed or the layout changes, like a real bundle's manifest hash.
    public let bundleID: String

    /// Stow Lake, Golden Gate Park: the tile the live tests use.
    public static let stowLake = "8085876c1"

    /// - Parameters:
    ///   - half: half the side of the data's square; a real site (9 L16 tiles) is about 225 m.
    ///   - groves: how many dense groups of trees.
    public init(token: String = SyntheticSite.stowLake, seed: UInt64 = 1, half: Double = 225, groves: Int = 48) {
        let tile = S2CellID(token: token)!.parent(level: S2CellID.tileLevel)
        self.token = tile.token
        self.origin = tile.center
        self.half = half
        let datum = Datum()
        self.datum = datum
        var random = SplitMix64(seed: seed)

        // Neighbouring tiles: step one tile's width each way from the centre.
        let frame = LocalFrame(origin: origin)
        let corners = tile.vertices.map { frame.enu(of: $0) }
        let width = (corners.map(\.east).max()! - corners.map(\.east).min()!) * 0.9
        let height = (corners.map(\.north).max()! - corners.map(\.north).min()!) * 0.9
        var covering: [String] = []
        for dj in -1...1 {
            for di in -1...1 {
                let p = frame.geoPoint(of: ENU(east: Double(di) * width, north: Double(dj) * height, up: 0)).point
                if !covering.contains(p.tile.token) { covering.append(p.tile.token) }
            }
        }
        self.covering = covering

        // Ground, with a lake round an island near the middle.
        let n = Int(2 * half)
        let lake = (centre: SIMD2(-20.0, 10.0), outer: SIMD2(95.0, 62.0), island: SIMD2(34.0, 26.0))
        func inLake(_ p: SIMD2<Double>) -> Bool {
            let d = p - lake.centre
            let outer = (d / lake.outer) * (d / lake.outer)
            let island = (d / lake.island) * (d / lake.island)
            return outer.sum() <= 1 && island.sum() > 1
        }
        func groundZ(_ x: Double, _ y: Double) -> Double {
            52 + 4 * sin(x / 63) + 2.5 * cos(y / 41) + 0.015 * x
        }
        var z = [Float](repeating: .nan, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                let p = SIMD2(-half + Double(i) + 0.5, -half + Double(j) + 0.5)
                if !inLake(p) { z[j * n + i] = Float(groundZ(p.x, p.y)) }
            }
        }
        self.ground = Heightfield(
            origin: Vector3(x: -half + 0.5, y: -half + 0.5, z: 0), cellSize: 1, nx: n, ny: n, z: z)

        // Buildings: a museum, a conservatory, a boathouse and a few sheds.
        var buildings: [Building] = []
        for (x, y, w, h, height) in [
            (120.0, 140.0, 70.0, 45.0, 14.0), (-150, -130, 50, 22, 9), (55, -40, 14, 10, 6), (-170, 120, 12, 12, 5),
            (160, -170, 20, 16, 7), (-60, 170, 30, 18, 11),
        ] {
            buildings.append(
                Building(
                    outline: [SIMD2(x, y), SIMD2(x + w, y), SIMD2(x + w, y + h), SIMD2(x, y + h)], height: height))
        }
        self.buildings = buildings
        func nearBuilding(_ p: SIMD2<Double>, _ clearance: Double) -> Bool {
            buildings.contains { b in
                let lo = b.outline[0] - clearance
                let hi = b.outline[2] + clearance
                return p.x >= lo.x && p.y >= lo.y && p.x <= hi.x && p.y <= hi.y
            }
        }

        // Trees: groves by dart throwing, crowns overlapping a little, then single trees in the open.
        var trees: [Tree] = []
        func place(_ p: SIMD2<Double>, radius r: Double, spacing: Double) -> Bool {
            guard abs(p.x) < half - 2, abs(p.y) < half - 2, !inLake(p), !nearBuilding(p, r + 2) else { return false }
            for t in trees {
                let d = SIMD2(t.x, t.y) - p
                if (d * d).sum() < pow(spacing * (t.crownRadius + r), 2) { return false }
            }
            let conifer = random.unit() < 0.35
            let height = 10 + 3.2 * r + random.unit() * 6
            trees.append(
                Tree(
                    x: p.x, y: p.y, height: height, crownRadius: r,
                    crownBase: height * (conifer ? 0.25 : 0.45) + random.unit() * 2, conifer: conifer))
            return true
        }
        for _ in 0..<groves {
            let centre = SIMD2(random.unit(in: -half...half), random.unit(in: -half...half))
            let radius = random.unit(in: 30...70)
            for _ in 0..<Int(radius * radius / 4) {
                let angle = random.unit() * 2 * .pi
                let distance = radius * random.unit().squareRoot()
                let p = centre + SIMD2(cos(angle), sin(angle)) * distance
                _ = place(p, radius: random.unit(in: 2.5...6.5), spacing: 0.8)
            }
        }
        for _ in 0..<600 {
            let p = SIMD2(random.unit(in: -half...half), random.unit(in: -half...half))
            _ = place(p, radius: random.unit(in: 2.5...5.5), spacing: 1.3)
        }
        self.trees = trees

        // Returns, one per occupied 1 m voxel: crown tops, returns through the crown, understorey, ground or water.
        let bucket = 16.0
        let buckets = Int((2 * half / bucket).rounded(.up))
        var grid = [[Int]](repeating: [], count: buckets * buckets)
        for (k, t) in trees.enumerated() {
            let i = min(buckets - 1, max(0, Int((t.x + half) / bucket)))
            let j = min(buckets - 1, max(0, Int((t.y + half) / bucket)))
            grid[j * buckets + i].append(k)
        }
        var points = Points()
        points.x.reserveCapacity(900_000)
        points.y.reserveCapacity(900_000)
        points.z.reserveCapacity(900_000)
        points.classification.reserveCapacity(900_000)
        points.intensity.reserveCapacity(900_000)
        for j in 0..<n {
            for i in 0..<n {
                let p = SIMD2(-half + Double(i) + 0.5, -half + Double(j) + 0.5)
                let jitter = { SIMD2(random.unit(in: -0.45...0.45), random.unit(in: -0.45...0.45)) }
                if inLake(p) {
                    let q = p + jitter()
                    points.append(q.x, q.y, 44.6 + random.unit(in: -0.03...0.03), 9, UInt16(random.unit(in: 20...200)))
                    continue
                }
                let g = groundZ(p.x, p.y)
                if let b = buildings.first(where: { b in
                    p.x >= b.outline[0].x && p.y >= b.outline[0].y && p.x <= b.outline[2].x && p.y <= b.outline[2].y
                }) {
                    let q = p + jitter()
                    // San Francisco's tiles leave many roofs unclassified: the footprints have to mask them.
                    points.append(q.x, q.y, g + b.height, random.unit() < 0.5 ? 1 : 6, UInt16(random.unit(in: 900...2600)))
                    continue
                }
                var top = 0.0
                var base = 0.0
                let bi = Int((p.x + half) / bucket)
                let bj = Int((p.y + half) / bucket)
                for dj in -1...1 {
                    for di in -1...1 {
                        let ii = bi + di
                        let jj = bj + dj
                        guard ii >= 0, jj >= 0, ii < buckets, jj < buckets else { continue }
                        for k in grid[jj * buckets + ii] {
                            let t = trees[k]
                            let d = ((p.x - t.x) * (p.x - t.x) + (p.y - t.y) * (p.y - t.y)).squareRoot()
                            guard d < t.crownRadius else { continue }
                            let f = d / t.crownRadius
                            let surface =
                                t.conifer
                                ? t.height - (t.height - t.crownBase) * f
                                : t.crownBase + (t.height - t.crownBase) * (1 - f * f).squareRoot()
                            if surface > top {
                                top = surface
                                base = t.crownBase
                            }
                        }
                    }
                }
                if top > 0 {
                    var q = p + jitter()
                    points.append(q.x, q.y, g + top + random.unit(in: -0.2...0.2), 1, UInt16(random.unit(in: 400...2200)))
                    var level = top - 1
                    while level > base {
                        if random.unit() < 0.6 {
                            q = p + jitter()
                            points.append(q.x, q.y, g + level, 1, UInt16(random.unit(in: 300...1800)))
                        }
                        level -= 1
                    }
                }
                if random.unit() < 0.15 {
                    let q = p + jitter()
                    points.append(q.x, q.y, g + random.unit(in: 0.6...2.4), 1, UInt16(random.unit(in: 300...1800)))
                }
                if top == 0 || random.unit() < 0.6 {
                    let q = p + jitter()
                    points.append(q.x, q.y, g + random.unit(in: -0.05...0.05), 2, UInt16(random.unit(in: 800...3000)))
                }
                if random.unit() < 0.0005 {
                    points.append(p.x, p.y, g - 8, 7, 0)  // low noise, which the server never sends
                }
            }
        }
        self.points = points

        let identity = "canopy-harness:\(self.token):\(seed):\(half):\(groves):\(trees.count):\(points.count)"
        self.bundleID = "sha256:" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The WGS 84 point at a site-frame position.
    public func geo(_ site: SIMD2<Double>) -> GeoPoint {
        let (east, north) = datum.enu(site)
        return LocalFrame(origin: origin).geoPoint(of: ENU(east: east, north: north, up: 0)).point
    }

    /// The site-frame position of a WGS 84 point.
    public func site(_ point: GeoPoint) -> SIMD2<Double> {
        let enu = LocalFrame(origin: origin).enu(of: point)
        return datum.site(east: enu.east, north: enu.north)
    }

    /// The ground height at a site-frame position, nil over water or off the data.
    public func groundHeight(_ p: SIMD2<Double>) -> Double? {
        ground.height(x: p.x, y: p.y)
    }
}

/// A small, fast, seedable generator: the same seed always makes the same site.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }

    mutating func unit(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }
}
