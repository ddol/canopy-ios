import CanopyModel
import Foundation
import simd

/// One horizontal cross-section of a tree: a ring of `radius` at `height` above the ground, of the trunk or of the
/// crown. A profile is a stack of these, so a trunk can taper and a crown can bulge instead of being two cylinders.
public struct TreeSection: Equatable, Sendable, Codable, Identifiable {
    public enum Part: String, Codable, Sendable, CaseIterable {
        case trunk
        case crown

        public var label: String {
            switch self {
            case .trunk: "Trunk"
            case .crown: "Foliage"
            }
        }
    }

    /// How the ring got its size.
    public enum Source: String, Codable, Sendable, CaseIterable {
        /// From the four-slider shape, or moved by eye.
        case eye
        /// Fitted to the scan's points at this height.
        case scan
        /// Fitted to the trunk's edges in the camera image, above where the scan's depth points reach
        /// (`RingAligner`).
        case camera
        /// Checked against the real tree by the player.
        case confirmed
    }

    public var id: UUID
    public var part: Part
    /// Above the ground, in metres.
    public var height: Double
    /// In metres.
    public var radius: Double
    public var source: Source
    /// Where the ring's centre is, horizontally, from the trunk's base (ARKit x and z, in metres) when it was
    /// fitted to the scan or aligned to the camera, or predicted from the rings below (`TrunkSteps.predicted`, set by
    /// eye); nil puts the ring on the leaning axis. So a centre of its own does not mean the scan fitted the ring.
    public var offset: SIMD2<Double>?
    /// Standard uncertainty of the radius when it was fitted.
    public var radiusUncertainty: Double?
    /// Which stem the ring is on (`TreeStem.id`); nil on the main trunk, the one the tree's base stands on. The rings of
    /// a stem are joined to each other, and its lowest to where it starts (`TreeStem.Origin`): the ring of the stem
    /// it forks off below it, so forked stems funnel into one trunk, or the ground.
    public var stem: Int?

    public init(
        id: UUID = UUID(), part: Part, height: Double, radius: Double, source: Source = .eye,
        offset: SIMD2<Double>? = nil, radiusUncertainty: Double? = nil, stem: Int? = nil
    ) {
        self.id = id
        self.part = part
        self.height = height
        self.radius = radius
        self.source = source
        self.offset = offset
        self.radiusUncertainty = radiusUncertainty
        self.stem = stem
    }

    /// Whether the ring stays when the shape sliders redraw the rest: a snapped, aligned or confirmed ring does.
    public var isKept: Bool { source != .eye }

    public var diameter: Double { radius * 2 }
}

/// Where one stem of a tree starts. A tree is a main trunk (rings on no stem) and any number of stems, each
/// growing from the ground or forking off another stem, and they can fork again: a "Y", a clump of five stems that
/// come out of the ground apart, or a trunk that forks and forks again.
public struct TreeStem: Equatable, Sendable, Codable, Identifiable {
    public enum Origin: Equatable, Sendable, Codable {
        /// Forks off `parent` (nil for the main trunk) at that stem's highest ring below this one's lowest.
        case fork(parent: Int?)
        /// Comes out of the ground on its own, at `base` from the tree's base (x, z, as `TreeSection.offset`).
        case ground(base: SIMD2<Double>)
    }

    public var id: Int
    public var origin: Origin

    public init(id: Int, origin: Origin) {
        self.id = id
        self.origin = origin
    }

    /// A stem no profile says otherwise of forks off the main trunk: how every stem started before the graph was kept.
    public static func `default`(_ id: Int) -> TreeStem { TreeStem(id: id, origin: .fork(parent: nil)) }

    public var parent: Int?? {
        if case .fork(let parent) = origin { return .some(parent) }
        return nil
    }
}

/// One stem's cross-section at breast height (`DBH.standardHeight`), as an inventory measures a tree of several:
/// each stem that reaches it, and for a stem that forks below it, each of its stems above the fork.
public struct BreastHeightStem: Equatable, Sendable {
    /// Nil for the main trunk.
    public var stem: Int?
    public var radius: Double
    /// From the tree's base (x, z).
    public var centre: SIMD2<Double>
    /// Standard uncertainty of the radius, when the rings either side were fitted.
    public var radiusUncertainty: Double?
    /// Whether the rings either side were fitted to the scan, aligned or confirmed, not set by eye.
    public var isMeasured: Bool

