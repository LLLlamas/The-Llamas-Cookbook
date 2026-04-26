import Foundation

/// Best-effort parser for pasted recipe text. Two paths:
///
/// 1. **Block format (default)** — the new convention pushed in the help
///    sheet. Blank lines separate the recipe into ordered sections:
///    *title block*, *ingredients block*, *steps block*. No keywords
///    needed — saves the user from typing "Ingredients" / "Steps".
///
/// 2. **Labeled format (fallback)** — for users who paste from Notes
///    with explicit `Ingredients` / `Steps` headers (or from the schema
///    importer, which produces clean labeled sections). Detected by
///    scanning for any of the canonical section keywords on their own
///    line; when present, takes precedence.
enum RecipeImporter {
    static func parse(_ text: String) -> DraftRecipe {
        if hasExplicitSectionLabels(text) {
            return parseLabeled(text)
        }
        return parseBlocks(text)
    }

    /// Parse a single ingredient line into one or more `DraftIngredient`s.
    /// Exposed for the schema-based URL importer, which already knows it
    /// has an ingredient and just needs the qty/unit/name split.
    static func parseIngredientLine(_ line: String) -> [DraftIngredient] {
        parseIngredients(line)
    }

    /// Parse a single instruction string into a `DraftStep`. Strips any
    /// leading numbering or bullet so a JSON-LD `HowToStep.text` like
    /// "1. Preheat oven" comes out clean.
    static func parseStepLine(_ line: String) -> DraftStep? {
        parseStep(line)
    }

    // MARK: - Labeled format

    private static func parseLabeled(_ text: String) -> DraftRecipe {
        var draft = DraftRecipe()
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var section: Section = .header
        var titleSet = false
        var summaryLines: [String] = []

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

            if applyHeaderField(line, lower: lower, into: &draft) { continue }

            switch section {
            case .header:
                summaryLines.append(line)
            case .ingredients:
                draft.ingredients.append(contentsOf: parseIngredients(line))
            case .steps:
                if let step = parseStep(line) { draft.steps.append(step) }
            }
        }

