import CanopyCapture
import CanopyMap
import CanopyModel
import Foundation

/// Trees of several stems (`docs/MULTI-STEM.md`): each stem's DBH and where it stands, recorded on the tree, and a
/// clump split into trees.
extension AppModel {
    /// Records the stems of a measured tree as the player sorted them, with no new scan.
    @discardableResult
    func saveStems(of treeID: UUID, dbh: DBH, stems: [StemMeasure]) async -> Bool {
        await record(.stemsMeasured(treeID: treeID, dbh: dbh, stems: stems)) != nil
    }

    /// Why stems cannot be split off as a tree at `position`, or nil when they can: Gerardus keeps one tree per L22
    /// cell (about 2 m across), so the new tree must not stand in another's.
    func splitRefusal(at position: GeoPoint) -> String? {
        guard let other = census.tree(standingAt: position) else { return nil }
        return "Those stems stand in the same 2 m cell as \(other.name), and the map keeps one tree a cell. Move "
            + "\(other.name) first, or keep them on this tree."
    }

    /// Splits stems off a measured tree into a new tree of their own, proposed at `position` with their stems and
    /// the scan that found them as its evidence: the tree keeps the rest (`keeping`). The new tree is drawn in
    /// `profile` from now on. Returns the new tree, or nil when it could not be recorded (see `splitRefusal`).
    func splitOff(
        from tree: Tree, keeping: (dbh: DBH, stems: [StemMeasure]), at position: Position, dbh: DBH,
        stems: [StemMeasure], evidence: BlobRef?, profile: TreeProfile?
    ) async -> Tree? {
        if let refusal = splitRefusal(at: position.geo) {
            error = refusal
            return nil
        }
        let new = Tree(
            meta: RecordMeta(playerID: player.id, chunk: position.chunk), position: position,
            countStatus: .proposed, dbh: dbh, evidenceRefs: evidence.map { [$0] } ?? [],
            stems: stems.count > 1 ? stems : nil)
        guard await record(.treeAdded(new)) != nil else { return nil }
        await saveStems(of: tree.id, dbh: keeping.dbh, stems: keeping.stems)
        if let profile { treeProfiles[MapLayers.censusWireframeID(new.id)] = profile }
        return census.trees[new.id]
    }
}

/// A profile's stems at breast height as a tree records them (`Tree.stems`).
enum StemRecord {
    /// The uncertainty of a stem's diameter set by eye, in metres.
    static let byEye = 0.05

    /// Each stem of `profile` at breast height: its diameter (the main trunk's from `mainDBH` when given, as the scan
    /// measured it there), and where it stands from `anchor`, by `place`, which gives the map position of an AR world
    /// point. `base` is the AR world point the profile stands on.
    static func measures(
        _ profile: TreeProfile, lean: Lean?, base: SIMD3<Float>, mainDBH: DBH?, anchor: GeoPoint,
        place: (SIMD3<Float>) -> GeoPoint?
    ) -> [StemMeasure] {
        let frame = LocalFrame(origin: anchor)
        return profile.breastHeightStems(lean: lean).map { stem in
            let diameter: Quantity
            if stem.stem == nil, let mainDBH {
                diameter = mainDBH.diameter
            } else if let sigma = stem.radiusUncertainty, stem.isMeasured {
                diameter = Quantity(stem.diameter, uncertainty: (pow(2 * sigma, 2) + 0.005 * 0.005).squareRoot())
            } else {
                diameter = Quantity(stem.diameter, uncertainty: stem.isMeasured ? 0.01 : byEye)
            }
            // Where it stands: the main trunk and a stem from the ground on their bases; a stem forking below breast
            // height where it crosses it, so two stems of one fork are told apart.
            let fromGround = stem.stem.map { profile.groundStems.contains($0) } ?? true
            let ground = fromGround ? profile.base(of: stem.stem) : stem.centre
            let point = base + SIMD3(Float(ground.x), 0, Float(ground.y))
            let east: Double
            let north: Double
            if let geo = place(point) {
                let enu = frame.enu(of: geo)
                (east, north) = (enu.east, enu.north)
            } else {
                // Not placed on the map: ARKit's x is east and its -z north.
                (east, north) = (ground.x, -ground.y)
            }
            return StemMeasure(diameter: diameter, east: east, north: north)
        }
    }

    /// The tree's DBH for `stems`: the equivalent of them all, or the one stem's.
    static func dbh(_ stems: [StemMeasure], method: DBH.Method = .lidarCircleFit) -> DBH? {
        DBH.equivalent(of: stems.map(\.diameter), method: method)
    }

    /// The stems a tree records: nil for one.
    static func recorded(_ stems: [StemMeasure]) -> [StemMeasure]? { stems.count > 1 ? stems : nil }
}
