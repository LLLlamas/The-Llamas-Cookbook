import Foundation

/// Centralizes the "render an ingredient for the user" pipeline shared by
/// Detail view, Cook mode, and text export. Each caller wants the same
/// underlying pieces (formatted quantity, pluralized unit, `of`-connector
/// rule, name) but composes them differently — so we compute them once
/// and expose both the parts and a space-joined full-line form.
extension Ingredient {
    struct Display {
        /// Display-ready quantity — "2 & 1/2", "1/4", "" for freeform/empty.
        let quantity: String
        /// Pluralized unit — "cups", "tbsp", "". Empty when the ingredient
        /// has no unit.
        let unit: String
        /// Whether "of" belongs between the unit and the name
        /// ("3 cloves of garlic" vs "2 cups flour").
        let takesOf: Bool
        /// Ingredient name, unchanged.
        let name: String

        /// Quantity + unit joined — "2 & 1/2 cups" or "" when no measure.
        var measure: String {
            [quantity, unit].filter { !$0.isEmpty }.joined(separator: " ")
        }

        /// Space-joined full line — "2 & 1/2 cups flour", "3 cloves of garlic",
        /// or bare "salt" when the ingredient has no measure.
        var fullLine: String {
            let connector = (takesOf && !unit.isEmpty) ? "of" : ""
            return [quantity, unit, connector, name]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    /// Build a `Display` for this ingredient. `scaledBy` multiplies the
    /// stored quantity before formatting — used by Cook Mode's servings
    /// scaler. Default 1 leaves the quantity untouched for Detail/Export.
    ///
    /// Name is lowercased on display — standard recipe-writing convention
    /// ("2 cups flour", not "2 cups Flour") and keeps the detail row's
    /// right-hand side visually calm regardless of how the user typed it.
    func display(scaledBy factor: Double = 1) -> Display {
        let scaled = Quantity.scale(quantity, by: factor) ?? quantity ?? ""
        let qty = Quantity.displayFormat(scaled)
        let pluralized = Plural.unit(unit ?? "", for: scaled)
        let takesOf = !pluralized.isEmpty && Plural.needsConnector(pluralized)
        return Display(quantity: qty, unit: pluralized, takesOf: takesOf, name: name.lowercased())
    }
}
