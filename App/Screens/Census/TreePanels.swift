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

    enum Mode: String, CaseIterable {
        case shape
        case rings
    }

    @State private var mode = Mode.shape
    /// How each confirmed ring was set before, so taking the confirmation back restores it. Kept here, not in the
    /// rings editor, which is made afresh each time Rings is picked.
    @State private var beforeConfirming: [TreeSection.ID: TreeSection.Source] = [:]

    var body: some View {
        VStack(spacing: Spacing.xs) {
            Picker("Edit", selection: $mode) {
                Text("Shape").tag(Mode.shape)
                Text("Rings").tag(Mode.rings)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("fit-mode")
            switch mode {
            case .shape:
                // The rings fitted or confirmed against the tree stay; the rest follow the sliders.
                TreeFormSliders(form: Binding(get: { fitting.shape }, set: { fitting.reshape($0) }))
            case .rings:
                TreeSectionEditor(
                    profile: $fitting.profile, selected: $selectedSection, beforeConfirming: $beforeConfirming,
                    onSnap: onSnap, isAligning: isAligning, alignStatus: alignStatus, onAlign: onAlign)
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
            HStack(spacing: Spacing.s) {
                Button(
                    isAligning ? "Stop aligning" : "Align steps",
                    systemImage: isAligning ? "stop.circle" : "camera.viewfinder", action: onAlign
                )
                .buttonStyle(.canopySecondary)
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("rings-align")
                Text(alignStatus ?? "Rings a metre apart up the trunk, set from the camera above the scan.")
                    .font(.caption2)
                    .foregroundStyle(Color.canopyInkMuted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("rings-align-status")
            }
            .font(.footnote)
            if let section {
                slider(
                    "Height", value: Binding(get: { section.height }, set: { reshape(height: $0) }),
                    in: TreeProfile.heights, step: 0.05, digits: 2, id: "ring-height")
                slider(
                    section.part == .trunk ? "Trunk diameter" : "Foliage width",
                    value: Binding(get: { section.diameter }, set: { reshape(radius: $0 / 2) }),
                    in: section.part == .trunk ? TreeForm.trunkDiameters : TreeForm.crownWidths,
                    step: section.part == .trunk ? 0.01 : 0.25, digits: section.part == .trunk ? 2 : 1,
                    id: "ring-width")
                HStack(spacing: Spacing.s) {
                    Button("Snap to scan", systemImage: "scope", action: onSnap)
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
                .font(.footnote)
                Text(describe(section))
                    .font(CanopyFont.mono(.caption2))
                    .foregroundStyle(Color.canopyInkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
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

    private func slider(
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

/// A tree picked in the AR view: what is known about it, the sliders to reshape its wireframe, and what to do next.
struct SelectedTreePanel: View {
    let selection: ARTreeSelection
    @Binding var form: TreeForm
    /// Whether the player has moved a slider on this tree.
    let isAdjusted: Bool
    var onReset: () -> Void
    var onScan: () -> Void
    var onDone: () -> Void
    private let format = QuantityFormat()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                if let status = selection.status {
                    StatusBadge(status.presentation)
                } else {
                    StatusBadge("Gerardus", systemImage: "cube", tone: .ok)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(selection.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(selection.detail).font(CanopyFont.mono(.caption)).foregroundStyle(Color.canopyInkMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("selected-tree")
            TreeFormSliders(form: $form)
            HStack(spacing: Spacing.s) {
                Button("Done", systemImage: "xmark", action: onDone)
                    .buttonStyle(.canopySecondary)
                Button("Reset", systemImage: "arrow.uturn.backward", action: onReset)
                    .buttonStyle(.canopySecondary)
                    .disabled(!isAdjusted)
                Button(action: onScan) {
                    Label("Scan trunk", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.canopySurvey)
            }
            .labelStyle(.titleAndIcon)
            .font(.footnote)
        }
        .padding(Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large))
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

    static let censusPrefix = "census:"

    var censusID: UUID? {
        id.hasPrefix(Self.censusPrefix) ? UUID(uuidString: String(id.dropFirst(Self.censusPrefix.count))) : nil
    }
}
