import Foundation
import Testing

@testable import CanopyDesign

@Suite struct FormatTests {
    let format = QuantityFormat(locale: Locale(identifier: "en_US"))
    let nnbsp = "\u{202F}"

    @Test func lengthUsesANarrowNoBreakSpaceBeforeTheUnit() {
        #expect(format.length(0.42) == "0.42\(nnbsp)m")
        #expect(format.length(12.3456, fractionDigits: 1) == "12.3\(nnbsp)m")
    }

    @Test func uncertaintyPicksTheDecimalsAndIsNeverUnderstated() {
        #expect(format.length(0.4213, uncertainty: 0.012) == "0.42\(nnbsp)±\(nnbsp)0.02\(nnbsp)m")
        #expect(format.length(0.4213, uncertainty: 0.01) == "0.42\(nnbsp)±\(nnbsp)0.01\(nnbsp)m")
        #expect(format.length(0.4213, uncertainty: 0.004) == "0.421\(nnbsp)±\(nnbsp)0.004\(nnbsp)m")
        #expect(format.length(0.4213, uncertainty: 0.0001) == "0.421\(nnbsp)±\(nnbsp)0.001\(nnbsp)m")
        #expect(format.length(0.4213, uncertainty: 0.0001, fractionDigits: 2) == "0.42\(nnbsp)±\(nnbsp)0.01\(nnbsp)m")
    }

    @Test func anglesHaveNoSpaceBeforeTheDegreeSign() {
        #expect(format.angle(4.52) == "4.5°")
        #expect(format.angle(4.52, uncertainty: 0.5) == "4.5\(nnbsp)±\(nnbsp)0.5°")
    }

    @Test func percentAndCounts() {
        #expect(format.percent(0.083) == "8\(nnbsp)%")
        #expect(format.count(214) == "214")
        #expect(format.count(1234) == "1234")
        #expect(format.count(12345) == "12\(nnbsp)345")
        #expect(format.count(1_234_567) == "1\(nnbsp)234\(nnbsp)567")
        #expect(format.count(-12345) == "-12\(nnbsp)345")
    }

    @Test func followsTheLocaleDecimalSeparator() {
        let french = QuantityFormat(locale: Locale(identifier: "fr_FR"))
        #expect(french.length(0.42) == "0,42\(nnbsp)m")
    }
}
