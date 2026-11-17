import CanopyCapture
import CanopyDesign
import CanopyModel
import SwiftUI

/// Four sliders that shape a wireframe tree: trunk diameter, height, foliage height and foliage width.
struct TreeFormSliders: View {
    @Binding var form: TreeForm
    private let format = QuantityFormat()

    var body: some View {
        VStack(spacing: Spacing.xs) {
            dimension(
                "Trunk diameter", value: $form.trunkDiameter, in: TreeForm.trunkDiameters, step: 0.01, digits: 2,
                id: "fit-trunk-diameter")
            dimension("Height", value: $form.height, in: TreeForm.heights, step: 0.25, digits: 1, id: "fit-height")
            dimension(
                "Foliage height", value: $form.crownHeight, in: 0...TreeForm.heights.upperBound, step: 0.25, digits: 1,
                id: "fit-foliage-height")
            dimension(
                "Foliage width", value: $form.crownWidth, in: TreeForm.crownWidths, step: 0.25, digits: 1,
                id: "fit-foliage-width")
        }
    }

    private func dimension(
        _ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, digits: Int, id: String
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.footnote)
                Spacer()
                Text(format.length(value.wrappedValue, fractionDigits: digits))
                    .font(CanopyFont.mono(.footnote))
                    .foregroundStyle(Color.canopyInkMuted)
            }
            Slider(value: value, in: range, step: step) {
                Text(label)
            }
            .tint(Color.canopySurvey)
            .accessibilityIdentifier(id)
        }
    }
}

/// The tree being fitted over a scanned trunk: its shape by four sliders, or ring by ring (each snapped to the scan
/// or aligned to the camera, and checked against the tree), and the buttons to move it, go back to scanning, or go
/// on to the measurement.
struct TreeFitPanel: View {
    @Binding var fitting: TreeFitting
    @Binding var selectedSection: TreeSection.ID?
    var onSnap: () -> Void
    var isAligning = false
    var alignStatus: String?
    var onAlign: () -> Void = {}
    var onMoveHere: () -> Void
    var onBack: () -> Void
    var onMeasurement: () -> Void
    /// The tree's stems at breast height, to sort in Stems.
    var stems = TreeStemsEditor.Actions()

    enum Mode: String, CaseIterable {
        case shape
        case rings
        case stems
    }

    @State private var mode = Mode.shape
    /// How each confirmed ring was set before, so taking the confirmation back restores it. Kept here, not in the
    /// rings editor, which is made afresh each time Rings is picked.
    @State private var beforeConfirming: [TreeSection.ID: TreeSection.Source] = [:]
    /// Folded down to its first rows, so the tree and the scan have the screen while the player walks round.
    @State private var folded = false

    var body: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Picker("Edit", selection: $mode) {
                    Text("Shape").tag(Mode.shape)
                    Text("Rings").tag(Mode.rings)
                    Text(stems.count > 1 ? "Stems \(stems.count)" : "Stems").tag(Mode.stems)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("fit-mode")
                Button(
                    folded ? "Show the controls" : "Fold the controls away",
                    systemImage: folded ? "chevron.up" : "chevron.down"
                ) {
                    withAnimation(.snappy) { folded.toggle() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.canopySecondary)
                .accessibilityIdentifier("fit-fold")
            }
            switch mode {
            case .shape:
                // The rings fitted or confirmed against the tree stay; the rest follow the sliders.
                if !folded {
                    TreeFormSliders(form: Binding(get: { fitting.shape }, set: { fitting.reshape($0) }))
                }
            case .rings:
                TreeSectionEditor(
                    profile: $fitting.profile, selected: $selectedSection, beforeConfirming: $beforeConfirming,
                    onSnap: onSnap, isAligning: isAligning, alignStatus: alignStatus, onAlign: onAlign,
                    folded: folded)
            case .stems:
                TreeStemsEditor(
                    profile: fitting.profile, selected: $selectedSection, actions: stems, folded: folded)
            }
            HStack(spacing: Spacing.s) {
                Button("Back", systemImage: "chevron.backward", action: onBack)
                    .buttonStyle(.canopySecondary)
                Button("Move here", systemImage: "scope", action: onMoveHere)
                    .buttonStyle(.canopySecondary)
                Button(action: onMeasurement) {
                    Label("Measurement", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.canopySurvey)
            }
            .labelStyle(.titleAndIcon)
            .font(.footnote)
        }
        .padding(Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large))
        .accessibilityIdentifier("tree-fit")
        .onChange(of: mode) {
            if mode == .rings, selectedSection == nil {
                selectedSection =
                    fitting.profile.trunk.first { abs($0.height - DBH.standardHeight) < 0.01 }?.id
                    ?? fitting.profile.sections.first?.id
            }
            if mode == .shape { selectedSection = nil }
            if mode == .stems { selectedSection = TreeStemsEditor.ring(of: nil, in: fitting.profile)?.id }
        }
    }
}

