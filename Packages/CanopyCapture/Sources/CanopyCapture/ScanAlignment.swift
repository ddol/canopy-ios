import CanopyModel
import CanopyReference
import Foundation
import simd

/// A tree's rings set against the mesh of one of its scans, after the AR session: the profile, the ground under the
/// trunk, and where Gerardus's tree for the place stands against the trunk. Kept on the phone by scan, so a tree's
/// fitted rings outlive the session, and corrected later with no camera.
///
/// Everything is in the scan's own frame, the evidence mesh's: metres, y up, x east and z south (the AR session is
/// aligned to gravity and heading), with the origin on the trunk's axis at the height the scan started. The trunk's
/// base is `groundHeight` up from there (usually below), and the profile stands on it, as it did in AR.
public struct ScanAlignment: Codable, Equatable, Sendable {
    /// The evidence mesh's SHA-256, so a scan downloaded from another device can be aligned too.
    public var scan: BlobRef
    public var treeID: UUID
    public var profile: TreeProfile
    /// The ground's height under the trunk in the scan's frame.
    public var groundHeight: Double
    /// Gerardus's tree for the place, when one was loaded and set against the trunk.
    public var vectorTree: VectorTreePlacement?
    /// The trunk's map position as Gerardus's tree, moved onto the trunk, puts it: the census tree's position when
    /// the alignment was saved, corrected by `vectorTree.correction`.
    public var correctedPosition: GeoPoint?
    /// The crown's shape as set against the aerial points, when it was; the profile's crown rings are drawn from it.
    public var crown: CrownShape?
    /// How far the aerial points were moved on the ground to sit on the scanned trunk (x east, z south), when they
    /// were lined up with it with no Gerardus tree to carry the move (`AerialRegistration`).
    public var aerialShift: SIMD2<Double>?
    public var savedAt: Date

    public init(
        scan: BlobRef, treeID: UUID, profile: TreeProfile, groundHeight: Double, vectorTree: VectorTreePlacement? = nil,
        correctedPosition: GeoPoint? = nil, crown: CrownShape? = nil, aerialShift: SIMD2<Double>? = nil,
        savedAt: Date = .now
    ) {
        self.scan = scan
        self.treeID = treeID
        self.profile = profile
        self.groundHeight = groundHeight
        self.vectorTree = vectorTree
        self.correctedPosition = correctedPosition
        self.crown = crown
        self.aerialShift = aerialShift
        self.savedAt = savedAt.roundedToMilliseconds
    }

    /// The trunk's base in the scan's frame.
    public var trunkBase: SIMD3<Float> { SIMD3(0, Float(groundHeight), 0) }
}

/// Where Gerardus's tree (the TREES layer, `GerardusTree`) stands against a scanned trunk, in metres east and north of
/// the trunk's base.
///
/// It is first drawn where the two map positions put it: Gerardus's (3DEP) against the census tree's (GPS and the AR
/// offset, metres out). The player moves its base onto the trunk; the difference is how far the census tree's map
/// position is out, by Gerardus's.
public struct VectorTreePlacement: Codable, Equatable, Sendable {
    /// Gerardus's feature id.
    public var id: String
    /// Where the map positions put its base.
    public var drawn: SIMD2<Double>
    /// Where the player put it; zero is on the trunk.
    public var placed: SIMD2<Double>

    public init(id: String, drawn: SIMD2<Double>, placed: SIMD2<Double>? = nil) {
        self.id = id
        self.drawn = drawn
        self.placed = placed ?? drawn
    }

    /// How far, east and north, the census tree's map position is from where Gerardus's tree, set on the trunk,
    /// puts the trunk.
    public var correction: SIMD2<Double> { drawn - placed }

    /// Whether the player has moved it from where the map positions put it.
    public var isMoved: Bool { simd_length(correction) > 0.005 }

    /// A map position moved by `correction`.
    public func corrected(_ position: GeoPoint) -> GeoPoint {
        LocalFrame(origin: position).geoPoint(of: ENU(east: correction.x, north: correction.y, up: 0)).point
    }

    /// Its base in the scan's frame, on the scan's ground.
    public func base(groundHeight: Double) -> SIMD3<Float> {
        SIMD3(Float(placed.x), Float(groundHeight), Float(-placed.y))
    }
}

