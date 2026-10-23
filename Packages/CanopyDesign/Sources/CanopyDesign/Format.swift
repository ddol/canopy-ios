import Foundation

/// Formats SI quantities for the UI. A value and its unit are joined by a narrow no-break space (U+202F),
/// so "0.42 m" never wraps between the number and the unit.
public struct QuantityFormat: Sendable {
    /// U+202F NARROW NO-BREAK SPACE.
    public static let thinSpace = "\u{202F}"

    public var locale: Locale

    public init(locale: Locale = .autoupdatingCurrent) {
        self.locale = locale
    }

    /// A length in metres, e.g. "0.42 m" or, with an uncertainty, "0.42 ± 0.01 m". Without an explicit number
    /// of decimals, the uncertainty picks it: enough for one significant digit, between 2 and 3 decimals.
    public func length(_ metres: Double, uncertainty: Double? = nil, fractionDigits: Int? = nil) -> String {
        let digits = fractionDigits ?? Self.digits(for: uncertainty, minimum: 2, maximum: 3)
        return withUnit(metres, uncertainty: uncertainty, digits: digits, unit: "m")
    }

    /// An angle in degrees, e.g. "4.5°" or "4.5 ± 0.5°". SI writes the degree sign without a space.
    public func angle(_ degrees: Double, uncertainty: Double? = nil, fractionDigits: Int = 1) -> String {
        let value = number(degrees, digits: fractionDigits)
        guard let uncertainty else { return value + "°" }
        return value + Self.thinSpace + "±" + Self.thinSpace + number(uncertainty, digits: fractionDigits) + "°"
    }

    /// A share, 0…1, as a percentage, e.g. "42 %".
    public func percent(_ fraction: Double, fractionDigits: Int = 0) -> String {
        number(fraction * 100, digits: fractionDigits) + Self.thinSpace + "%"
    }

    /// A count. Numbers of five or more digits are grouped in threes with narrow no-break spaces ("12 345").
    public func count(_ value: Int) -> String {
        let digits = String(value.magnitude)
        guard digits.count >= 5 else { return value < 0 ? "-" + digits : digits }
        var groups: [Substring] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(digits[start..<end], at: 0)
            end = start
        }
        return (value < 0 ? "-" : "") + groups.joined(separator: Self.thinSpace)
    }

    /// A duration in the SI-accepted units d, h, min and s, largest first and at most three of them, with seconds
    /// only under an hour: "1 d 2 h 3 min", "4 min 5 s". Each number is joined to its unit by a narrow no-break space.
    public func duration(seconds: UInt64) -> String {
        let units: [(UInt64, String)] = [(86_400, "d"), (3_600, "h"), (60, "min"), (1, "s")]
        var remaining = seconds
        var parts: [String] = []
        for (size, symbol) in units {
            if symbol == "s", seconds >= 3_600 { break }
            let amount = remaining / size
            remaining %= size
            if amount > 0 || (symbol == "s" && parts.isEmpty) {
                parts.append(count(Int(amount)) + Self.thinSpace + symbol)
            }
            if parts.count == 3 { break }
        }
        return parts.joined(separator: " ")
    }

    /// A short time in whole milliseconds, e.g. "42 ms" for a network round trip.
    public func milliseconds(_ seconds: Double) -> String {
        withUnit(seconds * 1_000, uncertainty: nil, digits: 0, unit: "ms")
    }

    private func withUnit(_ value: Double, uncertainty: Double?, digits: Int, unit: String) -> String {
        var text = number(value, digits: digits)
        if let uncertainty {
            let shown = Self.roundUp(uncertainty, digits: digits)
            text += Self.thinSpace + "±" + Self.thinSpace + number(shown, digits: digits)
        }
        return text + Self.thinSpace + unit
    }

    private func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
    }

    /// Rounds an uncertainty up to the shown precision so it is never understated (and never shown as zero).
    static func roundUp(_ uncertainty: Double, digits: Int) -> Double {
        let scale = pow(10, Double(digits))
        return max(1, (uncertainty * scale - 1e-9).rounded(.up)) / scale
    }

    static func digits(for uncertainty: Double?, minimum: Int, maximum: Int) -> Int {
        guard let uncertainty, uncertainty > 0 else { return minimum }
        let needed = Int((-log10(uncertainty)).rounded(.up))
        return min(maximum, max(minimum, needed))
    }
}
