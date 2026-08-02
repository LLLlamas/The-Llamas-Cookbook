import Foundation

/// Shared normalization for grocery-item names. `AddToGroceryListSheet`
/// (recipe→list dedup) needs one normalization rule for free-text item
/// names like "2 large brown eggs" or "Unsalted Butter". (Substitution +
/// aisle data live in `GroceryKnowledge`, which has its own matcher.)
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
}
