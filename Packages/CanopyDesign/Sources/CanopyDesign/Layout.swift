import CoreGraphics
import SwiftUI

/// Spacing steps, in points: 4 · 8 · 12 · 16 · 24 · 32 · 48.
public enum Spacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let s: CGFloat = 12
    public static let m: CGFloat = 16
    public static let l: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48

    public static let all: [CGFloat] = [xxs, xs, s, m, l, xl, xxl]
}

/// Corner radii, in points: 6 · 10 · 16, plus pill (use `Capsule`).
public enum Radius {
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 10
    public static let large: CGFloat = 16
}

extension View {
    /// Keeps a list or form to a readable column, centred, with the grouped background behind the margins. On an
    /// iPhone the screen is narrower than `maxWidth` and nothing changes; on an iPad a full-width row would leave a
    /// name and its distance a screen apart.
    public func readableColumn(maxWidth: CGFloat = 720) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
    }
}
