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
        let cleaned = stripTrailingHandle(text)
        let exploded = explodeSingleParagraph(cleaned)
        if hasExplicitSectionLabels(exploded) {
            return parseLabeled(exploded)
        }
        return parseBlocks(exploded)
    }

    /// Strip TikTok-style `@handle` decorations from a pasted caption.
    /// TikTok captions copied directly from the app — and some share
    /// sheets — append the creator's handle after the recipe text,
    /// which has no business in the recipe model.
    ///
    /// Conservative scope: only the trailing handle (very end of
    /// text) and entire-line handle rows are stripped. Inline
    /// `@mentions` mid-text are left alone — that avoids false
    /// positives on email addresses and on attribution lines like
    /// "Adapted from @smittenkitchen's brownie recipe", where the
    /// mention is part of meaningful prose.
    ///
    /// Note: the URL-import path strips handles more aggressively in
    /// `RecipeURLImporter.liftHashtags` because we already know it's
    /// a TikTok caption. This text-paste path can't make that
    /// assumption, hence the lighter touch.
    private static func stripTrailingHandle(_ text: String) -> String {
        // 1. Drop any line whose only content is a handle.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let dehandled = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if (try? #/^@[\p{L}\p{N}_.]+$/#.wholeMatch(in: trimmed)) != nil {
                    return ""
                }
                return line
            }
            .joined(separator: "\n")

        // 2. Strip a trailing handle (and absorb the punctuation /
        // whitespace gap that typically separates it from the recipe
        // text — e.g. "…Bake 12 min. @creator" or "…cookies! @creator").
        return dehandled.replacing(
            #/[\s,;:.\-—–]*@[\p{L}\p{N}_.]+\s*$/#,
            with: ""
        )
    }

    /// Insert newlines into a single-paragraph TikTok-style caption so
    /// the existing block parser can recognize ingredients and steps.
    /// TikTok oEmbed delivers the caption as one long line — title,
    /// ingredients, and a dozen steps all glued together with spaces
    /// and periods — and `parseBlocks` collapses that whole thing into
    /// the title block, leaving zero ingredients / zero steps.
    ///
    /// Exposed for callers that know they're handling caption-style
    /// input (the URL importer's seed-text path can pre-explode before
    /// re-displaying to the user).
    ///
    /// No-op for input that already contains line breaks — multi-line
    /// pastes already go through the right path.
    static func explodeSingleParagraph(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let nonEmptyLines = normalized
            .split(separator: "\n", omittingEmptySubsequences: true)
            .count
        guard nonEmptyLines <= 1 else { return normalized }

        var s = normalized

        // 1. Sentence boundaries — letter+(.|!|?)+space+(Capital|digit).
        // The greedy `\s+` swallows any trailing whitespace (including
        // the double spaces TikTok inserts between sentences) so we
        // don't leave a leading space on the next line.
        s = s.replacingOccurrences(
            of: #"([\p{L}])([.!?])\s+(?=\p{Lu}|\d)"#,
            with: "$1$2\n",
            options: .regularExpression
        )

        // 2. Double-space gap (TikTok inserts these between sentences
        // even when the prior char isn't a letter — e.g. after a
        // closing paren or a degree symbol).
        s = s.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: "\n",
            options: .regularExpression
        )

        // 3. Comma + Then / digit boundary. Caption authors glue a
        // wait and the next action with a comma:
        //   "Let sit for 1 hour, then do 8 stretch and folds"
        //   "Let sit for 30 minutes, 8 more stretch and folds"
        s = s.replacingOccurrences(
            of: #",\s+(?=[Tt]hen\b|\d)"#,
            with: "\n",
            options: .regularExpression
        )

        // 4. Measurement-start boundary — split before each `<num><unit>`
        // when preceded by a non-whitespace character. Breaks ingredient
        // runs like "100g starter 390g water 530g flour" into one per
        // line. The unit list is borrowed from `knownUnits` and excludes
        // time units, so step text like "for 1 hour" / "for 30 minutes"
        // stays on a single line.
        s = s.replacingOccurrences(
            of: explodeMeasurementPattern,
            with: "\n",
            options: .regularExpression
        )

        // 5. Step-verb boundary — split before known cooking command
        // verbs when the prior char is a non-uppercase, non-whitespace
        // character. Catches the ingredient→step transition where
        // there's no period or measurement to split on:
        //   "10g salt Combine into shaggy dough" → "10g salt" + "Combine…"
        //   "for 1-2 hours Preheat Dutch oven"   → "for 1-2 hours" + "Preheat…"
        //   "while dough is proofing) Bake for 30 minutes" → split on ") Bake"
        s = s.replacingOccurrences(
            of: explodeVerbPattern,
            with: "\n",
            options: .regularExpression
        )

        return s
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
        parseStep(line).map(enrichStep)
    }

    /// Title cleanup pass — exposed so the AI parser can run it on the
    /// model's title output. The model is *told* to strip "Recipe👇"
    /// and trailing emoji runs, but small on-device models drift; this
    /// is the deterministic fallback.
    static func cleanTitle(_ s: String) -> String {
        stripTitleLabel(s)
    }

    /// Post-process an AI-parsed step. Runs the parenthetical / "while X"
    /// lift, then **overrides** `needsTimer` from `hasTimerSignal` rather
    /// than trusting the model's flag. Rationale: the compound-noun
    /// guard ("8 hour sourdough", "30 minute meal") is encoded
    /// deterministically in `hasTimerSignal`, and the model loses that
    /// rule under load far more often than it loses ingredient parsing.
    static func enrichAIStep(_ step: DraftStep) -> DraftStep {
        var s = liftWhileClause(step)
        s.needsTimer = hasTimerSignal(s.text)
        return s
    }

    /// Parse one input string into one *or more* `DraftStep`s. Use this
    /// when the input might glue several steps together — TikTok captions
    /// and JSON-LD `HowToStep.text` fields where publishers stuff a whole
    /// recipe into one paragraph. Splits via `splitIntoSteps` first, then
    /// runs each piece through the standard step parser + enrichment
    /// (timer flag, "while X" → special note).
    static func parseStepLines(_ line: String) -> [DraftStep] {
        splitIntoSteps(line)
            .compactMap { parseStep($0) }
            .map(enrichStep)
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
                draft.steps.append(contentsOf: parseStepLines(line))
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
    ///
    /// Caption-style fallback: TikTok's oEmbed and some share-sheet
    /// pastes strip the blank-line separators between sections,
    /// leaving a stack of single-newline lines. Blank-line block
    /// parsing then collapses everything into the title block and
    /// emits zero ingredients / zero steps. When we detect that
    /// shape (≤ 2 blocks but ≥ 6 lines total), we hand off to a
    /// per-line classifier that uses measurement markers to tell
    /// ingredients from steps.
    private static func parseBlocks(_ text: String) -> DraftRecipe {
        var draft = DraftRecipe()
        let blocks = splitIntoBlocks(text)
        guard !blocks.isEmpty else { return draft }

        let totalLines = blocks.reduce(0) { $0 + $1.count }
        if blocks.count <= 2, totalLines >= 6 {
            return parseUnstructuredLines(blocks.flatMap { $0 })
        }

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

        // --- Block 3+: steps (extra blocks fold into the step list).
        // Each line goes through `parseStepLines` rather than `parseStep`
        // so a single line that mashes several steps together — common
        // with TikTok captions like "Step 1: Combine. Step 2: Rest …" —
        // splits into separate steps instead of becoming one giant blob.
        if blocks.count >= 3 {
            for blockIdx in 2..<blocks.count {
                for line in blocks[blockIdx] {
                    draft.steps.append(contentsOf: parseStepLines(line))
                }
            }
        }
        return draft
    }

    /// Per-line classifier for caption-style input where the source
    /// dropped the blank-line section breaks. First line becomes the
    /// title; every line after that is sorted into ingredients vs.
    /// steps by `looksLikeIngredient`. Header-field lines (Source:,
    /// Serves:, Cook time:) are still lifted out into their own
    /// fields rather than misclassified.
    private static func parseUnstructuredLines(_ lines: [String]) -> DraftRecipe {
        var draft = DraftRecipe()
        guard let first = lines.first else { return draft }
        draft.title = stripTitleLabel(first)

        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if applyHeaderField(line, lower: lower, into: &draft) { continue }
            if looksLikeIngredient(line) {
                draft.ingredients.append(contentsOf: parseIngredients(line))
            } else {
                draft.steps.append(contentsOf: parseStepLines(line))
            }
        }
        return draft
    }

    /// True when the line opens with a `<number><unit>` shape — the
    /// strongest signal we have for "this is an ingredient, not a
    /// cooking instruction" without doing real semantic analysis.
    /// Anchors the match at the start of the (post-bullet-stripped)
    /// line so a step like "Bake 30 minutes" doesn't false-positive
    /// from its leading number; ingredient lines almost always begin
    /// with the quantity.
    private static func looksLikeIngredient(_ line: String) -> Bool {
        let stripped = stripLeadingBullet(line).trimmingCharacters(in: .whitespaces)
        // Quantity: integer, decimal, vulgar fraction, or simple
        // mixed/improper fraction (e.g. "1 1/2", "1/4").
        // Then optional whitespace, then a known unit keyword.
        let pattern = #/(?i)^\d+(?:[.\u{00BC}-\u{215E}]\d*)?(?:\s+\d+/\d+)?(?:/\d+)?\s*(cup|cups|tbsp|tablespoon|tablespoons|tsp|teaspoon|teaspoons|oz|ounce|ounces|lb|lbs|pound|pounds|g|gram|grams|kg|kilogram|kilograms|mg|ml|milliliter|milliliters|l|liter|liters|litre|litres|pint|pints|quart|quarts|gallon|gallons|clove|cloves|pinch|pinches|dash|dashes|slice|slices|piece|pieces|can|cans|stick|sticks|sprig|sprigs|head|heads|bunch|bunches|handful|handfuls)\b/#
        return (try? pattern.firstMatch(in: stripped)) != nil
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

    /// Tidy a raw title line into something fit to display. Three
    /// passes, each independently optional:
    ///
    /// 1. `"Title: Foo"` / `"Title - Foo"` / `"Title Foo"` — old-school
    ///    labeled prefix; keep the value side.
    /// 2. `"Recipe👇 Foo"` / `"Recipe: Foo"` — TikTok-style intros where
    ///    "Recipe" is followed by an arrow emoji or colon used as a
    ///    pointer to the actual content. Strip the marker plus any
    ///    emoji / punctuation glyphs that immediately follow it.
    /// 3. Trailing emoji / exclamation runs ("Sourdough!😍🙌🏻") —
    ///    chop until the string ends on a letter or digit so the
    ///    library row doesn't carry social-media ornamentation.
    private static func stripTitleLabel(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = try? #/^[Tt]itle(?:\s*[:\-]\s*|\s+)(.+)$/#.wholeMatch(in: s) {
            s = String(match.output.1).trimmingCharacters(in: .whitespaces)
        }
        // \p{S} = Symbol (covers emoji), \p{P} = Punctuation,
        // \p{Z} = Separator (incl. spaces). Together they swallow the
        // arrow-emoji-and-colon decoration TikTok captions stack
        // between "Recipe" and the dish name.
        if let match = try? #/^[Rr]ecipe[\p{P}\p{S}\p{Z}]*(.+)$/#.wholeMatch(in: s) {
            let candidate = String(match.output.1).trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty { s = candidate }
        }
        while let last = s.last,
              !last.isLetter,
              !last.isNumber,
              !last.isWhitespace {
            s = String(s.dropLast())
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // "Step 1:", "Step 1." — same idea, drop the marker entirely so
        // it doesn't bleed into the visible step text.
        if let range = s.range(of: #"^(?i)step\s+\d+\s*[:.)\-]\s*"#, options: .regularExpression) {
            s = String(s[range.upperBound...])
        }
        s = stripLeadingBullet(s).trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // Capitalize the first letter. After `splitIntoSteps` cuts on a
        // ", then …" boundary the second piece begins with lowercase
        // "then …"; in Detail / Cook view that reads as a typo, so
        // bring it up to sentence case before the step ships.
        if let first = s.first, first.isLowercase {
            s = String(first).uppercased() + s.dropFirst()
        }
        return DraftStep(text: s)
    }

    /// Split one instruction string into separate steps using
    /// progressively weaker signals. Without this, a TikTok caption or
    /// schema field that ships multiple steps glued into one paragraph
    /// ends up as a single step in the editor.
    ///
    /// 1. **Newlines** — cleanest signal; respect publisher layout.
    /// 2. **Numbered markers** — "Step 1:", "Step 1.", "1.", "1)".
    ///    `\b` anchors the marker to a word boundary so "mix1." won't
    ///    fragment, and the trailing `\s+` requirement prevents
    ///    matching mid-decimal: "1.5 cups" has "5" after the period,
    ///    not whitespace, so it's left alone.
    /// 3. **Comma-then / comma-digit boundary** — caption authors glue
    ///    a wait and the next action with a comma ("…1 hour, then do
    ///    8 folds"). Lookahead requires "then" or a digit so we don't
    ///    shatter prose lists ("flour, salt, water").
    /// 4. **Sentence boundaries** — last resort. Letter + period +
    ///    whitespace + capital or digit. The leading letter (consumed
    ///    as part of the match, since Swift Regex literals don't
    ///    support lookbehind) excludes "1.5" splits while still
    ///    catching "350°F. Cream butter…" because F is a letter.
    static func splitIntoSteps(_ raw: String) -> [String] {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return [] }

        // 1. Newlines.
        let byNewline = s
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if byNewline.count > 1 { return byNewline }

        // 2. Numbered step markers — drop the marker entirely.
        let markerRegex = #/\b(?:[Ss]tep\s+\d+\s*[:.)]|\d+\s*[.)])\s+/#
        let markers = Array(s.matches(of: markerRegex))
        if markers.count >= 2 {
            var pieces: [String] = []
            var cursor = s.startIndex
            for m in markers {
                let segment = s[cursor..<m.range.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty { pieces.append(segment) }
                cursor = m.range.upperBound
            }
            let tail = s[cursor...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { pieces.append(tail) }
            if pieces.count >= 2 { return pieces }
        }

        // 3. Comma-then / comma-digit boundary. Caption authors very
        // often glue a wait and a follow-up action with a comma:
        //   "Let sit for 30 minutes, 8 more stretch and folds"
        //   "Let sit for 1 hour, then do 8 stretch and folds"
        // Splitting on `,` alone would shatter ingredient-style lists
        // ("flour, salt, water"), so the lookahead requires either the
        // word "then" or a digit — both strong "next instruction"
        // signals in caption prose. Lookahead keeps the trigger word
        // with the second piece so it reads naturally.
        let commaBoundaryRegex = #/,\s+(?=[Tt]hen\b|\d)/#
        let commas = Array(s.matches(of: commaBoundaryRegex))
        if !commas.isEmpty {
            var pieces: [String] = []
            var cursor = s.startIndex
            for m in commas {
                let segment = s[cursor..<m.range.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty { pieces.append(segment) }
                cursor = m.range.upperBound
            }
            let tail = s[cursor...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { pieces.append(tail) }
            if pieces.count >= 2 { return pieces }
        }

        // 4. Sentence boundary fallback. Match consumes the letter
        // and period (no lookbehind support), so we keep the first
        // two characters of each match with the previous piece —
        // "Foo. Bar" becomes ["Foo.", "Bar"]. The lookahead accepts
        // either a capital letter OR a digit so a paragraph that ends
        // with "…30 minutes. 8 more stretch and folds" splits into
        // two steps instead of one (the digit-led sentence is the
        // start of the next instruction in caption-style writing).
        let sentenceRegex = #/[a-zA-Z]\.\s+(?=[A-Z]|\d)/#
        let sentences = Array(s.matches(of: sentenceRegex))
        if !sentences.isEmpty {
            var pieces: [String] = []
            var cursor = s.startIndex
            for m in sentences {
                let prevEnd = s.index(
                    m.range.lowerBound,
                    offsetBy: 2,
                    limitedBy: m.range.upperBound
                ) ?? m.range.upperBound
                let segment = s[cursor..<prevEnd]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty { pieces.append(segment) }
                cursor = m.range.upperBound
            }
            let tail = s[cursor...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { pieces.append(tail) }
            if pieces.count >= 2 { return pieces }
        }

        return [s]
    }

    /// Layer the post-parse enrichments onto a freshly-parsed step:
    /// auto-flag a timer if the step mentions a duration, and lift any
    /// `while X` clause out of the body and into `specialNote` so it
    /// shows in the dedicated callout instead of cluttering the step.
    private static func enrichStep(_ step: DraftStep) -> DraftStep {
        var s = liftWhileClause(step)
        if !s.needsTimer, hasTimerSignal(s.text) {
            s.needsTimer = true
        }
        return s
    }

    /// Lift a parenthetical aside or "while X …" suffix out of the step
    /// text and into the special note. Two passes:
    ///
    /// 1. **Parenthetical first**: `"Preheat oven (start while X)"` →
    ///    text becomes `"Preheat oven"`, note becomes `"Start while X"`.
    ///    Doing this *before* the bare-while split is what fixes the
    ///    trailing-`)` bug — a "while" that lives inside parens used to
    ///    split the step in the wrong place, leaving an unmatched `(`
    ///    on the left and a dangling `)` on the right.
    /// 2. **Bare-while fallback**: `"Stir while butter melts"` →
    ///    `"Stir"` + note `"While butter melts"`. Only fires when no
    ///    parens were available.
    ///
    /// The main action must be substantive (≥ 2 words) so a short stub
    /// like `"Stir"` doesn't get hollowed out into a bare verb with all
    /// its detail in the note.
    private static func liftWhileClause(_ step: DraftStep) -> DraftStep {
        // Don't disturb steps that already carry a special note — the
        // note is the user's, not ours to overwrite.
        guard step.specialNote == nil else { return step }
        let text = step.text

        // 1. Parenthetical extraction. The captured group is the inside
        //    of the parens; the surrounding `\s*` consumes the gap on
        //    either side so we don't leave a double space behind.
        if let parens = try? #/\s*\(([^()]+)\)\s*/#.firstMatch(in: text) {
            let inside = String(parens.output.1)
                .trimmingCharacters(in: .whitespaces)
            let before = String(text[..<parens.range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let after = String(text[parens.range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            let main = [before, after]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !main.isEmpty, !inside.isEmpty {
                var copy = step
                copy.text = main
                copy.specialNote = capitalizingFirst(inside)
                return copy
            }
        }

        // 2. Bare "while" fallback.
        guard let range = text.range(of: #"(?i)\s+while\s+"#, options: .regularExpression) else {
            return step
        }
        let main = String(text[..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let tail = String(text[range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard main.split(separator: " ").count >= 2,
              !tail.isEmpty
        else { return step }
        var copy = step
        copy.text = main
        copy.specialNote = "While " + tail
        return copy
    }

    /// Capitalize the first letter without touching the rest. Used on
    /// lifted parenthetical content so `"start preheating …"` reads as
    /// `"Start preheating …"` in the special-note callout.
    private static func capitalizingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    /// Quick check for "this step mentions a timer-shaped duration":
    /// any `<number> <hour|min|sec>` pair, including ranges. Used to
    /// auto-flag `needsTimer` so imported recipes light up in Cook Mode
    /// without the user manually toggling each step.
    ///
    /// The trailing alternation is the false-positive guard: a duration
    /// only counts as a timer cue when it's followed by punctuation, a
    /// connector word (`with`, `then`, `until`, …), or end-of-text.
    /// Without that, compound adjectives where the duration modifies
    /// a noun ("8 hour sourdough", "30 minute meal") would all trip
    /// the flag and leave the user with bogus timers in Cook Mode.
    private static func hasTimerSignal(_ text: String) -> Bool {
        let pattern = #/(?i)\d+(?:\.\d+)?(?:\s*[-–—]\s*\d+(?:\.\d+)?)?\s*(?:hours?|hrs?|minutes?|mins?|seconds?|secs?)\b(?:\s*[.,;:!?]|\s+(?:with|then|and|or|until|in|at|on|of|before|after)\b|\s*$)/#
        return (try? pattern.firstMatch(in: text)) != nil
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

    /// Lookbehind: any non-whitespace char (so the pattern fires after
    /// emoji, closing parens, degree signs, etc.). Lookahead: a number
    /// followed by a known unit. The unit list excludes hour / minute
    /// / second so step text like "for 1 hour" doesn't split mid-clause.
    private static let explodeMeasurementPattern: String = {
        let units = knownUnits
            .filter { !$0.contains(" ") }
            .sorted { $0.count > $1.count }
            .joined(separator: "|")
        return "(?<=\\S)\\s+(?=\\d+(?:[.,]\\d+)?\\s*(?:\(units))\\b)"
    }()

    /// Lookbehind: any non-uppercase, non-whitespace char (lowercase
    /// letters, digits, punctuation, emoji, °). Lookahead: a known
    /// step-starting verb. Restricting the lookbehind keeps the rule
    /// from firing inside Title-Case phrases like "First Slice" — only
    /// the prior word has to *not* be a Capital-led word.
    private static let explodeVerbPattern: String = {
        let verbs = [
            "Preheat", "Combine", "Knead", "Refrigerate",
            "Boil", "Simmer", "Bake", "Roast", "Broil", "Grill", "Fry",
            "Sauté", "Saute", "Steam", "Marinate", "Chill", "Freeze",
            "Garnish", "Enjoy", "Serve", "Let", "Shape", "Stretch",
            "Whisk", "Stir", "Beat", "Pour", "Spread", "Drizzle",
            "Sprinkle", "Place", "Remove", "Cover", "Heat", "Cool",
            "Top", "Fold", "Toast", "Sear", "Reduce", "Bring", "Allow",
            "Cook", "Cut", "Chop", "Slice", "Mince", "Dice", "Brush",
            "Dust", "Coat", "Season", "Transfer", "Roll", "Form"
        ].joined(separator: "|")
        return "(?<=[^\\sA-Z])\\s+(?=(?:\(verbs))\\b)"
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