    public var diameter: Double { 2 * radius }
}

/// The cross-sections of a tree from the ground up. Kept sorted by height, trunk before crown at the same height.
public struct TreeProfile: Equatable, Sendable, Codable {
    public private(set) var sections: [TreeSection]
    /// Where the stems that do not fork off the main trunk start (`TreeStem.Origin`). A stem with rings and no entry
    /// here forks off the main trunk, as every stem did before stems could start elsewhere, so a profile saved then
    /// reads the same.
    public private(set) var stemGraph: [TreeStem] = []

    public static let radii = 0.015...17.5
    public static let heights = 0.0...45.0

    public init(sections: [TreeSection], stems: [TreeStem] = []) {
        self.sections = sections
        self.stemGraph = stems
        sort()
        tidyGraph()
    }

    private enum CodingKeys: String, CodingKey {
        case sections
        case stemGraph = "stems"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sections: try container.decode([TreeSection].self, forKey: .sections),
            stems: try container.decodeIfPresent([TreeStem].self, forKey: .stemGraph) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sections, forKey: .sections)
        if !stemGraph.isEmpty { try container.encode(stemGraph, forKey: .stemGraph) }
    }

    /// Where a new trunk's rings start, in metres above the ground: a ring a metre, from the ground to 4 m.
    public static let trunkHeights: [Double] = [0, 1, 2, 3, 4]

    /// The rings a four-slider shape stands for: the trunk at the ground and every metre to 4 m (`trunkHeights`), and
    /// at the crown's base when that is higher; the crown at its base, its middle and its top.
    public init(form: TreeForm) {
        let form = form.clamped
        let trunkRadius = form.trunkDiameter / 2
        var sections = Self.trunkHeights.map { TreeSection(part: .trunk, height: $0, radius: trunkRadius) }
        if form.crownBase > Self.trunkHeights.last! + 0.05 {
            sections.append(TreeSection(part: .trunk, height: form.crownBase, radius: trunkRadius))
        }
        let crownRadius = form.crownWidth / 2
        sections.append(TreeSection(part: .crown, height: form.crownBase, radius: crownRadius))
        if form.crownHeight > 1 {
            sections.append(
                TreeSection(part: .crown, height: form.crownBase + form.crownHeight / 2, radius: crownRadius))
        }
        sections.append(TreeSection(part: .crown, height: form.height, radius: crownRadius))
        self.init(sections: sections)
    }

    /// A tree of several stems as its record has them (`Tree.stems`, east and north of its position), with no rings
    /// fitted: the stem standing nearest the tree's position is the main trunk, of the form's crown, and each other
    /// comes out of the ground where it stands, with a ring at breast height and one at the crown's base. The form's
    /// trunk diameter is the main stem's. With fewer than two stems, the form's profile.
    public init(form: TreeForm, stems: [StemMeasure]) {
        guard stems.count > 1, let main = stems.min(by: { $0.distance < $1.distance }) else {
            self.init(form: form)
            return
        }
        var form = form
        form.trunkDiameter = main.diameter.value
        self.init(form: form.clamped)
        let top = self.form.crownBase
        for stem in stems where stem != main {
            // ARKit's frame and the 3D map's: x east, z south.
            let at = SIMD2(stem.east - main.east, -(stem.north - main.north))
            let radius = stem.diameter.value / 2
            let rings = [DBH.standardHeight, max(top, DBH.standardHeight + 0.5)].map {
                TreeSection(part: .trunk, height: $0, radius: radius, offset: at)
            }
            addStem(rings, origin: .ground(base: at))
        }
    }

    public var trunk: [TreeSection] { sections.filter { $0.part == .trunk } }
    /// The trunk's rings below any fork: those on no stem.
    public var mainTrunk: [TreeSection] { sections.filter { $0.part == .trunk && $0.stem == nil } }
    /// The stems a forked trunk splits into, by number, each with its rings from the bottom up.
    public var stems: [Int: [TreeSection]] {
        Dictionary(grouping: trunk.filter { $0.stem != nil }) { $0.stem! }
    }

    /// The trunk's radius at `height` on the main trunk: between the rings either side of it, or the nearest one
    /// beyond the end.
    public func trunkRadius(at height: Double) -> Double? {
        let rings = mainTrunk
        switch (rings.last { $0.height <= height }, rings.first { $0.height >= height }) {
        case (let lower?, let upper?) where upper.height > lower.height:
            let t = (height - lower.height) / (upper.height - lower.height)
            return lower.radius + (upper.radius - lower.radius) * t
        case (let lower?, _): return lower.radius
        case (nil, let upper?): return upper.radius
        case (nil, nil): return nil
        }
    }
    public var crown: [TreeSection] { sections.filter { $0.part == .crown } }

    /// The four-slider shape this profile sums to: the trunk's diameter at the ring nearest breast height, the top
    /// ring's height, the crown from its lowest ring to the top and its widest ring.
    public var form: TreeForm {
        let trunk = trunk
        let crown = crown
        let height = max(sections.map(\.height).max() ?? 1, TreeForm.heights.lowerBound)
        let breast = trunkRadius(at: DBH.standardHeight) ?? trunk.first?.radius
        let crownBase = crown.first?.height ?? trunk.last?.height ?? height * 2 / 3
        let crownWidth = (crown.map(\.radius).max() ?? trunk.last?.radius ?? 0.5) * 2
        return TreeForm(
            trunkDiameter: (breast ?? 0.15) * 2, height: height, crownHeight: height - crownBase,
            crownWidth: crownWidth
        ).clamped
    }

    /// The profile a changed shape gives: the rings fitted or confirmed against the tree stay where they are, and
    /// the rest are drawn again from the shape.
    ///
    /// The shape is of the main trunk and the crown, so the other stems stay as they are, rings by eye and all, and
    /// so does where each starts.
    public func following(_ form: TreeForm) -> TreeProfile {
        let kept = sections.filter { $0.isKept || ($0.part == .trunk && $0.stem != nil) }
        var fresh = TreeProfile(form: form).sections
        // A fresh ring within a few centimetres of a kept one of the same part, on the main trunk, would double it.
        fresh.removeAll { ring in
            kept.contains { $0.part == ring.part && $0.stem == nil && abs($0.height - ring.height) < 0.05 }
        }
        return TreeProfile(sections: kept + fresh, stems: stemGraph)
    }

    public func section(_ id: TreeSection.ID) -> TreeSection? {
        sections.first { $0.id == id }
    }

    public subscript(id: TreeSection.ID) -> TreeSection? {
        get { section(id) }
        set {
            sections.removeAll { $0.id == id }
            if var ring = newValue {
                ring.height = min(max(ring.height, Self.heights.lowerBound), Self.heights.upperBound)
                ring.radius = min(max(ring.radius, Self.radii.lowerBound), Self.radii.upperBound)
                sections.append(ring)
            }
            sort()
            if newValue == nil { tidyGraph() }
        }
    }

    /// A new ring of the same part above `id`: halfway to the next ring of that part, or a metre up from the top
    /// one, with the same radius. Returns the new ring's id.
    @discardableResult
    public mutating func addSection(above id: TreeSection.ID) -> TreeSection.ID? {
        guard let ring = section(id) else { return nil }
        let same = sections.filter { $0.part == ring.part && $0.stem == ring.stem }
        let next = same.first { $0.height > ring.height + 0.01 }
        let height = next.map { (ring.height + $0.height) / 2 } ?? min(ring.height + 1, Self.heights.upperBound)
        let radius = next.map { (ring.radius + $0.radius) / 2 } ?? ring.radius
        // A ring on a stem goes up that stem, from its centre.
        let added = TreeSection(
            part: ring.part, height: height, radius: radius, offset: ring.stem == nil ? nil : ring.offset,
            stem: ring.stem)
        sections.append(added)
        sort()
        return added.id
    }

    /// Takes a ring out; a part keeps at least one ring.
    public mutating func removeSection(_ id: TreeSection.ID) {
        guard let ring = section(id), sections.filter({ $0.part == ring.part }).count > 1 else { return }
        sections.removeAll { $0.id == id }
        tidyGraph()
    }

    // MARK: Stems

    /// Where a stem starts: as the graph says, or forking off the main trunk.
    public func stem(_ id: Int) -> TreeStem {
        stemGraph.first { $0.id == id } ?? .default(id)
    }

    /// Every stem with rings, by number.
    public var stemIDs: [Int] { Set(trunk.compactMap(\.stem)).sorted() }

    /// The trunk's rings on one stem (nil: the main trunk), from the bottom up.
    public func rings(onStem id: Int?) -> [TreeSection] {
        trunk.filter { $0.stem == id }
    }

    /// The stems that fork off `parent` (nil: the main trunk).
    public func forks(of parent: Int?) -> [Int] {
        stemIDs.filter { stem($0).origin == .fork(parent: parent) }
    }

    /// The stems that come out of the ground on their own.
    public var groundStems: [Int] {
        stemIDs.filter { if case .ground = stem($0).origin { true } else { false } }
    }

    /// Whether a stem (nil: the main trunk) ends where it forks: two stems or more fork off it, so it does not go on
    /// above them.
    public func endsInFork(_ id: Int?) -> Bool { forks(of: id).count >= 2 }

    /// Where a stem's lowest ring is joined to: the ring of its parent below it, or, for a stem from the ground, a
    /// ring of its lowest ring's size on the ground at its base. Nil for the main trunk, and for a stem forking off a
    /// stem with no ring below it.
    public func start(ofStem id: Int) -> TreeSection? {
        guard let first = rings(onStem: id).first else { return nil }
        switch stem(id).origin {
        case .fork(let parent):
            return rings(onStem: parent).last { $0.height < first.height - 1e-6 }
        case .ground(let base):
            return TreeSection(
                id: Self.groundRingID(id), part: .trunk, height: 0, radius: first.radius, source: first.source,
                offset: base, stem: id)
        }
    }

    /// The same id every time for a stem's ring on the ground, which is drawn, never kept.
    static func groundRingID(_ stem: Int) -> UUID {
        UUID(uuid: (0xC4, 0x0E, 0x57, 0xE4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(stem >> 8 & 0xFF), UInt8(stem & 0xFF)))
    }

    /// A number no stem has yet.
    public var nextStemID: Int { (Set(stemIDs).union(stemGraph.map(\.id)).max() ?? -1) + 1 }

    /// Sets where a stem starts.
    public mutating func setOrigin(_ origin: TreeStem.Origin, ofStem id: Int) {
        stemGraph.removeAll { $0.id == id }
        if origin != .fork(parent: nil) { stemGraph.append(TreeStem(id: id, origin: origin)) }
        stemGraph.sort { $0.id < $1.id }
    }

    /// Adds a stem of `rings` (their `stem` set to its number) starting at `origin`. Returns its number.
    @discardableResult
    public mutating func addStem(_ rings: [TreeSection], origin: TreeStem.Origin) -> Int {
        let id = nextStemID
        for var ring in rings {
            ring.part = .trunk
            ring.stem = id
            sections.append(ring)
        }
        sort()
        setOrigin(origin, ofStem: id)
        return id
    }

    /// The stems that grow off `id`, at any depth.
    public func descendants(of id: Int?) -> [Int] {
        var found: [Int] = []
        var queue = forks(of: id)
        while let next = queue.popLast() {
            found.append(next)
            queue += forks(of: next)
        }
        return found.sorted()
    }

    /// Takes a stem out with every stem that grows off it. The main trunk (nil) is not taken out: its rings are,
    /// and the stems forking off it are, and those from the ground stay.
    public mutating func removeStem(_ id: Int?) {
        let gone = Set(descendants(of: id) + (id.map { [$0] } ?? []))
        sections.removeAll { $0.part == .trunk && ($0.stem.map(gone.contains) ?? (id == nil)) }
        stemGraph.removeAll { gone.contains($0.id) }
    }

    /// Moves a stem and every stem growing off it by `shift` (x, z), keeping how they lean. A ring on the leaning
    /// axis is given its own centre there first.
    public mutating func moveStem(_ id: Int?, by shift: SIMD2<Double>, lean: Lean? = nil) {
        let moving = Set(descendants(of: id) + (id.map { [$0] } ?? []))
        let tilt = WireframeTree.tilt(lean)
        for index in sections.indices where sections[index].part == .trunk {
            let ring = sections[index]
            guard ring.stem.map(moving.contains) ?? (id == nil) else { continue }
            let centre = ring.offset ?? SIMD2(Double(tilt.x), Double(tilt.z)) * ring.height
            sections[index].offset = centre + shift
        }
        for index in stemGraph.indices where moving.contains(stemGraph[index].id) {
            if case .ground(let base) = stemGraph[index].origin {
                stemGraph[index].origin = .ground(base: base + shift)
            }
        }
    }

    /// A stem's radius and centre at `height`, between its rings either side of it, or nil when the stem does not
    /// reach that height or starts above it. A stem from the ground starts at the ground; one that forks starts at its
    /// lowest ring, as the fork is somewhere below it. A stem that ends in a fork goes on as its highest ring up to
    /// the fork.
    public func cross(stem id: Int?, at height: Double, lean: Lean? = nil) -> BreastHeightStem? {
        var rings = rings(onStem: id)
        if let id, case .ground = stem(id).origin, let start = start(ofStem: id) { rings.insert(start, at: 0) }
        guard let lower = rings.last(where: { $0.height <= height + 1e-6 }) else { return nil }
        guard
            let upper = rings.first(where: { $0.height >= height - 1e-6 })
                ?? forkHeight(of: id).flatMap({ height < $0 ? lower : nil })
        else { return nil }
        let tilt = WireframeTree.tilt(lean)
        func centre(_ ring: TreeSection) -> SIMD2<Double> {
            ring.offset ?? SIMD2(Double(tilt.x), Double(tilt.z)) * ring.height
        }
        let t = upper.height > lower.height ? (height - lower.height) / (upper.height - lower.height) : 0
        let uncertainty: Double? =
            switch (lower.radiusUncertainty, upper.radiusUncertainty) {
            case (let a?, let b?): max(a, b)
            case (let a?, nil), (nil, let a?): a
            case (nil, nil): nil
            }
        return BreastHeightStem(
            stem: id, radius: lower.radius + (upper.radius - lower.radius) * t,
            centre: centre(lower) + (centre(upper) - centre(lower)) * t, radiusUncertainty: uncertainty,
            isMeasured: lower.isKept || upper.isKept)
    }

    /// Every stem at breast height, as an inventory measures a tree of several: each that crosses 1.37 m, the main
    /// trunk first, then by number. A stem that forks below it is measured above the fork, as its stems.
    public func breastHeightStems(lean: Lean? = nil) -> [BreastHeightStem] {
        ([nil] + stemIDs.map(Optional.some)).compactMap { id -> BreastHeightStem? in
            // A stem that ends in a fork below breast height is measured as its stems; its rings above the fork,
            // if any are left, are not a stem.
            if endsInFork(id),
                let fork = forks(of: id).compactMap({ rings(onStem: $0).first?.height }).min(),
                fork <= DBH.standardHeight
            {
                return nil
            }
            return cross(stem: id, at: DBH.standardHeight, lean: lean)
        }
    }

    /// The diameter of a tree of several stems at breast height (`DBH.equivalent`), or of its one stem, in metres.
    public func equivalentDiameter(lean: Lean? = nil) -> Double? {
        let stems = breastHeightStems(lean: lean)
        guard !stems.isEmpty else { return nil }
        return stems.reduce(0) { $0 + $1.diameter * $1.diameter }.squareRoot()
    }

    /// The stem a stem grows from in the end: itself for one from the ground, nil for one that forks off the main
    /// trunk, or off a stem that does, at any depth.
    public func root(of id: Int?) -> Int? {
        var current = id
        var seen: Set<Int> = []
        while let stem = current, seen.insert(stem).inserted {
            switch self.stem(stem).origin {
            case .ground: return stem
            case .fork(let parent): current = parent
            }
        }
        return nil
    }

    /// Where a stem stands on the ground (from the tree's base, x and z): its base for one from the ground, the
    /// tree's base for the main trunk and the stems forking off it.
    public func base(of id: Int?) -> SIMD2<Double> {
        guard let root = root(of: id), case .ground(let base) = stem(root).origin else { return .zero }
        return base
    }

    /// Splits stems from the ground off into a tree of their own, with every stem that grows off them: the largest
    /// of them at breast height becomes its main trunk, the others stand on its ground as they do here, and it has
    /// this tree's crown. Returns this tree without them, and the new tree's profile with where it stands (from this
    /// tree's base). Nil when `roots` names no stem from the ground.
    public func splittingOff(
        _ roots: [Int], lean: Lean? = nil
    ) -> (kept: TreeProfile, off: TreeProfile, base: SIMD2<Double>)? {
        let roots = roots.filter(groundStems.contains)
        guard
            let main = roots.max(by: { a, b in
                (cross(stem: a, at: DBH.standardHeight, lean: lean)?.radius ?? rings(onStem: a).first?.radius ?? 0)
                    < (cross(stem: b, at: DBH.standardHeight, lean: lean)?.radius ?? rings(onStem: b).first?.radius ?? 0)
            })
        else { return nil }
        let newBase = base(of: main)
        let moving = Set(roots + roots.flatMap { descendants(of: $0) })
        let tilt = WireframeTree.tilt(lean)
        var sections: [TreeSection] = []
        for ring in trunk where ring.stem.map(moving.contains) ?? false {
            var moved = ring
            moved.offset = (ring.offset ?? SIMD2(Double(tilt.x), Double(tilt.z)) * ring.height) - newBase
            if moved.stem == main { moved.stem = nil }
            sections.append(moved)
        }
        // The new main trunk stands on the ground.
        if let first = sections.filter({ $0.stem == nil }).first, first.height > 0.05 {
            sections.append(
                TreeSection(part: .trunk, height: 0, radius: first.radius, source: first.source, offset: .zero))
        }
        sections += crown
        var graph: [TreeStem] = []
        for id in moving where id != main {
            switch stem(id).origin {
            case .ground(let base): graph.append(TreeStem(id: id, origin: .ground(base: base - newBase)))
            case .fork(let parent): graph.append(TreeStem(id: id, origin: .fork(parent: parent == main ? nil : parent)))
            }
        }
        var kept = self
        for root in roots { kept.removeStem(root) }
        return (kept, TreeProfile(sections: sections, stems: graph.filter { $0.origin != .fork(parent: nil) }), newBase)
    }

    /// Drops what the graph says of stems that have no rings left.
    private mutating func tidyGraph() {
        let present = Set(sections.compactMap(\.stem))
        stemGraph.removeAll { !present.contains($0.id) }
    }

    private mutating func sort() {
        sections.sort { a, b in
            if a.height != b.height { return a.height < b.height }
            if a.part != b.part { return a.part == .trunk }
            return (a.stem ?? -1) < (b.stem ?? -1)
        }
    }
}

/// A tree being fitted in AR: the shape the four sliders were last set to, and the rings it gives with the snapped
/// and confirmed ones kept. The sliders read the shape, not the rings: the rings sum to a shape too
/// (`TreeProfile.form`), but that reads the trunk at the kept breast-height ring, so a slider bound to it could not
/// move while that ring is kept.
public struct TreeFitting: Equatable, Sendable {
    /// What the shape sliders were last set to.
    public private(set) var shape: TreeForm
    /// The rings, edited one by one or redrawn from the shape.
    public var profile: TreeProfile

    public init(shape: TreeForm, profile: TreeProfile? = nil) {
        self.shape = shape.clamped
        self.profile = profile ?? TreeProfile(form: shape)
    }

    /// Sets the shape: the rings fitted or confirmed against the tree stay where they are, and the rest are drawn
    /// again from it.
    public mutating func reshape(_ form: TreeForm) {
        shape = form.clamped
        profile = profile.following(shape)
    }
}
