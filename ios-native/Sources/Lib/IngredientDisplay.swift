import Foundation

/// The "render a measured thing for the user" pipeline — formatted
/// quantity, pluralized unit, `of`-connector rule, name — shared by recipe
/// ingredients (Detail, Cook mode, export) and grocery-list items. Computed
/// once here so every surface composes from the same parts instead of
/// re-inlining the `Quantity`/`Plural` calls.
struct MeasureDisplay {
    /// Display-ready quantity — "2 & 1/2", "1/4", "" for freeform/empty.
    let quantity: String
    /// Pluralized unit — "cups", "tbsp", "". Empty when there's no unit.
    let unit: String
    /// Whether "of" belongs between the unit and the name
    /// ("3 cloves of garlic" vs "2 cups flour").
    let takesOf: Bool
    /// Name, lowercased on display (standard recipe-writing convention).
    let name: String

    /// Quantity + unit joined — "2 & 1/2 cups" or "" when no measure.
    var measure: String {
        [quantity, unit].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Space-joined full line — "2 & 1/2 cups flour", "3 cloves of garlic",
    /// or bare "salt" when there's no measure.
    var fullLine: String {
        let connector = (takesOf && !unit.isEmpty) ? "of" : ""
        return [quantity, unit, connector, name]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Build a `MeasureDisplay` from raw fields. `scaledBy` multiplies the
    /// quantity before formatting (Cook Mode's servings scaler); default 1
    /// leaves it untouched. Name is lowercased so the right-hand side reads
    /// calmly regardless of how the user typed it.
    static func make(
        quantity: String?,
        unit: String?,
        name: String,
        scaledBy factor: Double = 1
    ) -> MeasureDisplay {
        let scaled = Quantity.scale(quantity, by: factor) ?? quantity ?? ""
        let qty = Quantity.displayFormat(scaled)
        let pluralized = Plural.unit(unit ?? "", for: scaled)
        let takesOf = !pluralized.isEmpty && Plural.needsConnector(pluralized)
        return MeasureDisplay(quantity: qty, unit: pluralized, takesOf: takesOf, name: name.lowercased())
    }
}

extension Ingredient {
    /// Kept as `Ingredient.Display` for the existing Detail/Cook/Export call
    /// sites; the implementation now lives in the shared `MeasureDisplay`.
    typealias Display = MeasureDisplay

    /// Build a `Display` for this ingredient. See `MeasureDisplay.make`.
    func display(scaledBy factor: Double = 1) -> Display {
        MeasureDisplay.make(quantity: quantity, unit: unit, name: name, scaledBy: factor)
    }
}

extension GroceryItem {
    /// Render this grocery item's measure with the same pipeline recipe
    /// ingredients use — so "2 & 1/2 cups of flour" formats identically on
    /// the list, the share page, and the recipe it came from.
    func display(scaledBy factor: Double = 1) -> MeasureDisplay {
        MeasureDisplay.make(quantity: quantity, unit: unit, name: name, scaledBy: factor)
    }
}
