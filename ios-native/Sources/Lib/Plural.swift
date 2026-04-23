import Foundation

enum Plural {
    /// Unit abbreviations that stay identical in plural form (tbsp, tsp, oz…).
    /// Kept lowercase since we compare case-insensitively.
    private static let invariants: Set<String> = [
        "tbsp", "tsp", "oz", "lb", "lbs",
        "g", "kg", "mg", "ml", "l",
        "qt", "pt", "gal", "fl oz", "c",
    ]

    /// Pluralize a cooking unit to match the quantity. "1 cup" vs "2 cups",
    /// but never "2 tbsps". Freeform quantities ("a pinch of") stay singular
    /// since we can't tell how many.
    static func unit(_ unit: String, for quantity: String?) -> String {
        let trimmed = unit.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        guard let qty = Quantity.parse(quantity), qty > 1 else { return trimmed }

        let lower = trimmed.lowercased()
        if invariants.contains(lower) { return trimmed }
        if lower.hasSuffix("s") { return trimmed }

        if lower.hasSuffix("ch") || lower.hasSuffix("sh") ||
           lower.hasSuffix("x") || lower.hasSuffix("z") {
            return trimmed + "es"
        }
        return trimmed + "s"
    }
}
