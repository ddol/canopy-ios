import CanopyCapture
import CanopyDesign
import CanopyMap
import CanopyModel
import Observation
import SwiftUI
import simd

/// The tree the census actions are about: one tapped in AR, else the census tree chosen from the list or the
/// nearest.
struct FocusTree: Equatable {
    enum Source: Equatable {
        case tapped
        case chosen
        case nearest

        var label: String {
            switch self {
            case .tapped: "Tapped"
            case .chosen: "Chosen"
            case .nearest: "Nearest"
            }
        }
    }

    /// The wireframe's id: `census:<uuid>` or a Gerardus feature id.
    var id: String
    var title: String
    /// The census status; nil for one of Gerardus's trees.
    var status: CountStatus?
    /// The census tree, which Not a tree and Move act on; nil for one of Gerardus's.
    var tree: Tree?
    /// Where it is on the map, for distance and bearing by GPS until the overlay is placed.
    var geo: GeoPoint?
    var source: Source
    /// Its DBH, when measured.
    var dbh: DBH?
}

/// Follows the focus tree from the camera a few times a second: its distance and bearing, the heading, the nearby
/// trees for the compass, and whether the tree is in view. Each is its own property and set only when it changes, so
/// a view reads only what it draws: the census view watches `inView`, the card and the compass the rest.
@Observable
final class TreeTracker {
    /// Where a tree is: as drawn in AR once the overlay is placed, and on the map.
    struct Target: Equatable {
        var id: String
        /// Its trunk base in the AR world, as drawn.
        var world: SIMD3<Float>?
        var geo: GeoPoint?
        /// How tall it is drawn, for whether any of it is in view.
        var height: Float = 8
    }

    /// The focus tree from the player.
    struct Reading: Equatable {
        /// East and north of the player, metres.
        var offset: SIMD2<Double>
        var distance: Double
        /// Degrees clockwise from north; nil when the player is at it.
        var bearing: Double?
        /// From AR world points (true), else from GPS.
        var fromAR: Bool

        init(offset: SIMD2<Double>, fromAR: Bool) {
            self.offset = offset
            distance = simd_length(offset)
            bearing = Compass.bearing(of: offset)
            self.fromAR = fromAR
        }
    }

    /// A nearby tree on the compass.
    struct Mark: Equatable, Identifiable {
        var id: String
        var offset: SIMD2<Double>
    }

    @ObservationIgnored private var focus: Target?
    @ObservationIgnored private var nearby: [Target] = []
    private(set) var reading: Reading?
    private(set) var marks: [Mark] = []
    /// Where the camera looks (or the compass points), degrees clockwise from north.
    private(set) var heading: Double?
    private(set) var inView = false

    /// How often the camera is read, in seconds.
    static let interval = 0.2

    /// Follows `focus` from now on, with `nearby` for the compass. A new focus starts out of view.
    func follow(_ focus: Target?, nearby: [Target]) {
        if focus?.id != self.focus?.id {
            set(\.inView, false)
            set(\.reading, nil)
        }
        self.focus = focus
        self.nearby = nearby
    }

