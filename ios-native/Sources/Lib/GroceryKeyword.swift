import Foundation

/// Shared keyword matching for grocery-item names. Both `GrocerySwaps`
/// (curated substitutions) and `IngredientVisual` (curated ingredient
/// glyphs) need the same job: given a free-text item name like
/// "2 large brown eggs" or "Unsalted Butter", find the best entry in a
/// curated keyword table. Centralized here so the two tables match items
/// identically — one normalization rule, one longest-match policy.
enum GroceryKeyword {
    /// Lowercased, punctuation-flattened form for matching. Keeps letters,
    /// digits, and spaces; collapses everything else to a space so
    /// "all-purpose flour" and "all purpose flour" match the same key.
    static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        var lastWasSpace = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// The best matching key for `itemName` among `keys`: the LONGEST key
    /// that appears as a whole word (tolerant of a trailing plural "s"/"es")
    /// in the normalized name. Longest-first so a specific key
    /// ("buttermilk", "peanut butter") wins over a shorter one it contains
    /// ("butter"). Returns nil when nothing matches — callers then fall
    /// back gracefully rather than guessing, which is what keeps the
    /// curated tables high-confidence.
    ///
    /// Store table keys in SINGULAR base form ("egg", "tomato", "onion");
    /// the matcher handles "eggs", "tomatoes", "onions" via the +s/+es
    /// suffix rule. Irregular plurals (berries, leaves) should be added to
    /// the table as their own keys.
    static func bestKey(in itemName: String, keys: [String]) -> String? {
        let name = " " + normalize(itemName) + " "
        for key in keys.sorted(by: { $0.count > $1.count }) {
            if name.contains(" \(key) ")
                || name.contains(" \(key)s ")
                || name.contains(" \(key)es ") {
                return key
            }
        }
        return nil
    }
}
