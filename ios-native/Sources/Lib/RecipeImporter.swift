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

    /// Build a draft from three already-separated inputs. Used by the three-
    /// section Import view, where the user supplies title / ingredients /
    /// steps in their own fields and we don't need to hunt for section
    /// headers inside a single blob.
    static func build(title: String, ingredientsText: String, stepsText: String) -> DraftRecipe {
        var draft = DraftRecipe()
        draft.title = title.trimmingCharacters(in: .whitespaces)
        for line in nonEmptyLines(of: ingredientsText) {
            if let ing = parseIngredient(line) { draft.ingredients.append(ing) }
        }
        for line in nonEmptyLines(of: stepsText) {
            if let step = parseStep(line) { draft.steps.append(step) }
        }
        return draft
    }

    /// Count how many parseable ingredient lines are in the given text — used
    /// by the Import view's live checklist without actually committing a draft.
    static func countIngredients(in text: String) -> Int {
        nonEmptyLines(of: text).filter { parseIngredient($0) != nil }.count
    }

    /// Same, for steps.
    static func countSteps(in text: String) -> Int {
        nonEmptyLines(of: text).filter { parseStep($0) != nil }.count
    }

    private static func nonEmptyLines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
                unit = tokens[idx]
                idx += 1
            }
        }

        let nameTokens = tokens[idx...].joined(separator: " ")
        let name = nameTokens.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return nil }

        return DraftIngredient(
            quantity: qtyTokens.joined(separator: " "),
            unit: unit,
            name: name
        )
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
        "cup", "cups", "tbsp", "tsp", "oz", "lb", "lbs",
        "g", "kg", "mg", "ml", "l",
        "clove", "cloves", "pinch", "pinches", "dash", "dashes",
        "slice", "slices", "piece", "pieces", "can", "cans",
        "stick", "sticks", "sprig", "sprigs", "head", "heads",
        "bunch", "bunches",
    ]
}
