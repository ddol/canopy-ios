import CoreText
import SwiftUI
import UIKit

/// Canopy type: DM Sans for titles, the system font for body text (with Dynamic Type), SF Mono with tabular
/// figures for numbers and ids.
public enum CanopyFont {
    /// The family name of the bundled title font.
    public static let titleFamily = "DM Sans"

    /// Registers the bundled DM Sans font with the process. Safe to call more than once.
    public static func register() {
        _ = registration
    }

    private static let registration: Bool = {
        guard let url = Bundle.module.url(forResource: "DMSans-Variable", withExtension: "ttf") else {
            assertionFailure("DM Sans is missing from the CanopyDesign bundle")
            return false
        }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !registered, let error = error?.takeRetainedValue(),
            CFErrorGetCode(error) != CTFontManagerError.alreadyRegistered.rawValue
        {
            assertionFailure("Could not register DM Sans: \(error)")
        }
        return registered
    }()

    /// A DM Sans title font that scales with Dynamic Type relative to `style`.
    public static func title(
        _ size: CGFloat, relativeTo style: Font.TextStyle = .title, weight: Font.Weight = .bold
    ) -> Font {
        register()
        return Font.custom(postScriptName(for: weight), size: size, relativeTo: style)
    }

    /// The variable font's named instance for a weight. CoreText names the instances after the font's default
    /// optical size (9 pt), so the names look odd; `TokenTests` checks they resolve.
    static func postScriptName(for weight: Font.Weight) -> String {
        let instance =
            switch weight {
            case .black, .heavy: "ExtraBold"
            case .bold: "Bold"
            case .semibold: "SemiBold"
            case .medium: "Medium"
            case .light, .thin, .ultraLight: "Light"
            default: "Regular"
            }
        return "DMSans-9ptRegular_" + instance
    }

    public static let largeTitle = title(34, relativeTo: .largeTitle)
    public static let title1 = title(28, relativeTo: .title)
    public static let title2 = title(22, relativeTo: .title2, weight: .semibold)
    public static let title3 = title(20, relativeTo: .title3, weight: .semibold)

    /// Monospaced with tabular figures, for numbers, measurements and ids.
    public static func mono(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        Font.system(style, design: .monospaced).weight(weight).monospacedDigit()
    }
}