/// A trunk scan read back from its evidence GLB, to align rings against after the AR session. Only the mesh is kept
/// (the raw depth points stay with the session), so rings are fitted to the mesh's slices, as AR does where the depth
/// points do not reach.
public struct SavedScan: Sendable {
    public var mesh: Mesh

    public init(mesh: Mesh) {
        self.mesh = mesh
    }

    public init(glb: Data) throws {
        self.init(mesh: try GLB.File(glb).mesh())
    }

    /// The ground under the trunk, from the mesh's near-horizontal triangles, as a scan without classified floor finds
    /// it (`TrunkScan`); nil when the mesh has nothing near the trunk.
    public var estimatedGroundHeight: Double? {
        mesh.groundHeight(near: .zero, radius: 1.5)
    }

    /// How high the mesh reaches above the ground at `groundHeight`, in metres.
    public func top(groundHeight: Double) -> Double? {
        mesh.bounds.map { Double($0.max.y) - groundHeight }
    }

    /// A circle fitted to the mesh's walls `height` metres above the ground, round the trunk nearest `near` (from the
    /// trunk's base, x and z): the ground and anything flat are left out, and above a fork it is one stem. Throws
    /// when the mesh has too little of a trunk there.
    public func fitSection(at height: Double, groundHeight: Double, near: SIMD2<Double> = .zero) throws -> FittedCircle
    {
        try TrunkStems.ring(through: mesh.trunkSlices(atHeight: groundHeight + height), nearest: near)
    }

    /// Rings round every trunk the mesh crosses `height` metres above the ground within `radius` of `near`: one below
    /// a fork, a ring per stem above it. Largest first.
    public func stems(
        at height: Double, groundHeight: Double, near: SIMD2<Double>, within radius: Double
    ) -> [FittedCircle] {
        TrunkStems.rings(through: mesh.trunkSlices(atHeight: groundHeight + height), near: near, within: radius)
    }

    /// A ring snapped to the mesh at its height, round the trunk nearest its centre: its radius and centre from
    /// `fitSection`, marked as fitted.
    public func snapping(_ section: TreeSection, groundHeight: Double, lean: Lean? = nil) throws -> TreeSection {
        section.snapped(
            to: try fitSection(at: section.height, groundHeight: groundHeight, near: Self.centre(of: section, lean)))
    }

    static func centre(of section: TreeSection, _ lean: Lean?) -> SIMD2<Double> {
        let centre = WireframeTree.centre(of: section, lean: lean)
        return SIMD2(Double(centre.x), Double(centre.z))
    }

    /// Every trunk ring the mesh can fit snapped to it, except those confirmed against the tree; the rest stay as
    /// they were. Where the mesh shows more than one stem at a ring's height, the ring is split
    /// (`TreeProfile.splitting`): stems coming out of it fork off its stem, stems standing apart from it come out of
    /// the ground, and stems already in the profile go on up. Above where a stem forks, a ring left on it that the
    /// mesh shows as one stem joins the stem it fits, and one it cannot fit goes. Every stem is then carried up to
    /// the crown's base (`TreeProfile.reachingCrown`). Returns the profile, how many rings snapped, and how many
    /// stems the trunk has besides the main one (0 for one trunk).
    public func snappingTrunk(
        _ profile: TreeProfile, groundHeight: Double, lean: Lean? = nil
    ) -> (profile: TreeProfile, snapped: Int, stems: Int) {
        var profile = profile
        var snapped = 0
        for ring in profile.trunk where ring.source != .confirmed {
            // Split away by a ring below it.
            guard let ring = profile.section(ring.id) else { continue }
            let centre = Self.centre(of: ring, lean)
            if ring.height >= Self.lowestFork {
                let found = stems(
                    at: ring.height, groundHeight: groundHeight, near: centre, within: Self.forkReach(ring))
                if found.count >= 2 {
                    snapped += profile.splitting(ring.id, into: found).count
                    continue
                }
            }
            if let fork = profile.forkHeight(of: ring.stem), ring.height > fork + 0.01 {
                // Above where its stem forks: on one of the stems growing off it, or nowhere.
                let onto = profile.descendants(of: ring.stem).filter {
                    !(profile.forkHeight(of: $0).map { $0 < ring.height - 0.01 } ?? false)
                }
                if let fitted = try? snapping(ring, groundHeight: groundHeight, lean: lean),
                    let stem = profile.nearestStem(to: fitted.offset ?? .zero, below: ring.height, among: onto)
                {
                    var onStem = fitted
                    onStem.stem = stem
                    profile[ring.id] = onStem
                    snapped += 1
                } else {
                    profile[ring.id] = nil
                }
                continue
            }
            guard let fitted = try? snapping(ring, groundHeight: groundHeight, lean: lean) else { continue }
            profile[ring.id] = fitted
            snapped += 1
        }
        return (profile.reachingCrown(lean: lean), snapped, profile.stemIDs.count)
    }

