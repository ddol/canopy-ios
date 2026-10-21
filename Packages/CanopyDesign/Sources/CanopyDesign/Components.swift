import SwiftUI

/// Icon + word + colour. The only way Canopy shows a status.
public struct StatusBadge: View {
    public let systemImage: String
    public let label: String
    public let tone: StatusTone

    public init(_ label: String, systemImage: String, tone: StatusTone) {
        self.label = label
        self.systemImage = systemImage
        self.tone = tone
    }

    public var body: some View {
        Label(label, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tone.foreground.color)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(tone.tint.color, in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

/// A row of labelled numbers, such as the map's "Confirmed · Estimated · Coverage".
public struct SummaryBar: View {
    public struct Item: Identifiable, Sendable {
        public let label: String
        public let value: String
        public var id: String { label }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public let items: [Item]

    public init(_ items: [Item]) {
        self.items = items
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider()
                        .frame(height: Spacing.xl)
                        .overlay(Color.canopyLine)
                }
                VStack(spacing: Spacing.xxs) {
                    Text(item.value)
                        .font(CanopyFont.mono(.title3, weight: .semibold))
                        .foregroundStyle(Color.canopyInk)
                    Text(item.label)
                        .font(.caption)
                        .foregroundStyle(Color.canopyInkMuted)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.label): \(item.value)")
            }
        }
        .padding(.vertical, Spacing.s)
        .padding(.horizontal, Spacing.xs)
        .background(Color.canopyCard, in: RoundedRectangle(cornerRadius: Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Radius.large).strokeBorder(Color.canopyLine))
    }
}

/// Button styles in the Canopy palette.
public struct CanopyButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        /// Brand green with on-brand text.
        case primary
        /// Card surface with a line border and ink text.
        case secondary
        /// Survey orange with ink text: "needs a person", and the record button.
        case survey
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .frame(minHeight: 44)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.medium))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Color.canopyLineStrong)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .canopyOnBrand
        case .secondary, .survey: .canopyInk
        }
    }

    private var background: Color {
        switch kind {
        case .primary: .canopyBrand
        case .secondary: .canopyCard
        case .survey: .canopySurvey
        }
    }
}

extension ButtonStyle where Self == CanopyButtonStyle {
    public static var canopyPrimary: CanopyButtonStyle { CanopyButtonStyle(.primary) }
    public static var canopySecondary: CanopyButtonStyle { CanopyButtonStyle(.secondary) }
    public static var canopySurvey: CanopyButtonStyle { CanopyButtonStyle(.survey) }
}

/// A card: surface-000 with a hairline border and the large radius.
public struct CardModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .padding(Spacing.m)
            .background(Color.canopyCard, in: RoundedRectangle(cornerRadius: Radius.large))
            .overlay(RoundedRectangle(cornerRadius: Radius.large).strokeBorder(Color.canopyLine))
    }
}

extension View {
    public func canopyCard() -> some View {
        modifier(CardModifier())
    }
}

#Preview("Components") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Canopy").font(CanopyFont.largeTitle)
            SummaryBar([
                .init(label: "Confirmed", value: "12"),
                .init(label: "Estimated", value: "214"),
                .init(label: "Coverage", value: "8\u{202F}%"),
            ])
            HStack {
                StatusBadge("Confirmed", systemImage: "checkmark.circle", tone: .ok)
                StatusBadge("Proposed", systemImage: "clock", tone: .proposed)
            }
            HStack {
                StatusBadge("Moved", systemImage: "arrow.left.and.right", tone: .moved)
                StatusBadge("Watch", systemImage: "eye", tone: .watch)
                StatusBadge("Hazard", systemImage: "exclamationmark.triangle", tone: .hazard)
            }
            Button("Confirm tree") {}.buttonStyle(.canopyPrimary)
            Button("Not a tree") {}.buttonStyle(.canopySecondary)
            Button("Measure trunk") {}.buttonStyle(.canopySurvey)
            Text("DBH " + QuantityFormat().length(0.42, uncertainty: 0.008)).font(CanopyFont.mono())
        }
        .padding(Spacing.m)
    }
    .background(Color.canopySurface)
}
