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
    public var savedAt: Date

    public init(
        scan: BlobRef, treeID: UUID, profile: TreeProfile, groundHeight: Double, vectorTree: VectorTreePlacement? = nil,
        correctedPosition: GeoPoint? = nil, crown: CrownShape? = nil, savedAt: Date = .now
    ) {
        self.scan = scan
        self.treeID = treeID
        self.profile = profile
        self.groundHeight = groundHeight
        self.vectorTree = vectorTree
        self.correctedPosition = correctedPosition
        self.crown = crown
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
    /// they were. Where the trunk forks, a ring below the fork that the mesh shows as two stems or more becomes a
    /// ring on each (`TreeSection.stem`), numbered to follow the stems below. Returns the profile, how many rings
    /// snapped, and how many stems the trunk forks into (0 when it does not).
    public func snappingTrunk(
        _ profile: TreeProfile, groundHeight: Double, lean: Lean? = nil
    ) -> (profile: TreeProfile, snapped: Int, stems: Int) {
        var profile = profile
        var snapped = 0
        for ring in profile.trunk where ring.source != .confirmed {
            let centre = Self.centre(of: ring, lean)
            if ring.stem == nil, ring.height >= Self.lowestFork {
                let found = stems(
                    at: ring.height, groundHeight: groundHeight, near: centre, within: Self.forkReach(ring))
                if found.count >= 2 {
                    snapped += profile.splitting(ring.id, into: found).count
                    continue
                }
            }
            guard let fitted = try? snapping(ring, groundHeight: groundHeight, lean: lean) else { continue }
            profile[ring.id] = fitted
            snapped += 1
        }
        return (profile, snapped, profile.stems.count)
    }

    /// No trunk forks lower than this, in metres: below it, two pieces are roots or a buttress.
    public static let lowestFork = 0.8

    /// How far from a ring's centre its stems are looked for: two metres, or three times its radius.
    static func forkReach(_ ring: TreeSection) -> Double { max(2, 3 * ring.radius) }

    /// Splits the ring nearest `height` on the main trunk into a ring per stem the mesh shows there, as
    /// `snappingTrunk` does; nil when the mesh shows one trunk or none there. Returns the profile and the stems'
    /// ring ids.
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
        return (profile, rings)
    }
}

extension TreeProfile {
    /// Replaces a trunk ring with one ring per circle, each on a stem (`TreeSection.stem`), fitted to the scan. A
    /// circle takes the number of the stem whose ring below is nearest it, so a stem keeps its number up the tree;
    /// the rest take numbers not yet used. Returns the new rings' ids, in the circles' order.
    @discardableResult
    public mutating func splitting(_ id: TreeSection.ID, into circles: [FittedCircle]) -> [TreeSection.ID] {
        guard let ring = section(id) else { return [] }
        let below = stems.compactMapValues { rings in rings.last { $0.height < ring.height - 0.01 } }
        var free = below.keys.sorted()
        var next = (stems.keys.max() ?? -1) + 1
        var ids: [TreeSection.ID] = []
        self[id] = nil
        for circle in circles {
            let stem: Int
            if let nearest = free.min(by: { a, b in
                simd_distance(below[a]?.offset ?? .zero, circle.center)
                    < simd_distance(below[b]?.offset ?? .zero, circle.center)
            }) {
                stem = nearest
                free.removeAll { $0 == nearest }
            } else {
                stem = next
                next += 1
            }
            let added = TreeSection(part: .trunk, height: ring.height, radius: ring.radius, stem: stem)
                .snapped(to: circle)
            self[added.id] = added
            ids.append(added.id)
        }
        return ids
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