    /// Reads the camera, the fix and the compass, and updates what changed.
    func sample(capture: CaptureSession, location: LocationProvider) {
        let transform = capture.cameraTransform
        let camera = transform.map { SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
        if let heading = Compass.heading(camera: transform, compass: location.heading) {
            set(\.heading, heading.rounded())
        }
        let here = location.geoPoint
        func offset(_ target: Target) -> (SIMD2<Double>, fromAR: Bool)? {
            if let world = target.world, let camera { return (Compass.offset(from: camera, to: world), true) }
            if let geo = target.geo, let here { return (Compass.offset(from: here, to: geo), false) }
            return nil
        }
        func rounded(_ offset: SIMD2<Double>) -> SIMD2<Double> { (offset * 10).rounded(.toNearestOrEven) / 10 }

        var reading: Reading?
        if let focus, let found = offset(focus) {
            reading = Reading(offset: rounded(found.0), fromAR: found.fromAR)
        }
        set(\.reading, reading)
        set(
            \.marks,
            nearby.filter { $0.id != focus?.id }.compactMap { target in
                offset(target).map { Mark(id: target.id, offset: rounded($0.0)) }
            })

        var inView = false
        if let focus, let world = focus.world, let transform, let reading, reading.fromAR {
            if reading.distance < Compass.atTree {
                inView = true
            } else {
                let points = [0, Float(DBH.standardHeight), focus.height / 2, focus.height].map { height in
                    let point = world + SIMD3(0, height, 0)
                    return Compass.isInFront(point, ofCamera: transform) ? capture.project(point) : nil
                }
                inView = Compass.isInView(points, bounds: capture.viewBounds, wasInView: self.inView)
            }
        }
        set(\.inView, inView)
    }

    /// Shows a reading as a sample would, for previews.
    func show(_ reading: Reading?, marks: [Mark] = [], heading: Double?, inView: Bool = false) {
        set(\.reading, reading)
        set(\.marks, marks)
        set(\.heading, heading)
        set(\.inView, inView)
    }

    /// Sets a property only when the value differs, so its observers are not told about every sample.
    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<TreeTracker, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

/// "Turn left 40°", "Ahead", "Behind you": which way to the tree from where the player faces.
enum TurnWords {
    static func describe(bearing: Double?, heading: Double?) -> String? {
        guard let bearing, let heading else { return nil }
        let format = QuantityFormat()
        switch Compass.direction(turn: Compass.turn(to: bearing, from: heading)) {
        case .ahead: return "ahead"
        case .behind: return "behind you"
        case .left(let degrees): return "turn left " + format.angle(degrees, fractionDigits: 0)
        case .right(let degrees): return "turn right " + format.angle(degrees, fractionDigits: 0)
        }
    }
}

/// The selected tree, at the top of the census view: its status and name, how far it is and which way, and the list
/// of trees near by to choose another. Outlined in the survey orange while it is in view, as its wireframe is drawn.
struct SelectedTreeCard: View {
    let focus: FocusTree?
    let tracker: TreeTracker
    /// What to say with no tree: waiting for GPS, or none near.
    let placeholder: String
    let choices: [(Tree, Double)]
    var onChoose: (Tree) -> Void
    private let format = QuantityFormat()

    var body: some View {
        HStack(spacing: Spacing.s) {
            if let focus {
                if let status = focus.status {
                    StatusBadge(status.presentation)
                } else {
                    StatusBadge("Gerardus", systemImage: "cube", tone: .ok)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(focus.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(line(focus))
                        .font(CanopyFont.mono(.caption))
                        .foregroundStyle(Color.canopyInkMuted)
                        .lineLimit(2)
                        .accessibilityIdentifier("selected-tree-where")
                }
            } else {
                Label(placeholder, systemImage: "location")
                    .font(.subheadline)
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(choices.prefix(8), id: \.0.id) { tree, distance in
                    Button {
                        onChoose(tree)
                    } label: {
                        Label(
                            "\(tree.name), \(tree.displayStatus.presentation.label.lowercased()), "
                                + format.length(distance, fractionDigits: 0),
                            systemImage: tree.displayStatus.presentation.systemImage)
                    }
                }
            } label: {
                Label("Change tree", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.iconOnly)
            }
            .disabled(choices.isEmpty)
        }
        .padding(Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large))
        .overlay {
            if focus != nil, tracker.inView {
                RoundedRectangle(cornerRadius: Radius.large).strokeBorder(Color.canopySurvey, lineWidth: 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selected-tree-card")
    }

    /// "Nearest · 12 m NE · turn left 40° · DBH 0.42 m", from the camera once the overlay is placed, else by GPS.
    private func line(_ focus: FocusTree) -> String {
        var parts = [focus.source.label]
        if let reading = tracker.reading {
            var distance = format.length(reading.distance, fractionDigits: reading.distance < 10 ? 1 : 0)
            if let bearing = reading.bearing { distance += " " + Compass.point(of: bearing) }
            parts.append(distance)
            if tracker.inView {
                parts.append("in view")
            } else if let turn = TurnWords.describe(bearing: reading.bearing, heading: tracker.heading) {
                parts.append(turn)
            }
            if !reading.fromAR { parts.append("by GPS") }
        }
        if let dbh = focus.dbh {
            parts.append("DBH " + format.length(dbh.diameter.value, uncertainty: dbh.diameter.uncertainty))
        }
        return parts.joined(separator: " · ")
    }
}

/// A small top-down compass round the player, heading up: the selected tree as an orange marker with its distance
/// (on the rim, pointing the way, when it is further than the compass reaches), nearby trees faint, north on the rim.
/// Shown while the selected tree is not in view.
struct TreeCompassView: View {
    let tracker: TreeTracker
    let title: String
    private let format = QuantityFormat()
    static let size: CGFloat = 128
    private var radius: CGFloat { Self.size / 2 }

    var body: some View {
        let heading = tracker.heading ?? 0
        let reading = tracker.reading
        let range = Compass.range(for: reading?.distance ?? 0)
        VStack(spacing: Spacing.xxs) {
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().strokeBorder(Color.canopyLineStrong, lineWidth: 1)
                Circle()
                    .stroke(Color.canopyLine, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: radius, height: radius)
                Text("N")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StatusTone.hazard.foreground.color)
                    .offset(at(Compass.place(SIMD2(0, 1), heading: heading, range: 1).point, inset: 9))
                ForEach(tracker.marks) { mark in
                    let placed = Compass.place(mark.offset, heading: heading, range: range)
                    if !placed.clamped {
                        Circle()
                            .fill(Color.canopyInkMuted.opacity(0.45))
                            .frame(width: 6, height: 6)
                            .offset(at(placed.point, inset: 3))
                    }
                }
                Image(systemName: tracker.heading == nil ? "circle.fill" : "location.north.fill")
                    .font(.system(size: tracker.heading == nil ? 8 : 14))
                    .foregroundStyle(Color.canopyBrand)
                if let reading {
                    marker(reading, heading: heading, range: range)
                }
            }
            .frame(width: Self.size, height: Self.size)
            Text(caption(reading, range: range))
                .font(CanopyFont.mono(.caption2))
                .foregroundStyle(Color.canopyInkMuted)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(reading))
        .accessibilityIdentifier("tree-compass")
    }

    /// The selected tree: a dot inside the rim, else an arrow on it pointing the way.
    @ViewBuilder
    private func marker(_ reading: TreeTracker.Reading, heading: Double, range: Double) -> some View {
        let placed = Compass.place(reading.offset, heading: heading, range: range)
        if placed.clamped {
            Image(systemName: "location.north.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.canopySurvey)
                .rotationEffect(.radians(atan2(placed.point.x, -placed.point.y)))
                .offset(at(placed.point, inset: 9))
        } else {
            Circle()
                .fill(Color.canopySurvey)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .frame(width: 14, height: 14)
                .shadow(radius: 1)
                .offset(at(placed.point, inset: 7))
        }
    }

    /// A point on the compass (a fraction of its radius) as an offset from its centre, kept `inset` points inside the
    /// rim.
    private func at(_ point: SIMD2<Double>, inset: CGFloat) -> CGSize {
        let r = radius - inset
        return CGSize(width: CGFloat(point.x) * r, height: CGFloat(point.y) * r)
    }

    private func caption(_ reading: TreeTracker.Reading?, range: Double) -> String {
        guard let reading else { return "Finding the tree…" }
        let distance = format.length(reading.distance, fractionDigits: reading.distance < 10 ? 1 : 0)
        guard let turn = TurnWords.describe(bearing: reading.bearing, heading: tracker.heading) else {
            return distance + (tracker.heading == nil ? " · north up" : "")
        }
        return distance + " · " + turn
    }

    private func accessibilityText(_ reading: TreeTracker.Reading?) -> String {
        guard let reading else { return "Compass: finding \(title)" }
        var text = "Compass: \(title), " + format.length(reading.distance, fractionDigits: 0)
        if let turn = TurnWords.describe(bearing: reading.bearing, heading: tracker.heading) { text += ", " + turn }
        return text
    }
}

#Preview("Selected tree out of view") {
    let tracker = TreeTracker()
    tracker.show(
        TreeTracker.Reading(offset: SIMD2(9, 14), fromAR: true),
        marks: [
            TreeTracker.Mark(id: "a", offset: SIMD2(-4, 6)), TreeTracker.Mark(id: "b", offset: SIMD2(3, -5)),
            TreeTracker.Mark(id: "c", offset: SIMD2(12, 2)),
        ],
        heading: 300)
    return VStack(spacing: Spacing.s) {
        SelectedTreeCard(
            focus: FocusTree(
                id: "census:preview", title: "Steadfast Raelin Caelum", status: .detected, tree: nil, geo: nil,
                source: .nearest),
            tracker: tracker, placeholder: "", choices: [], onChoose: { _ in })
        Spacer()
        HStack {
            Spacer()
            TreeCompassView(tracker: tracker, title: "Steadfast Raelin Caelum")
        }
        TreeActionsRow(canEdit: false, onNotATree: {}, onMove: {}, onNewTree: {})
        ScanHeroButton {}
    }
    .padding(Spacing.m)
    .background(Color.gray)
}

#Preview("Selected tree in view") {
    let tracker = TreeTracker()
    tracker.show(TreeTracker.Reading(offset: SIMD2(-2, 6), fromAR: true), heading: 345, inView: true)
    return VStack(spacing: Spacing.s) {
        SelectedTreeCard(
            focus: FocusTree(
                id: "census:preview", title: "Steadfast Raelin Caelum", status: .detected, tree: nil, geo: nil,
                source: .tapped),
            tracker: tracker, placeholder: "", choices: [], onChoose: { _ in })
        Spacer()
        TreeActionsRow(canEdit: true, onNotATree: {}, onMove: {}, onNewTree: {})
        ScanHeroButton {}
        MovePanel(
            name: "Steadfast Raelin Caelum", offset: "1.8 m NE of where it was drawn", onReticle: {},
            onCancel: {}, onPlace: {})
    }
    .padding(Spacing.m)
    .background(Color.gray)
}
