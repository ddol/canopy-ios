import SwiftUI
import UIKit

/// A colour token with a light and a dark value, as 0xRRGGBB.
public struct ColorToken: Hashable, Sendable {
    public let name: String
    public let light: UInt32
    public let dark: UInt32

    public init(_ name: String, light: UInt32, dark: UInt32) {
        self.name = name
        self.light = light
        self.dark = dark
    }

    /// A dynamic colour that follows the interface style.
    public var uiColor: UIColor {
        let light = UIColor(rgb: self.light)
        let dark = UIColor(rgb: self.dark)
        return UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
    }

    public var color: Color { Color(uiColor: uiColor) }
}

/// The Canopy colour tokens. See docs/DESIGN-TOKENS.md.
public enum CanopyColor {
    public static let surface100 = ColorToken("surface-100", light: 0xf4f6f1, dark: 0x0f1512)
    public static let surface000 = ColorToken("surface-000", light: 0xffffff, dark: 0x18211c)
    public static let surface200 = ColorToken("surface-200", light: 0xe6ebe2, dark: 0x222d27)
    public static let ink = ColorToken("ink", light: 0x14201a, dark: 0xeef3ec)
    public static let inkMuted = ColorToken("ink-muted", light: 0x4d5a51, dark: 0xa9b6ad)
    public static let line = ColorToken("line", light: 0xd3dacd, dark: 0x2a352f)
    public static let lineStrong = ColorToken("line-strong", light: 0x7d8a76, dark: 0x6b7a70)
    /// The brand green. Text on it uses `onBrand`.
    public static let brand = ColorToken("brand", light: 0x1e5d1b, dark: 0x6fbf7f)
    public static let onBrand = ColorToken("on-brand", light: 0xffffff, dark: 0x0f1512)
    /// Lime accent. Only ever with `ink` text on it.
    public static let canopy = ColorToken("canopy", light: 0x9bd14b, dark: 0xb6e36a)
    /// Orange for "needs a person" and the record button. Text on it uses `ink`.
    public static let survey = ColorToken("survey", light: 0xf08a24, dark: 0xff9d4d)

    public static let all: [ColorToken] = [
        surface100, surface000, surface200, ink, inkMuted, line, lineStrong, brand, onBrand, canopy, survey,
    ]
}

/// The status tones. A tone is always shown with an icon and a word, never as colour alone.
public enum StatusTone: String, CaseIterable, Sendable {
    case ok
    case proposed
    case moved
    case watch
    case hazard

    /// Foreground: icon, text and strokes.
    public var foreground: ColorToken {
        switch self {
        case .ok: CanopyColor.brand
        case .proposed: ColorToken("status-proposed", light: 0xa34a00, dark: 0xff9d4d)
        case .moved: ColorToken("status-moved", light: 0x1f5fbf, dark: 0x7fb2ff)
        case .watch: ColorToken("status-watch", light: 0x7d5800, dark: 0xe6b84a)
        case .hazard: ColorToken("status-hazard", light: 0xb3261e, dark: 0xff8a7f)
        }
    }

    /// Background tint behind a badge.
    public var tint: ColorToken {
        switch self {
        case .ok: ColorToken("status-ok-tint", light: 0xe1efe3, dark: 0x1a3322)
        case .proposed: ColorToken("status-proposed-tint", light: 0xfde9d6, dark: 0x3a2512)
        case .moved: ColorToken("status-moved-tint", light: 0xe2ecfb, dark: 0x172a45)
        case .watch: ColorToken("status-watch-tint", light: 0xf7eccc, dark: 0x33290f)
        case .hazard: ColorToken("status-hazard-tint", light: 0xfbe4e1, dark: 0x3a1b18)
        }
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }
}

extension Color {
    public static let canopySurface = CanopyColor.surface100.color
    public static let canopyCard = CanopyColor.surface000.color
    public static let canopySunken = CanopyColor.surface200.color
    public static let canopyInk = CanopyColor.ink.color
    public static let canopyInkMuted = CanopyColor.inkMuted.color
    public static let canopyLine = CanopyColor.line.color
    public static let canopyLineStrong = CanopyColor.lineStrong.color
    public static let canopyBrand = CanopyColor.brand.color
    public static let canopyOnBrand = CanopyColor.onBrand.color
    public static let canopyAccent = CanopyColor.canopy.color
    public static let canopySurvey = CanopyColor.survey.color
}
