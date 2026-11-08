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
    public enum Source: String, Codable, Sendable {
        /// From the four-slider shape, or moved by eye.
        case eye
        /// Fitted to the scan's points at this height.
        case scan
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
    /// fitted to the scan; nil puts the ring on the leaning axis.
    public var offset: SIMD2<Double>?
    /// Standard uncertainty of the radius when it was fitted.
    public var radiusUncertainty: Double?

    public init(
        id: UUID = UUID(), part: Part, height: Double, radius: Double, source: Source = .eye,
        offset: SIMD2<Double>? = nil, radiusUncertainty: Double? = nil
    ) {
        self.id = id
        self.part = part
        self.height = height
        self.radius = radius
        self.source = source
        self.offset = offset
        self.radiusUncertainty = radiusUncertainty
    }

    /// Whether the ring stays when the shape sliders redraw the rest: a snapped or confirmed ring does.
    public var isKept: Bool { source != .eye }

    public var diameter: Double { radius * 2 }
}

/// The cross-sections of a tree from the ground up. Kept sorted by height, trunk before crown at the same height.
public struct TreeProfile: Equatable, Sendable, Codable {
    public private(set) var sections: [TreeSection]

    public static let radii = 0.015...17.5
    public static let heights = 0.0...45.0

    public init(sections: [TreeSection]) {
        self.sections = sections
        sort()
    }

    /// The rings a four-slider shape stands for: the trunk at the ground, at breast height and at the crown's base;
    /// the crown at its base, its middle and its top.
    public init(form: TreeForm) {
        let form = form.clamped
        let trunkRadius = form.trunkDiameter / 2
        var sections = [TreeSection(part: .trunk, height: 0, radius: trunkRadius)]
        if form.crownBase > DBH.standardHeight {
            sections.append(TreeSection(part: .trunk, height: DBH.standardHeight, radius: trunkRadius))
        }
        sections.append(TreeSection(part: .trunk, height: form.crownBase, radius: trunkRadius))
        let crownRadius = form.crownWidth / 2
        sections.append(TreeSection(part: .crown, height: form.crownBase, radius: crownRadius))
        if form.crownHeight > 1 {
            sections.append(
                TreeSection(part: .crown, height: form.crownBase + form.crownHeight / 2, radius: crownRadius))
        }
        sections.append(TreeSection(part: .crown, height: form.height, radius: crownRadius))
        self.init(sections: sections)
    }

    public var trunk: [TreeSection] { sections.filter { $0.part == .trunk } }
    public var crown: [TreeSection] { sections.filter { $0.part == .crown } }

    /// The four-slider shape this profile sums to: the trunk's diameter at the ring nearest breast height, the top
    /// ring's height, the crown from its lowest ring to the top and its widest ring.
    public var form: TreeForm {
        let trunk = trunk
        let crown = crown
        let height = max(sections.map(\.height).max() ?? 1, TreeForm.heights.lowerBound)
        let breast =
            trunk.min { abs($0.height - DBH.standardHeight) < abs($1.height - DBH.standardHeight) }
            ?? trunk.first
        let crownBase = crown.first?.height ?? trunk.last?.height ?? height * 2 / 3
        let crownWidth = (crown.map(\.radius).max() ?? trunk.last?.radius ?? 0.5) * 2
        return TreeForm(
            trunkDiameter: (breast?.radius ?? 0.15) * 2, height: height, crownHeight: height - crownBase,
            crownWidth: crownWidth
        ).clamped
    }

    /// The profile a changed shape gives: the rings fitted or confirmed against the tree stay where they are, and
    /// the rest are drawn again from the shape.
    public func following(_ form: TreeForm) -> TreeProfile {
        let kept = sections.filter(\.isKept)
        var fresh = TreeProfile(form: form).sections
        // A fresh ring within a few centimetres of a kept one of the same part would double it.
        fresh.removeAll { ring in kept.contains { $0.part == ring.part && abs($0.height - ring.height) < 0.05 } }
        return TreeProfile(sections: kept + fresh)
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
        }
    }

    /// A new ring of the same part above `id`: halfway to the next ring of that part, or a metre up from the top
    /// one, with the same radius. Returns the new ring's id.
    @discardableResult
    public mutating func addSection(above id: TreeSection.ID) -> TreeSection.ID? {
        guard let ring = section(id) else { return nil }
        let same = sections.filter { $0.part == ring.part }
        let next = same.first { $0.height > ring.height + 0.01 }
        let height = next.map { (ring.height + $0.height) / 2 } ?? min(ring.height + 1, Self.heights.upperBound)
        let radius = next.map { (ring.radius + $0.radius) / 2 } ?? ring.radius
        let added = TreeSection(part: ring.part, height: height, radius: radius)
        sections.append(added)
        sort()
        return added.id
    }

    /// Takes a ring out; a part keeps at least one ring.
    public mutating func removeSection(_ id: TreeSection.ID) {
        guard let ring = section(id), sections.filter({ $0.part == ring.part }).count > 1 else { return }
        sections.removeAll { $0.id == id }
    }

    private mutating func sort() {
        sections.sort { a, b in
            a.height != b.height ? a.height < b.height : (a.part == .trunk && b.part == .crown)
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
