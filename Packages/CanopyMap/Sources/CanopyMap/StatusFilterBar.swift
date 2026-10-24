import CanopyDesign
import CanopyModel
import SwiftUI

/// A row of chips, one per tree status, that show or hide those trees on the map. Each chip is the status's icon, word
/// and colour with its count; a hidden status keeps its word but loses its colour.
public struct StatusFilterBar: View {
    @Binding private var shown: Set<CountStatus>
    private let counts: [CountStatus: Int]
    private let format = QuantityFormat()

    public init(shown: Binding<Set<CountStatus>>, counts: [CountStatus: Int]) {
        self._shown = shown
        self.counts = counts
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                ForEach(MapLayers.Visibility.treeStatuses, id: \.self) { status in
                    chip(status)
                }
            }
            .padding(.horizontal, Spacing.m)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status-filter")
    }

    private func chip(_ status: CountStatus) -> some View {
        let presentation = status.presentation
        let isShown = shown.contains(status)
        return Button {
            if isShown { shown.remove(status) } else { shown.insert(status) }
        } label: {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: isShown ? presentation.systemImage : "eye.slash")
                Text(presentation.label)
                Text(format.count(counts[status] ?? 0))
                    .font(CanopyFont.mono(.caption))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isShown ? presentation.tone.foreground.color : Color.canopyInkMuted)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs + 2)
            .background(isShown ? presentation.tone.tint.color : Color.canopyCard, in: Capsule())
            .overlay(Capsule().strokeBorder(isShown ? Color.clear : Color.canopyLineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(presentation.label) trees, \(counts[status] ?? 0)")
        .accessibilityValue(isShown ? "Shown" : "Hidden")
        .accessibilityAddTraits(isShown ? .isSelected : [])
        .accessibilityIdentifier("status-filter-\(status.rawValue)")
    }
}
