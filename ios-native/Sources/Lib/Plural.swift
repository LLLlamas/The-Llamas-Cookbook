import Foundation

enum Plural {
    /// Unit abbreviations that stay identical in plural form (tbsp, tsp, oz…).
    /// Kept lowercase since we compare case-insensitively.
    private static let invariants: Set<String> = [
        "tbsp", "tsp", "oz", "lb", "lbs",
        "g", "kg", "mg", "ml", "l",
        "qt", "pt", "gal", "fl oz", "c",
    ]

    /// Discrete-count units that read naturally with "of" between the unit
    /// and the ingredient name: "3 pieces of chocolate", "2 cloves of garlic".
    /// Volume and weight units ("2 cups flour") don't take "of".
    /// Compared case-insensitively, includes the plural form too.
    private static let connectorUnits: Set<String> = [
        "piece", "pieces",
        "slice", "slices",
        "pinch", "pinches",
        "dash", "dashes",
        "clove", "cloves",
        "can", "cans",
        "stick", "sticks",
        "sprig", "sprigs",
        "head", "heads",
        "bunch", "bunches",
        "handful", "handfuls",
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

    /// Whether the given unit reads naturally as "N <unit> of <ingredient>"
    /// ("3 pieces of chocolate") rather than "N <unit> <ingredient>"
    /// ("2 cups flour"). Works on either the singular or plural form.
    static func needsConnector(_ unit: String) -> Bool {
        let lower = unit.trimmingCharacters(in: .whitespaces).lowercased()
        return connectorUnits.contains(lower)
    }
}