/// The rings of a profile: one chip per ring to pick it, aligning the trunk's rings a metre apart to the camera,
/// sliders for the picked ring's height and width, and snapping it to the scan, confirming it, adding a ring above it
/// or taking it out.
struct TreeSectionEditor: View {
    @Binding var profile: TreeProfile
    @Binding var selected: TreeSection.ID?
    /// How each confirmed ring was set before, so taking the confirmation back restores it. Held by the caller: this
    /// view's own state would be lost each time the panel switches to Shape and back, and a ring set by eye or from
    /// the camera, which has a centre of its own, would then come back as fitted to the scan.
    @Binding var beforeConfirming: [TreeSection.ID: TreeSection.Source]
    var onSnap: () -> Void
    var isAligning = false
    var alignStatus: String?
    var onAlign: () -> Void = {}
    /// Only the rings to pick from, and what the picked one is: the sliders and buttons are put away.
    var folded = false
    private let format = QuantityFormat()

    private var section: TreeSection? { selected.flatMap { profile.section($0) } }

    var body: some View {
        VStack(spacing: Spacing.xs) {
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.xs) {
                    ForEach(profile.sections) { ring in
                        chip(ring)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("fit-rings")
            if let section {
                Text(describe(section))
                    .font(CanopyFont.mono(.caption2))
                    .foregroundStyle(Color.canopyInkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let alignStatus {
                Text(alignStatus)
                    .font(.caption2)
                    .foregroundStyle(Color.canopyInkMuted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("rings-align-status")
            }
            if !folded, let section {
                slider(
                    "Height", value: Binding(get: { section.height }, set: { reshape(height: $0) }),
                    in: TreeProfile.heights, step: 0.05, digits: 2, id: "ring-height")
                slider(
                    section.part == .trunk ? "Diameter" : "Width",
                    value: Binding(get: { section.diameter }, set: { reshape(radius: $0 / 2) }),
                    in: section.part == .trunk ? TreeForm.trunkDiameters : TreeForm.crownWidths,
                    step: section.part == .trunk ? 0.01 : 0.25, digits: section.part == .trunk ? 2 : 1,
                    id: "ring-width")
                HStack(spacing: Spacing.xs) {
                    Button(
                        isAligning ? "Stop" : "Align",
                        systemImage: isAligning ? "stop.circle" : "camera.viewfinder", action: onAlign
                    )
                    .accessibilityIdentifier("rings-align")
                    Button("Snap", systemImage: "scope", action: onSnap)
                        .accessibilityIdentifier("ring-snap")
                    Button(
                        section.source == .confirmed ? "Confirmed" : "Looks right",
                        systemImage: section.source == .confirmed ? "checkmark.seal.fill" : "checkmark.seal"
                    ) {
                        update { ring in
                            if ring.source == .confirmed {
                                ring.source = beforeConfirming[ring.id] ?? (ring.offset == nil ? .eye : .scan)
                            } else {
                                beforeConfirming[ring.id] = ring.source
                                ring.source = .confirmed
                            }
                        }
                    }
                    .tint(section.source == .confirmed ? Color.canopyBrand : nil)
                    .accessibilityIdentifier("ring-confirm")
                    Spacer(minLength: 0)
                    Button("Add ring above", systemImage: "plus.circle") {
                        if let added = profile.addSection(above: section.id) { selected = added }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("ring-add")
                    Button("Remove ring", systemImage: "minus.circle", role: .destructive) {
                        let part = section.part
                        profile.removeSection(section.id)
                        selected = profile.sections.last { $0.part == part }?.id ?? profile.sections.first?.id
                    }
                    .labelStyle(.iconOnly)
                    .disabled(profile.sections.filter { $0.part == section.part }.count <= 1)
                    .accessibilityIdentifier("ring-remove")
                }
                .buttonStyle(.canopySecondary)
                .labelStyle(.titleAndIcon)
                .font(.caption)
            } else if section == nil {
                Text("Pick a ring.").font(.footnote).foregroundStyle(Color.canopyInkMuted)
            }
        }
    }

    private func chip(_ ring: TreeSection) -> some View {
        let picked = ring.id == selected
        return Button {
            selected = ring.id
        } label: {
            HStack(spacing: 2) {
                Image(systemName: ring.part == .trunk ? "circle" : "leaf")
                Text(format.length(ring.height, fractionDigits: ring.height < 10 ? 2 : 1))
                if ring.source == .confirmed {
                    Image(systemName: "checkmark.seal.fill")
                } else if ring.source == .scan {
                    Image(systemName: "scope")
                } else if ring.source == .camera {
                    Image(systemName: "camera.viewfinder")
                }
            }
            .font(CanopyFont.mono(.caption))
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(tint(ring).opacity(picked ? 0.3 : 0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(picked ? tint(ring) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ring.part.label) ring \(format.length(ring.height, fractionDigits: 2)) up")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func tint(_ ring: TreeSection) -> Color {
        switch ring.source {
        // As the rings are drawn in AR: the scan's lime, the camera's blue, the brand green.
        case .eye: Color.canopyInkMuted
        case .scan: Color.canopyAccent
        case .camera: StatusTone.moved.foreground.color
        case .confirmed: Color.canopyBrand
        }
    }

    private func describe(_ ring: TreeSection) -> String {
        var text = ring.part.label + " " + format.length(ring.height, fractionDigits: 2) + " up, "
        text += (ring.part == .trunk ? "⌀ " : "") + format.length(ring.diameter, fractionDigits: 2)
        if let sigma = ring.radiusUncertainty, ring.source != .eye {
            text += " ± " + format.length(2 * sigma, fractionDigits: 3)
        }
        switch ring.source {
        case .eye: text += " · by eye"
        case .scan: text += " · fitted to the scan"
        case .camera: text += " · aligned to the camera"
        case .confirmed: text += " · confirmed"
        }
        return text
    }

    /// Moves or resizes the picked ring by hand: it is then no longer the scan's fit.
    private func reshape(height: Double? = nil, radius: Double? = nil) {
        guard var ring = section else { return }
        if let height { ring.height = height }
        if let radius { ring.radius = radius }
        if ring.height != section?.height || ring.radius != section?.radius {
            ring.source = .eye
            ring.offset = nil
            ring.radiusUncertainty = nil
        }
        profile[ring.id] = ring
    }

    private func update(_ change: (inout TreeSection) -> Void) {
        guard var ring = section else { return }
        change(&ring)
        profile[ring.id] = ring
    }

    /// A ring's slider on one line: its name, the slider and its value, so the panel is short.
    private func slider(
        _ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, digits: Int, id: String
    ) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(label).font(.caption).frame(width: 58, alignment: .leading)
            Slider(value: value, in: range, step: step) {
                Text(label)
            }
            .tint(Color.canopySurvey)
            .accessibilityIdentifier(id)
            Text(format.length(value.wrappedValue, fractionDigits: digits))
                .font(CanopyFont.mono(.caption))
                .foregroundStyle(Color.canopyInkMuted)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

/// A tree's stems at breast height, to sort them: one chip per stem with its diameter (picking one picks out its ring
/// there in AR), the equivalent DBH of them all, and the buttons to take out what is not a stem, add one the scan
/// missed, split the clump into two trees with a cut through the middle of the screen, and record the stems.
struct TreeStemsEditor: View {
    /// What the census does with the stems.
    struct Actions {
        /// How many stems the tree has at breast height, the other scans' included.
        var count = 1
        /// Stems of the tree measured by other scans, kept with these.
        var others = 0
        /// The tree's equivalent DBH, as recorded or to be.
        var dbh: DBH?
        /// Whether the stems have changed since they were recorded.
        var isChanged = false
        var onRemove: (Int) -> Void = { _ in }
        var onAdd: () -> Void = {}
        var onSplit: () -> Void = {}
        var onSave: () -> Void = {}
    }

    let profile: TreeProfile
    @Binding var selected: TreeSection.ID?
    var actions: Actions
    var folded = false
    private let format = QuantityFormat()

    /// The ring a stem is picked out by: its ring nearest breast height.
    static func ring(of stem: Int?, in profile: TreeProfile) -> TreeSection? {
        profile.rings(onStem: stem).min {
            abs($0.height - DBH.standardHeight) < abs($1.height - DBH.standardHeight)
        }
    }

    private var stems: [BreastHeightStem] { profile.breastHeightStems() }
    /// The stem picked, by the ring picked out.
    private var pickedStem: Int?? { selected.flatMap { profile.section($0) }.map(\.stem) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.xs) {
                    ForEach(Array(stems.enumerated()), id: \.offset) { index, stem in
                        chip(stem, number: index + 1)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("fit-stems")
            Text(summary)
                .font(CanopyFont.mono(.caption2))
                .foregroundStyle(Color.canopyInkMuted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("stems-summary")
            if !folded {
                HStack(spacing: Spacing.xs) {
                    Button("Not a stem", systemImage: "xmark.circle", role: .destructive) {
                        if case .some(.some(let stem)) = pickedStem { actions.onRemove(stem) }
                    }
                    .disabled(!isOtherStemPicked)
                    .accessibilityIdentifier("stem-remove")
                    Button("Add", systemImage: "plus.circle", action: actions.onAdd)
                        .accessibilityIdentifier("stem-add")
                    Button("Split here", systemImage: "scissors", action: actions.onSplit)
                        .disabled(profile.groundStems.isEmpty)
                        .accessibilityIdentifier("stem-split")
                    Spacer(minLength: 0)
                    Button("Save", systemImage: "square.and.arrow.down", action: actions.onSave)
                        .disabled(!actions.isChanged)
                        .accessibilityIdentifier("stems-save")
                }
                .buttonStyle(.canopySecondary)
                .labelStyle(.titleAndIcon)
                .font(.caption)
            }
        }
    }

    /// Whether a stem other than the main trunk is picked, which can be taken out.
    private var isOtherStemPicked: Bool {
        if case .some(.some) = pickedStem { true } else { false }
    }

    private var summary: String {
        var text =
            stems.count == 1
            ? "One stem at breast height."
            : "\(stems.count) stems at breast height"
        if actions.others > 0 {
            text += (stems.count == 1 ? " " : ", ") + "and \(actions.others) from another scan"
        }
        if let dbh = actions.dbh, actions.count > 1 {
            text +=
                (text.hasSuffix(".") ? " " : ": ") + "equivalent DBH "
                + format.length(dbh.diameter.value, uncertainty: dbh.diameter.uncertainty)
        }
        if !text.hasSuffix(".") { text += "." }
        if !folded {
            text += " Aim between stems for Split here, at a missed one for Add."
        }
        return text
    }

    private func chip(_ stem: BreastHeightStem, number: Int) -> some View {
        let picked = pickedStem == .some(stem.stem)
        let tint = stem.isMeasured ? Color.canopyAccent : Color.canopyInkMuted
        return Button {
            selected = Self.ring(of: stem.stem, in: profile)?.id
        } label: {
            HStack(spacing: 2) {
                Image(systemName: stem.stem == nil ? "circle.circle" : "circle")
                Text("⌀ " + format.length(stem.diameter, fractionDigits: 2))
            }
            .font(CanopyFont.mono(.caption))
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(tint.opacity(picked ? 0.3 : 0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(picked ? tint : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            (stem.stem == nil ? "Main stem" : "Stem \(number)") + ", "
                + format.length(stem.diameter, fractionDigits: 2) + " across"
        )
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// A tree picked in the AR view: what is known about it, the sliders to reshape its wireframe, and what to do next:
/// Not a tree and Move for a census tree in view, and Scan trunk. Its name, status, distance and bearing are on the
/// selected tree's card at the top.
struct SelectedTreePanel: View {
    let selection: ARTreeSelection
    @Binding var form: TreeForm
    /// Whether the player has moved a slider on this tree.
    let isAdjusted: Bool
    /// Whether Not a tree and Move apply: a census tree, in view.
    var canEdit = false
    var onReset: () -> Void
    var onScan: () -> Void
    var onDone: () -> Void
    var onNotATree: () -> Void = {}
    var onMove: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Text(selection.detail)
                    .font(CanopyFont.mono(.caption))
                    .foregroundStyle(Color.canopyInkMuted)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Reset", systemImage: "arrow.uturn.backward", action: onReset)
                    .labelStyle(.iconOnly)
                    .disabled(!isAdjusted)
                Button("Done", systemImage: "checkmark", action: onDone)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.canopySecondary)
            .font(.footnote)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("selected-tree")
            TreeFormSliders(form: $form)
            if canEdit {
                TreeActionsRow(canEdit: true, onNotATree: onNotATree, onMove: onMove)
            }
            ScanHeroButton(action: onScan)
        }
        .padding(Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large))
    }
}

/// The selected census tree's actions once it is in view: Not a tree takes it out, Move puts it on its true spot.
/// New tree here sits at the end, small.
struct TreeActionsRow: View {
    var canEdit: Bool
    var onNotATree: () -> Void
    var onMove: () -> Void
    var onNewTree: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.s) {
            if canEdit {
                Button(action: onNotATree) {
                    Label {
                        Text("Not a tree")
                    } icon: {
                        Image(systemName: "xmark").foregroundStyle(StatusTone.hazard.foreground.color)
                    }
                }
                .accessibilityIdentifier("tree-not-a-tree")
                Button("Move", systemImage: "arrow.up.and.down.and.arrow.left.and.right", action: onMove)
                    .accessibilityIdentifier("tree-move")
            }
            Spacer(minLength: 0)
            if let onNewTree {
                if canEdit {
                    Button("New tree here", systemImage: "plus.circle", action: onNewTree)
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("new-tree")
                } else {
                    Button("New tree here", systemImage: "plus.circle", action: onNewTree)
                        .accessibilityIdentifier("new-tree")
                }
            }
        }
        .buttonStyle(.canopySecondary)
        .labelStyle(.titleAndIcon)
        .font(.footnote)
    }
}

/// Scan trunk: the census view's main button.
struct ScanHeroButton: View {
    /// The tree the scan will measure, when it was chosen for it, such as from the map.
    var treeName: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(treeName.map { "Scan \($0)" } ?? "Scan trunk", systemImage: "record.circle")
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.canopySurvey)
        .accessibilityIdentifier("scan-trunk")
    }
}

/// Moving the selected tree to its true spot: its wireframe stands where the reticle points or a finger drags it,
/// with a line back to where it was drawn, until Place here records the move.
struct MovePanel: View {
    let name: String
    /// How far and which way from where it was drawn, such as "1.8 m NE of where it was".
    let offset: String?
    var onReticle: () -> Void
    var onCancel: () -> Void
    var onPlace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Move " + name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(
                "The orange tree with marching ants is where it goes; the grey ring is where it is now. Point at the "
                    + "foot of its trunk and tap To reticle, or drag it, then Place here."
            )
            .font(.footnote)
            .foregroundStyle(Color.canopyInkMuted)
            if let offset {
                Text(offset)
                    .font(CanopyFont.mono(.caption))
                    .accessibilityIdentifier("move-offset")
            }
            HStack(spacing: Spacing.s) {
                Button("Cancel", systemImage: "xmark", action: onCancel)
                    .buttonStyle(.canopySecondary)
                Button("To reticle", systemImage: "scope", action: onReticle)
                    .buttonStyle(.canopySecondary)
                    .accessibilityIdentifier("move-to-reticle")
                Button(action: onPlace) {
                    Label("Place here", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.canopyPrimary)
                .accessibilityIdentifier("move-place")
            }
            .labelStyle(.titleAndIcon)
            .font(.footnote)
        }
        .padding(Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("move-panel")
    }
}

/// What the AR view knows about a picked tree, for its panel.
struct ARTreeSelection: Equatable {
    /// The wireframe item's id: `census:<uuid>` or a Gerardus feature id.
    var id: String
    var title: String
    var detail: String
    /// The census status, for a census tree; nil for one of Gerardus's.
    var status: CountStatus?
    /// The shape the server or the census gives it, before any adjustment.
    var baseForm: TreeForm
    /// Where it is on the map, for its distance and bearing by GPS.
    var geo: GeoPoint?

    static let censusPrefix = "census:"

    var censusID: UUID? {
        id.hasPrefix(Self.censusPrefix) ? UUID(uuidString: String(id.dropFirst(Self.censusPrefix.count))) : nil
    }
}
