import Foundation

/// Best-effort parser for pasted recipe text. Handles what users typically
/// keep in Notes: title on top, labeled sections ("Ingredients", "Steps"),
/// bulleted ingredient lines, numbered step lines. Missing fields default
/// to empty — the editor is shown for manual fixup before saving.
enum RecipeImporter {
    static func parse(_ text: String) -> DraftRecipe {
        var draft = DraftRecipe()
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var section: Section = .header
        var titleSet = false
        var summaryLines: [String] = []
        var notesLines: [String] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()

            if !titleSet {
                // "Title" / "Title:" alone on a line is just the section
                // identifier — the actual value is the next non-empty line.
                if lower == "title" || lower == "title:" { continue }
                // "Title: Cookie", "Title - Cookie", "Title Cookie" → strip
                // the identifier and keep just the value.
                if let match = try? #/^[Tt]itle(?:\s*[:\-]\s*|\s+)(.+)$/#.wholeMatch(in: line) {
                    draft.title = String(match.output.1).trimmingCharacters(in: .whitespaces)
                } else {
                    draft.title = line
                }
                titleSet = true
                continue
            }

            if sectionMatches(lower, ["ingredients"]) { section = .ingredients; continue }
            if sectionMatches(lower, ["steps", "instructions", "directions", "method"]) { section = .steps; continue }
            if sectionMatches(lower, ["notes"]) { section = .notes; continue }

            if let s = extractNumber(after: #"(?i)^serves?\s*:?\s*"#, in: line) {
                draft.servings = s
                continue
            }
            if let s = extractNumber(after: #"(?i)^cook(?:\s+time)?\s*:?\s*"#, in: line) {
                draft.cookTimeMinutes = s
                continue
            }
            if lower.hasPrefix("source:") {
                draft.sourceUrl = String(line.dropFirst("source:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            switch section {
            case .header:
                summaryLines.append(line)
            case .ingredients:
                if let ing = parseIngredient(line) { draft.ingredients.append(ing) }
            case .steps:
                if let step = parseStep(line) { draft.steps.append(step) }
            case .notes:
                notesLines.append(line)
            }
        }

        if !summaryLines.isEmpty {
            draft.summary = summaryLines.joined(separator: " ")
        }
        if !notesLines.isEmpty {
            draft.notes = notesLines.joined(separator: "\n")
        }
        return draft
    }

    private enum Section { case header, ingredients, steps, notes }

    private static func sectionMatches(_ line: String, _ names: [String]) -> Bool {
        let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        return names.contains(stripped)
    }

    private static func extractNumber(after pattern: String, in line: String) -> String? {
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        let remainder = line[range.upperBound...]
        let digits = remainder.prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    private static func parseIngredient(_ line: String) -> DraftIngredient? {
        var s = stripLeadingBullet(line)
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // Guard: lines that are only bullets, dashes, or punctuation
        // ("•", "- - -", "···") shouldn't become a named ingredient.
        // Require at least one letter or digit after bullet stripping.
        guard s.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }

        // Normalize spacing around "&" so "1 &1/2 cup flour" and variants
        // tokenize the same.
        s = s.replacingOccurrences(of: "&", with: " & ")
        // Repair broken fractions — "1 /3" and "1/ 3" both become "1/3".
        s = s.replacingOccurrences(of: #"(\d)\s+/(\d)"#, with: "$1/$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\d)/\s+(\d)"#, with: "$1/$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let tokens = s.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }

        var qtyTokens: [String] = []
        var idx = 0
        while idx < tokens.count, isQuantityToken(tokens[idx]) {
            qtyTokens.append(tokens[idx])
            idx += 1
        }

        var unit = ""
        if idx < tokens.count {
            let candidate = tokens[idx].lowercased().trimmingCharacters(in: .punctuationCharacters)
            if knownUnits.contains(candidate) {
                // Canonicalize plural → singular so display pluralization
                // via `Plural.unit(_, for:)` stays internally consistent.
                unit = unitSingularMap[candidate] ?? candidate
                idx += 1
            }
        }

        // "3 cups of flour" / "1 teaspoon of salt" — the connector "of"
        // isn't part of the ingredient name. Skip it so names don't get
        // polluted with stray prepositions.
        if idx < tokens.count, tokens[idx].lowercased() == "of" {
            idx += 1
        }

        var nameTokens = Array(tokens[idx...])

        // If nothing lined up at the front, scan the remaining tokens for
        // a `<number(s)> <known-unit>` pair and hoist it to the left —
        // "flour 1 cup" → (qty=1, unit=cup, name=flour). Requires a real
        // unit match to avoid pulling stray numbers out of ingredients
        // like "San Marzano tomatoes 2021".
        if qtyTokens.isEmpty, unit.isEmpty,
           let hoisted = hoistInlineMeasurement(tokens: nameTokens) {
            qtyTokens = hoisted.qty
            unit = hoisted.unit
            nameTokens = hoisted.remaining
        }

        let name = nameTokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return nil }

        return DraftIngredient(
            quantity: qtyTokens.joined(separator: " "),
            unit: unit,
            name: name
        )
    }

