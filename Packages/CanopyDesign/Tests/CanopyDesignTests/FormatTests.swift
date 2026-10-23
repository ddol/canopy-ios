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

    @Test func durationsUseDHMinAndS() {
        #expect(format.duration(seconds: 0) == "0\(nnbsp)s")
        #expect(format.duration(seconds: 42) == "42\(nnbsp)s")
        #expect(format.duration(seconds: 245) == "4\(nnbsp)min 5\(nnbsp)s")
        #expect(format.duration(seconds: 3_600) == "1\(nnbsp)h")
        #expect(format.duration(seconds: 93_784) == "1\(nnbsp)d 2\(nnbsp)h 3\(nnbsp)min")
        #expect(format.duration(seconds: 90_061) == "1\(nnbsp)d 1\(nnbsp)h 1\(nnbsp)min")
    }

    @Test func roundTripsInMilliseconds() {
        #expect(format.milliseconds(0.0424) == "42\(nnbsp)ms")
        #expect(format.milliseconds(1.5) == "1500\(nnbsp)ms")
    }

    @Test func followsTheLocaleDecimalSeparator() {
        let french = QuantityFormat(locale: Locale(identifier: "fr_FR"))
        #expect(french.length(0.42) == "0,42\(nnbsp)m")
    }
}