    /// No trunk forks lower than this, in metres: below it, two pieces are roots or a buttress.
    public static let lowestFork = 0.8

    /// How far from a ring's centre its stems are looked for: two metres, or three times its radius.
    static func forkReach(_ ring: TreeSection) -> Double { max(2, 3 * ring.radius) }

    /// Splits the ring `id` into a ring per stem the mesh shows at its height, as `snappingTrunk` does; nil when the
    /// mesh shows one stem or none there. Returns the profile and the stems' ring ids.
    public func splitting(
        _ profile: TreeProfile, at id: TreeSection.ID, groundHeight: Double, lean: Lean? = nil
    ) -> (profile: TreeProfile, rings: [TreeSection.ID])? {
        guard let ring = profile.section(id), ring.part == .trunk else { return nil }
        let found = stems(
            at: ring.height, groundHeight: groundHeight, near: Self.centre(of: ring, lean),
            within: Self.forkReach(ring))
        guard found.count >= 2 else { return nil }
        var profile = profile
        let rings = profile.splitting(id, into: found)
        // The stem's rings above the split go on to the stems it forks into, or go, as when the whole trunk is
        // snapped. A stem that goes on through the split keeps them.
        if let fork = profile.forkHeight(of: ring.stem) {
            let onto = profile.descendants(of: ring.stem)
            for above in profile.rings(onStem: ring.stem) where above.height > fork + 0.01 && above.source != .confirmed
            {
                if let fitted = try? snapping(above, groundHeight: groundHeight, lean: lean),
                    let stem = profile.nearestStem(to: fitted.offset ?? .zero, below: above.height, among: onto)
                {
                    var onStem = fitted
                    onStem.stem = stem
                    profile[above.id] = onStem
                } else {
                    profile[above.id] = nil
                }
            }
        }
        return (profile.reachingCrown(lean: lean), rings)
    }
}

extension TreeProfile {
    /// The stem among `stems` (every stem when nil) whose highest ring below `height` is nearest `centre` (x, z from
    /// the trunk's base); nil when none has a ring below `height`.
    public func nearestStem(to centre: SIMD2<Double>, below height: Double, among stems: [Int]? = nil) -> Int? {
        (stems ?? stemIDs).compactMap { stem -> (Int, Double)? in
            guard let ring = rings(onStem: stem).last(where: { $0.height < height - 0.01 }) else { return nil }
            return (stem, simd_distance(ring.offset ?? .zero, centre))
        }
        .min { $0.1 < $1.1 }?.0
    }

    /// Where a stem (nil: the main trunk) that ends in a fork forks: the lowest ring of the stems forking off it. Nil
    /// for a stem that goes on, with one stem or none forking off it.
    public func forkHeight(of stem: Int?) -> Double? {
        guard endsInFork(stem) else { return nil }
        return forks(of: stem).compactMap { rings(onStem: $0).first?.height }.min()
    }

