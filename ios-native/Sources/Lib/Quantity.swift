import Foundation

enum Quantity {
    /// Only fractions that exist on standard measuring spoons/cups. Intentionally
    /// omits 3/8, 5/8, 7/8 (not measurable with home equipment) and finer than 1/8.
    static let commonFractions: [(value: Double, label: String)] = [
        (1.0 / 8.0, "1/8"),
        (1.0 / 4.0, "1/4"),
        (1.0 / 3.0, "1/3"),
        (1.0 / 2.0, "1/2"),
        (2.0 / 3.0, "2/3"),
        (3.0 / 4.0, "3/4"),
    ]

    /// Parse "3", "1/4", "3 1/4", "3 & 1/4", "0.5" into a Double. Returns nil
    /// for freeform strings like "a pinch".
    static func parse(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }

        if let m = try? #/^(\d+)\s+(?:&\s+)?(\d+)\/(\d+)$/#.wholeMatch(in: trimmed) {
            guard let whole = Double(m.output.1),
                  let num = Double(m.output.2),
                  let den = Double(m.output.3),
                  den != 0 else { return nil }
            return whole + num / den
        }
        if let m = try? #/^(\d+)\/(\d+)$/#.wholeMatch(in: trimmed) {
            guard let num = Double(m.output.1),
                  let den = Double(m.output.2),
                  den != 0 else { return nil }
            return num / den
        }
        return Double(trimmed)
    }

    /// Format a Double back into a human-readable quantity, always snapping to a
    /// measurable fraction rather than falling back to decimals.
    static func format(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "" }
        if value == 0 { return "0" }
        let whole = Int(value.rounded(.down))
        let frac = value - Double(whole)

        let smallest = commonFractions[0]
        if frac < smallest.value / 2 {
            return whole > 0 ? String(whole) : smallest.label
        }
        if frac > 1 - smallest.value / 2 {
            return String(whole + 1)
        }

        var best = smallest
        var bestDiff = abs(frac - best.value)
        for entry in commonFractions {
            let diff = abs(frac - entry.value)
            if diff < bestDiff {
                bestDiff = diff
                best = entry
            }
        }
        return whole > 0 ? "\(whole) & \(best.label)" : best.label
    }

    static func scale(_ original: String?, by factor: Double) -> String? {
        guard let original, !original.isEmpty else { return original }
        if factor == 1 { return original }
        guard let parsed = parse(original) else { return original }
        return format(parsed * factor)
    }

    /// Normalize "2 1/2" or "2 & 1/2" into "2 & 1/2" for display. Leaves lone
    /// wholes, lone fractions, and freeform strings untouched.
    static func displayFormat(_ raw: String?) -> String {
        guard let raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let m = try? #/^(\d+)\s+(?:&\s+)?(\d+\/\d+)$/#.wholeMatch(in: trimmed) {
            return "\(m.output.1) & \(m.output.2)"
        }
        return trimmed
    }

    /// Split a string like "3 1/4" into its whole and fractional parts for the
    /// chip UI. Returns nil parts for freeform/decimal strings.
    struct Parsed {
        var whole: String?
        var frac: String?
        var isFreeform: Bool
    }

    static func splitForChips(_ raw: String) -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return Parsed(whole: nil, frac: nil, isFreeform: false) }
        if let m = try? #/^(\d+)\s+(?:&\s+)?(\d+\/\d+)$/#.wholeMatch(in: trimmed) {
            return Parsed(whole: String(m.output.1), frac: String(m.output.2), isFreeform: false)
        }
        if let m = try? #/^(\d+\/\d+)$/#.wholeMatch(in: trimmed) {
            return Parsed(whole: nil, frac: String(m.output.1), isFreeform: false)
        }
        if let m = try? #/^(\d+)$/#.wholeMatch(in: trimmed) {
            return Parsed(whole: String(m.output.1), frac: nil, isFreeform: false)
        }
        return Parsed(whole: nil, frac: nil, isFreeform: true)
    }

    static func combine(whole: String?, frac: String?) -> String {
        switch (whole, frac) {
        case let (w?, f?): return "\(w) & \(f)"
        case let (w?, nil): return w
        case let (nil, f?): return f
        default: return ""
        }
    }
}

enum StringCase {
    /// Uppercase the first character only, preserve the rest ("oven" → "Oven",
    /// "iOS recipe" → "IOS recipe"). Use for timer labels and other short
    /// words where we don't want to rewrite the user's casing.
    static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// Proper title case — uppercase the first letter of each word,
    /// lowercase the rest ("gluten-free" → "Gluten-Free",
    /// "COMFORT FOOD" → "Comfort Food"). Used for tag display so
    /// storage can be lowercase-normalized but the UI always reads
    /// like a proper label.
    static func titleCase(_ s: String) -> String {
        s.capitalized
    }
}
