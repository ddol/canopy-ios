import SwiftUI
import Testing
import UIKit

@testable import CanopyDesign

@Suite struct TokenTests {
    @Test func colourTokensResolveForLightAndDark() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        #expect(hex(CanopyColor.brand.uiColor.resolvedColor(with: light)) == 0x1e5d1b)
        #expect(hex(CanopyColor.brand.uiColor.resolvedColor(with: dark)) == 0x6fbf7f)
        #expect(hex(StatusTone.hazard.tint.uiColor.resolvedColor(with: dark)) == 0x3a1b18)
        for token in CanopyColor.all {
            #expect(hex(token.uiColor.resolvedColor(with: light)) == token.light, "\(token.name)")
            #expect(hex(token.uiColor.resolvedColor(with: dark)) == token.dark, "\(token.name)")
        }
    }

    @Test func okToneUsesTheBrandColour() {
        #expect(StatusTone.ok.foreground == CanopyColor.brand)
    }

    @Test func toneForegroundsAreDistinct() {
        let lights = Set(StatusTone.allCases.map(\.foreground.light))
        #expect(lights.count == StatusTone.allCases.count)
    }

    @Test func spacingAndRadiusScales() {
        #expect(Spacing.all == [4, 8, 12, 16, 24, 32, 48])
        #expect([Radius.small, Radius.medium, Radius.large] == [6, 10, 16])
    }

    @Test func dmSansIsBundledAndRegisters() throws {
        CanopyFont.register()
        let names = UIFont.fontNames(forFamilyName: CanopyFont.titleFamily)
        #expect(!names.isEmpty, "DM Sans family not registered")
        for weight in [Font.Weight.regular, .medium, .semibold, .bold] {
            let name = CanopyFont.postScriptName(for: weight)
            let font = try #require(UIFont(name: name, size: 20), "\(name)")
            #expect(font.familyName == CanopyFont.titleFamily)
        }
        #expect(Bundle.module.url(forResource: "OFL", withExtension: "txt") != nil)
    }

    private func hex(_ color: UIColor) -> UInt32 {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }
}
