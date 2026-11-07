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

/// The sliders for the tree being fitted over a scanned trunk, and the buttons to move it, go back to scanning, or
/// go on to the measurement.
struct TreeFitPanel: View {
    @Binding var form: TreeForm
    var onMoveHere: () -> Void
    var onBack: () -> Void
    var onMeasurement: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xs) {
            TreeFormSliders(form: $form)
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