    /// Every stem carried up to the crown's base: a ring a metre (`TrunkSteps.heights`) and one at the crown's base
    /// added where none is, up the main trunk and each stem that does not end in a fork, continuing the line and the
    /// taper of the rings below (`TrunkTaper`; a stem with one ring leaves where it starts along the line from there).
    /// Rings already there are left as they are; rings set by eye above the crown's base go.
    public func reachingCrown(lean: Lean? = nil) -> TreeProfile {
        guard let top = crown.first?.height, top >= 1 else { return self }
        var profile = self
        for ring in profile.trunk where !ring.isKept && ring.height > top + 0.05 { profile[ring.id] = nil }
        let heights = TrunkSteps.heights(below: top) + [top]
        func missing(_ rings: [TreeSection], above floor: Double) -> [Double] {
            heights.filter { h in h > floor + 0.25 && !rings.contains { abs($0.height - h) < 0.25 } }
        }
        if !profile.endsInFork(nil) {
            let main = profile.mainTrunk
            if let highest = main.last {
                let taper = TrunkTaper(main, lean: lean)
                for h in missing(main, above: highest.height) {
                    let ring = TreeSection(
                        part: .trunk, height: h, radius: taper?.radius(at: h) ?? highest.radius,
                        offset: taper?.centre(at: h) ?? highest.offset)
                    profile[ring.id] = ring
                }
            }
        }
        for stem in profile.stemIDs where !profile.endsInFork(stem) {
            let rings = profile.rings(onStem: stem)
            guard let highest = rings.last else { continue }
            let line = Self.stemLine(rings, below: profile.start(ofStem: stem))
            for h in missing(rings, above: highest.height) {
                let ring = TreeSection(part: .trunk, height: h, radius: highest.radius, offset: line(h), stem: stem)
                profile[ring.id] = ring
            }
        }
        return profile
    }

    /// Where a stem's axis is at a height: the line through its rings' centres, or, with its rings too close in
    /// height for a slope, through where it starts and its own. Never leaning more than 40°.
    static func stemLine(_ rings: [TreeSection], below fork: TreeSection?) -> (Double) -> SIMD2<Double> {
        var samples = rings.map { (h: $0.height, c: $0.offset ?? .zero) }
        let spread = (samples.map(\.h).max() ?? 0) - (samples.map(\.h).min() ?? 0)
        if spread < 0.2, let fork { samples.insert((fork.height, fork.offset ?? .zero), at: 0) }
        let n = Double(samples.count)
        let meanH = samples.reduce(0) { $0 + $1.h } / n
        let meanC = samples.reduce(SIMD2<Double>.zero) { $0 + $1.c } / n
        let shh = samples.reduce(0) { $0 + ($1.h - meanH) * ($1.h - meanH) }
        var slope = SIMD2<Double>.zero
        if shh > 1e-6 {
            slope = samples.reduce(SIMD2<Double>.zero) { $0 + ($1.h - meanH) * ($1.c - meanC) } / shh
        }
        let maximum = tan(40 * Double.pi / 180)
        if simd_length(slope) > maximum { slope *= maximum / simd_length(slope) }
        return { h in meanC + slope * (h - meanH) }
    }

    /// Two rings at one height are one stem's when their centres are no further apart than this beyond their radii,
    /// in metres.
    static let continuation = 0.25