        if !summaryLines.isEmpty {
            draft.summary = summaryLines.joined(separator: " ")
        }
        return draft
    }

    // MARK: - Block format

    /// Walk the input as blank-line-separated blocks. Block 1 is the
    /// title (line 1) plus optional summary (lines 2+); block 2 is the
    /// ingredients; block 3+ is the steps. Header-field lines (Source:,
    /// Serves:, Cook time:) inside the title block are lifted out so
    /// they don't pollute the summary.
    private static func parseBlocks(_ text: String) -> DraftRecipe {
        var draft = DraftRecipe()
        let blocks = splitIntoBlocks(text)
        guard !blocks.isEmpty else { return draft }

        // --- Block 1: title (+ summary)
        let titleBlock = blocks[0]
        if let firstLine = titleBlock.first {
            draft.title = stripTitleLabel(firstLine)
        }
        if titleBlock.count > 1 {
            var summaryLines: [String] = []
            for line in titleBlock.dropFirst() {
                let lower = line.lowercased()
                if applyHeaderField(line, lower: lower, into: &draft) { continue }
                summaryLines.append(line)
            }
            if !summaryLines.isEmpty {
                draft.summary = summaryLines.joined(separator: " ")
            }
        }

        // --- Block 2: ingredients
        if blocks.count >= 2 {
            for line in blocks[1] {
                draft.ingredients.append(contentsOf: parseIngredients(line))
            }
        }

        // --- Block 3+: steps (extra blocks fold into the step list)
        if blocks.count >= 3 {
            for blockIdx in 2..<blocks.count {
                for line in blocks[blockIdx] {
                    if let step = parseStep(line) { draft.steps.append(step) }
                }
            }
        }
        return draft
    }

    /// Split into trimmed-line blocks separated by one or more blank
    /// lines. Lines that are purely whitespace count as blank, so a
    /// pasted block with stray spaces still parses cleanly.
    private static func splitIntoBlocks(_ text: String) -> [[String]] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var blocks: [[String]] = []
        var current: [String] = []
        for raw in rawLines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty {
                    blocks.append(current)
                    current = []
                }
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    private static func stripTitleLabel(_ line: String) -> String {
        if let match = try? #/^[Tt]itle(?:\s*[:\-]\s*|\s+)(.+)$/#.wholeMatch(in: line) {
            return String(match.output.1).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    /// Try to interpret `line` as a header-style metadata row (Source:,
    /// Serves:, Cook time:). Returns true when consumed so the caller
    /// can skip it in the summary / block flow.
    private static func applyHeaderField(_ line: String, lower: String, into draft: inout DraftRecipe) -> Bool {
        if let s = extractNumber(after: #"(?i)^serves?\s*:?\s*"#, in: line) {
            draft.servings = s
            return true
        }
        if let s = extractNumber(after: #"(?i)^cook(?:\s+time)?\s*:?\s*"#, in: line) {
            draft.cookTimeMinutes = s
            return true
        }
        if lower.hasPrefix("source:") {
            draft.sourceUrl = String(line.dropFirst("source:".count))
                .trimmingCharacters(in: .whitespaces)
            return true
        }
        return false
    }

    /// Cheap pre-scan: does any line in the input look like an explicit
    /// section header? When yes, the labeled parser wins because the
    /// user clearly knows the older convention; when no, fall through
    /// to block parsing so users who only put blank-line separators get
    /// the friendlier outcome.
    private static func hasExplicitSectionLabels(_ text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for raw in normalized.split(separator: "\n").map(String.init) {
            let cleaned = raw
                .trimmingCharacters(in: CharacterSet(charactersIn: " :"))
                .lowercased()
            if Self.sectionHeaderKeywords.contains(cleaned) { return true }
        }
        return false
    }

    private static let sectionHeaderKeywords: Set<String> = [
        "ingredients", "steps", "instructions", "directions", "method"
    ]

    private enum Section { case header, ingredients, steps }

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

    /// One pasted line can produce zero, one, or many ingredients:
    /// "75g milk + 75g water" splits in two, "•" (bullet only) drops out,
    /// "150g butter" produces one. The conjunction split runs only when
    /// the line carries two or more measurements — that way a compound
    /// quantity like "1 & 1/2 cup flour" stays a single ingredient even
    /// though it contains an `&`.
    private static func parseIngredients(_ line: String) -> [DraftIngredient] {
        var s = stripLeadingBullet(line).trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return [] }

        // Guard: lines that are only bullets, dashes, or punctuation
        // ("•", "- - -", "···") shouldn't become a named ingredient.
        guard s.contains(where: { $0.isLetter || $0.isNumber }) else { return [] }

        // Order matters: Unicode fractions first so "1½cup" becomes
        // "1 1/2 cup" before the fused-unit splitter looks at it.
        s = normalizeUnicodeFractions(s)
        s = s.replacingOccurrences(of: "&", with: " & ")
        s = splitFusedNumberUnit(s)
        // Repair broken fractions — "1 /3", "1/ 3", "1 / 3" all become "1/3".
        s = s.replacingOccurrences(of: #"(\d)\s*/\s*(\d)"#, with: "$1/$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let tokens = s.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }

        return splitMeasurementSegments(tokens: tokens)
            .compactMap(buildIngredient(tokens:))
    }

    private static func buildIngredient(tokens: [String]) -> DraftIngredient? {
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

        // Strip a stray leading conjunction left over from segment splitting
        // (e.g. "and 2 tbsp salt" if a user puts "and" before a measurement).
        while let first = nameTokens.first, isConjunctionToken(first) {
            nameTokens.removeFirst()
        }

        let name = nameTokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return nil }

        return DraftIngredient(
            quantity: qtyTokens.joined(separator: " "),
            unit: unit,
            name: name
        )
    }

    /// Returns the indices in `tokens` where a `<quantity-run> <known-unit>`
    /// pair begins. Two or more starts means the line packs multiple
    /// ingredients ("75g milk + 75g water"); one start (or zero) means the
    /// line is a single ingredient and stays whole.
    private static func findMeasurementStarts(in tokens: [String]) -> [Int] {
        var starts: [Int] = []
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
                    starts.append(i)
                    i = qtyEnd + 2
                    continue
                }
            }
            i = qtyEnd + 1
        }
        return starts
    }

    private static func splitMeasurementSegments(tokens: [String]) -> [[String]] {
        let starts = findMeasurementStarts(in: tokens)
        guard starts.count >= 2 else { return [tokens] }

        var segments: [[String]] = []
        for k in 0..<starts.count {
            let start = starts[k]
            let end = (k + 1 < starts.count) ? starts[k + 1] : tokens.count
            var seg = Array(tokens[start..<end])
            while let last = seg.last, isConjunctionToken(last) {
                seg.removeLast()
            }
            if !seg.isEmpty {
                segments.append(seg)
            }
        }
        return segments
    }

    private static func isConjunctionToken(_ s: String) -> Bool {
        let t = s.lowercased()
        return t == "+" || t == "&" || t == "and" || t == "or"
    }

    /// Replaces vulgar-fraction characters (½, ⅓, …) with ASCII fractions,
    /// padded with spaces so a fused "1½cup" tokenizes cleanly into
    /// "1 1/2 cup". The trailing whitespace collapse later re-tightens it.
    private static func normalizeUnicodeFractions(_ s: String) -> String {
        var result = ""
        for ch in s {
            if let ascii = unicodeFractionMap[ch] {
                result.append(" ")
                result.append(ascii)
                result.append(" ")
            } else {
                result.append(ch)
            }
        }
        return result
    }

    /// Inserts a space between a number and a known-unit suffix so "150g"
    /// becomes "150 g" and "2tbsp" becomes "2 tbsp". Constrained to the
    /// `knownUnits` set so we don't fragment arbitrary digit-letter
    /// sequences inside ingredient names (e.g. "Vitamin B12").
    private static func splitFusedNumberUnit(_ s: String) -> String {
        s.replacingOccurrences(
            of: fusedUnitPattern,
            with: "$1 $2",
            options: [.regularExpression, .caseInsensitive]
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

    /// Built once from `knownUnits`, longest-first so "grams" wins over "g"
    /// when both could match a fused suffix. Word-boundary terminator (\b)
    /// prevents bleeding into adjacent letters — "150grain" stays intact
    /// because "g" doesn't sit on a word boundary inside that token.
    private static let fusedUnitPattern: String = {
        let units = knownUnits
            .filter { !$0.contains(" ") }
            .sorted { $0.count > $1.count }
            .joined(separator: "|")
        return "(\\d)(\(units))\\b"
    }()

    private static let unicodeFractionMap: [Character: String] = [
        "\u{00BC}": "1/4", "\u{00BD}": "1/2", "\u{00BE}": "3/4",
        "\u{2150}": "1/7", "\u{2151}": "1/9", "\u{2152}": "1/10",
        "\u{2153}": "1/3", "\u{2154}": "2/3",
        "\u{2155}": "1/5", "\u{2156}": "2/5", "\u{2157}": "3/5", "\u{2158}": "4/5",
        "\u{2159}": "1/6", "\u{215A}": "5/6",
        "\u{215B}": "1/8", "\u{215C}": "3/8", "\u{215D}": "5/8", "\u{215E}": "7/8",
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