    /// Scan tokens for the first `<number(s)> <known-unit>` window and
    /// pull it out. Returns nil when no measurement pair is present —
    /// in which case the caller leaves the tokens alone rather than
    /// fabricating a bogus qty/unit.
    private static func hoistInlineMeasurement(tokens: [String])
    -> (qty: [String], unit: String, remaining: [String])? {
        var i = 0
        while i < tokens.count {
            guard isQuantityToken(tokens[i]) else { i += 1; continue }

            var qtyEnd = i
            while qtyEnd + 1 < tokens.count && isQuantityToken(tokens[qtyEnd + 1]) {
                qtyEnd += 1
            }

            if qtyEnd + 1 < tokens.count {
                let candidate = tokens[qtyEnd + 1]
                    .lowercased()
                    .trimmingCharacters(in: .punctuationCharacters)
                if knownUnits.contains(candidate) {
                    let unit = unitSingularMap[candidate] ?? candidate
                    let qty = Array(tokens[i...qtyEnd])
                    var remaining = tokens
                    remaining.removeSubrange(i...(qtyEnd + 1))
                    // Drop a stray "of" if it now lands at the split point.
                    if i < remaining.count, remaining[i].lowercased() == "of" {
                        remaining.remove(at: i)
                    }
                    return (qty: qty, unit: unit, remaining: remaining)
                }
            }
            // Number run without a trailing unit — skip past and keep scanning.
            i = qtyEnd + 1
        }
        return nil
    }

    private static func parseStep(_ line: String) -> DraftStep? {
        var s = line
        if let range = s.range(of: #"^\d+[.)]\s*"#, options: .regularExpression) {
            s = String(s[range.upperBound...])
        }
        s = stripLeadingBullet(s).trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        return DraftStep(text: s)
    }

    private static func stripLeadingBullet(_ s: String) -> String {
        for prefix in ["• ", "- ", "* ", "– ", "— "] {
            if s.hasPrefix(prefix) {
                return String(s.dropFirst(prefix.count))
            }
        }
        return s
    }

    private static func isQuantityToken(_ s: String) -> Bool {
        if s == "&" { return true }
        if Double(s) != nil { return true }
        if s.contains("/"), s.split(separator: "/").allSatisfy({ Int($0) != nil }) { return true }
        return false
    }

    private static let knownUnits: Set<String> = [
        // Volume
        "cup", "cups",
        "tbsp", "tablespoon", "tablespoons",
        "tsp", "teaspoon", "teaspoons",
        "fl oz",
        "ml", "milliliter", "milliliters",
        "l", "liter", "liters", "litre", "litres",
        "pint", "pints", "quart", "quarts", "gallon", "gallons",
        // Weight
        "oz", "ounce", "ounces",
        "lb", "lbs", "pound", "pounds",
        "g", "gram", "grams",
        "kg", "kilogram", "kilograms",
        "mg", "milligram", "milligrams",
        // Discrete
        "clove", "cloves", "pinch", "pinches", "dash", "dashes",
        "slice", "slices", "piece", "pieces", "can", "cans",
        "stick", "sticks", "sprig", "sprigs", "head", "heads",
        "bunch", "bunches", "handful", "handfuls",
    ]

    /// Maps plural user-typed units back to their singular canonical form
    /// so storage stays consistent and `Plural.unit(_, for:)` can pluralize
    /// on display based on the actual quantity (avoids weird results like
    /// "1 cups" or "2 pieces" getting stuck).
    private static let unitSingularMap: [String: String] = [
        "cups": "cup",
        "tablespoons": "tablespoon",
        "teaspoons": "teaspoon",
        "ounces": "ounce",
        "pounds": "pound",
        "lbs": "lb",
        "grams": "gram",
        "kilograms": "kilogram",
        "milligrams": "milligram",
        "milliliters": "milliliter",
        "liters": "liter",
        "litres": "litre",
        "pints": "pint",
        "quarts": "quart",
        "gallons": "gallon",
        "cloves": "clove",
        "pinches": "pinch",
        "dashes": "dash",
        "slices": "slice",
        "pieces": "piece",
        "cans": "can",
        "sticks": "stick",
        "sprigs": "sprig",
        "heads": "head",
        "bunches": "bunch",
        "handfuls": "handful",
    ]
}