    /// Replaces a trunk ring with a ring per circle fitted to the scan at its height, each on a stem:
    /// - a circle where another stem has a ring at this height already is that ring, and is left out;
    /// - each other circle comes out of the stem whose ring below is nearest it, when near enough
    ///   (`continuation`): a stem with one such circle goes on through it, and a stem with two or more forks into
    ///   them (`TreeStem.Origin.fork`) and ends there;
    /// - and a circle out of no stem comes out of the ground (`TreeStem.Origin.ground`).
    ///
    /// The ring's own stem goes on, forks or ends here; it takes the ring's place when it goes on. Returns the ids of
    /// the rings put on the circles, in their order.
    @discardableResult
    public mutating func splitting(_ id: TreeSection.ID, into circles: [FittedCircle]) -> [TreeSection.ID] {
        guard let ring = section(id), ring.part == .trunk else { return [] }
        let own = ring.stem
        let ownOrigin = own.map { stem($0).origin }
        let height = ring.height
        func centre(_ ring: TreeSection) -> SIMD2<Double> { ring.offset ?? .zero }
        // Each stem that reaches up to this height, by its ring below it; the ring's own stem by the ring itself when
        // it has none below.
        var below: [Int?: TreeSection] = [:]
        for stem in [nil] + stemIDs.map(Optional.some) {
            if let fork = forkHeight(of: stem), fork <= height + 0.01 { continue }
            if let lower = rings(onStem: stem).last(where: { $0.height < height - 0.01 }) {
                below[stem] = lower
            } else if stem == own {
                below[stem] = ring
            }
        }
        // Circles where another stem has a ring here already are those rings.
        let atHeight = trunk.filter { $0.id != id && abs($0.height - height) < 0.05 }
        let fresh = circles.filter { circle in
            !atHeight.contains { simd_distance(centre($0), circle.center) < max($0.radius, circle.radius) }
        }
        var groups: [Int?: [FittedCircle]] = [:]
        var apart: [FittedCircle] = []
        for circle in fresh {
            let nearest = below.min { a, b in
                simd_distance(centre(a.value), circle.center) < simd_distance(centre(b.value), circle.center)
            }
            if let nearest,
                simd_distance(centre(nearest.value), circle.center)
                    <= nearest.value.radius + circle.radius + Self.continuation
            {
                groups[nearest.key, default: []].append(circle)
            } else {
                apart.append(circle)
            }
        }

        var placed: [(circle: FittedCircle, ring: TreeSection.ID)] = []
        self[id] = nil
        for (stem, group) in groups.sorted(by: { ($0.key ?? -1) < ($1.key ?? -1) }) {
            let hasRingHere = rings(onStem: stem).contains { abs($0.height - height) < 0.05 }
            if group.count == 1 {
                let circle = group[0]
                if stem == own {
                    var kept = ring.snapped(to: circle)
                    kept.stem = own
                    self[kept.id] = kept
                    // Taking its ring out above may have dropped where it starts.
                    if let own, let ownOrigin { setOrigin(ownOrigin, ofStem: own) }
                    placed.append((circle, kept.id))
                } else if !hasRingHere {
                    let added = TreeSection(part: .trunk, height: height, radius: ring.radius, stem: stem)
                        .snapped(to: circle)
                    self[added.id] = added
                    placed.append((circle, added.id))
                }
            } else if stem == own || !hasRingHere {
                // It forks here, into each of them. (Another stem with a ring here forks when that ring is split.)
                for circle in group {
                    let added = TreeSection(part: .trunk, height: height, radius: ring.radius).snapped(to: circle)
                    let new = addStem([added], origin: .fork(parent: stem))
                    placed.append((circle, rings(onStem: new)[0].id))
                }
            }
        }
        for circle in apart {
            let added = TreeSection(part: .trunk, height: height, radius: ring.radius).snapped(to: circle)
            let new = addStem([added], origin: .ground(base: circle.center))
            placed.append((circle, rings(onStem: new)[0].id))
        }
        return circles.compactMap { circle in placed.first { $0.circle.center == circle.center }?.ring }
    }
}

/// One of Gerardus's trees near a census tree, with its base's offset east and north of the census tree's map
/// position, in metres.
public struct NearbyVectorTree: Equatable, Sendable {
    public var tree: GerardusTree
    public var offset: SIMD2<Double>

    public var distance: Double { simd_length(offset) }
}

extension GerardusTree {
    /// Gerardus's trees within `radius` metres of a map position, nearest first. `sites` are the loaded sites'
    /// features, each with its georeference; a tree in two overlapping sites is given once.
    public static func near(
        _ position: GeoPoint, in sites: [(features: [VectorReference.Feature], georeference: SiteGeoreference)],
        within radius: Double = 15
    ) -> [NearbyVectorTree] {
        let frame = LocalFrame(origin: position)
        var seen: Set<String> = []
        var found: [NearbyVectorTree] = []
        for site in sites {
            // The site frame is in metres too, so the rough cut is made there before the exact offset.
            let here = site.georeference.site(of: position)
            for tree in SiteWireframes.trees(in: site.features) where !seen.contains(tree.id) {
                let base = SIMD2(Double(tree.base.x), Double(tree.base.y))
                guard simd_distance(base, here) <= radius * 1.01 + 1 else { continue }
                let enu = frame.enu(of: site.georeference.geo(x: base.x, y: base.y))
                let offset = SIMD2(enu.east, enu.north)
                guard simd_length(offset) <= radius else { continue }
                seen.insert(tree.id)
                found.append(NearbyVectorTree(tree: tree, offset: offset))
            }
        }
        return found.sorted { $0.distance < $1.distance }
    }
}
