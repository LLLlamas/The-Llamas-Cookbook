import Foundation

/// Pure math + reference table for sourdough starter feedings.
///
/// A "ratio" of 1:N:N means 1 part starter, N parts water, N parts flour
/// by weight. Given a target total mass `total` (grams) of active starter:
///
///     starter = total / (2N + 1)
///     water   = total * N / (2N + 1)
///     flour   = total * N / (2N + 1)
///
/// Approximate peak times are keyed by ratio and assume a warm room
/// (~75–80°F) plus a healthy active starter — they're a guide, not
/// a guarantee.
enum SourdoughCalculator {
    struct Row: Identifiable, Hashable {
        let ratio: Int          // N in 1:N:N
        let starter: Double     // grams
        let water: Double       // grams
        let flour: Double       // grams
        let timeRange: String   // "4–6 hours"

        var id: Int { ratio }
        var label: String { "1:\(ratio):\(ratio)" }
        /// Compact form for tight table columns ("4–6h" / "8.5–11h").
        var compactTimeRange: String {
            timeRange.replacingOccurrences(of: " hours", with: "h")
        }
    }

    /// Standard ratios shown on the chart — 1:1:1 through 1:10:10.
    static let ratios: [Int] = Array(1...10)

    /// Approximate peak times by N. Hand-keyed from Lorenzo's reference
    /// chart (the values are ratio-driven, not total-driven, so they
    /// don't change with the input mass).
    private static let timesByRatio: [Int: String] = [
        1:  "4–6 hours",
        2:  "5–7 hours",
        3:  "6–8 hours",
        4:  "7–9 hours",
        5:  "8–10 hours",
        6:  "8.5–11 hours",
        7:  "9–12 hours",
        8:  "10–13 hours",
        9:  "10–14 hours",
        10: "11–15 hours",
    ]

    /// Compute the full feeding table for a target total mass in grams.
    static func table(forTotal total: Double) -> [Row] {
        ratios.map { row(forTotal: total, ratio: $0) }
    }

    /// One row for a given ratio + total.
    static func row(forTotal total: Double, ratio: Int) -> Row {
        let denom = Double(2 * ratio + 1)
        let starter = total / denom
        let waterFlour = total * Double(ratio) / denom
        return Row(
            ratio: ratio,
            starter: starter,
            water: waterFlour,
            flour: waterFlour,
            timeRange: timesByRatio[ratio] ?? ""
        )
    }

    /// Numeric portion suitable for stuffing into `Ingredient.quantity`.
    /// Whole numbers above 100 drop the decimal (no one weighs to 0.1g
    /// at that scale); under 100 keeps a single decimal place. Trailing
    /// `.0` is stripped so "20.0" comes back as "20" — matches the chart.
    static func gramsValue(_ value: Double) -> String {
        if value >= 100 {
            return "\(Int(value.rounded()))"
        }
        let rounded = (value * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }

    /// Display form with the unit suffix — "33.3 g", "20 g", "120 g".
    static func formatGrams(_ value: Double) -> String {
        "\(gramsValue(value)) g"
    }
}
