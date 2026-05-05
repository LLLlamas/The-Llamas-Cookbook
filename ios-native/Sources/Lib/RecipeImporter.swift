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
        var draft: DraftRecipe
        if hasExplicitSectionLabels(exploded) {
            draft = parseLabeled(exploded)
        } else {
            draft = parseBlocks(exploded)
        }
        // Post-merge orphan-duration steps. Vision sometimes returns a
        // handwritten "Bake 425 degrees, 10 mins" as two separate
        // observations (the comma + space happens to land at a natural
        // break point) — each observation becomes its own step, leaving
        // a meaningless "10 mins" standalone step. The single-line
        // splitter in `splitIntoSteps` can't help once the input is
        // already split across lines, so this pass glues any pure-
        // duration step back onto the preceding action.
        draft.steps = mergeOrphanDurationSteps(draft.steps)
        return draft
    }

    /// Detect "pure duration" steps ("10 mins", "30 minutes", "1-2
    /// hours") that shouldn't stand alone and merge them into the
    /// preceding step's text. Standalone durations are nonsensical as
    /// instructions — they're always a time annotation glued to the
    /// previous action by some upstream split (Vision splitting a line
    /// at a comma, or the user pasting with stray newlines).
    ///
    /// Pure-duration as the FIRST step (no prior to merge into) is
    /// preserved as-is — extremely rare, and the fallback at least
    /// keeps the data visible to the user.
    ///
    /// Exposed (non-private) so the AI path can apply the same merge
    /// via `RecipeAIParser.toDraft`. Both parser pipelines now go
    /// through the same orphan-duration normalizer, which keeps the
    /// best-of picker comparing step counts on equal footing.
    static func mergeOrphanDurationSteps(_ steps: [DraftStep]) -> [DraftStep] {
        var merged: [DraftStep] = []
        for step in steps {
            if isPureDuration(step.text), let last = merged.last {
                var lastText = last.text.trimmingCharacters(in: .whitespaces)
                if lastText.hasSuffix(",") {
                    lastText = String(lastText.dropLast())
                        .trimmingCharacters(in: .whitespaces)
                }
                let combinedText = lastText + ", " + step.text
                let combinedStep = DraftStep(
                    id: last.id,
                    text: combinedText,
                    needsTimer: last.needsTimer || hasTimerSignal(combinedText),
                    specialNote: last.specialNote,
                    images: last.images
                )
                merged[merged.count - 1] = combinedStep
            } else {
                merged.append(step)
            }
        }
        return merged
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

    /// Returns true when a parsed caption has enough content to be a
    /// recipe, not just a social blurb that happened to mention food.
    static func hasUsableRecipeContent(_ draft: DraftRecipe) -> Bool {
        let realIngredientCount = draft.ingredients.filter { ing in
            !ing.name.trimmed.isEmpty
                && (!ing.quantity.trimmed.isEmpty || !ing.unit.trimmed.isEmpty)
        }.count
        if realIngredientCount >= 1 { return true }

        let realSteps = draft.steps.filter { hasCookingActionOrDuration($0.text) }
        return realSteps.count >= 2
    }

    /// Extract a likely source URL from social captions. Supports both
    /// full links and domain-only mentions such as "smittenkitchen.com".
    static func extractCaptionURL(_ text: String) -> URL? {
        if let match = try? #/https?:\/\/[^\s<>"']+/#.firstMatch(in: text) {
            let raw = String(match.output.0).trimmingCharacters(in: captionURLTrimCharacters)
            if let url = URL(string: raw) { return url }
        }
        let lower = text.lowercased()
        if let match = try? #/\b([a-z0-9-]+\.(?:com|net|org|io|co|us|blog|food|recipe|kitchen)(?:\/[^\s<>"']*)?)\b/#.firstMatch(in: lower) {
            if match.range.lowerBound > lower.startIndex {
                let previous = lower[lower.index(before: match.range.lowerBound)]
                if previous == "@" || previous == "." { return nil }
            }
            let raw = String(match.output.1).trimmingCharacters(in: captionURLTrimCharacters)
            return URL(string: "https://" + raw)
        }
        return nil
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

    /// Repairs OCR-collapsed mixed fractions in measurement contexts.
    /// Example: handwritten "1 1/2 cup" can arrive as "142 cup" when
    /// Vision eats the spaces and reads the slash as a 4. Scoped to
    /// home-cooking units where 112/142 is implausible as a real amount.
    static func repairCollapsedMixedFractionQuantities(_ text: String) -> String {
        text.replacingOccurrences(
            of: "(?<!\\d)1(?:12|42)\\s*(\(collapsedMixedFractionUnitPattern))\\b",
            with: "1 1/2 $1",
            options: [.regularExpression, .caseInsensitive]
        )
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
            if sectionMatches(lower, ["steps", "instructions", "directions", "method", "preparation", "procedure"]) { section = .steps; continue }

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
        let rawBlocks = splitIntoBlocks(text)
        guard !rawBlocks.isEmpty else { return draft }

        // Pass 1 — lift header-shaped metadata out of every block
        // before classification. Cookbook + handwritten layouts often
        // put metadata in its own block ("8 servings\n20 min prep time"
        // sandwiched between title and ingredients). Without this pass,
        // a metadata-only block 2 would hijack the ingredients slot and
        // push real ingredients into steps.
        //
        // The title line — firstLine of the first block — is exempt:
        // an unfortunate "Source: My Cookbook" or "Yields: Brownies" as
        // a literal recipe name would otherwise be eaten by the header
        // matcher and leave us with no title.
        var blocks: [[String]] = []
        for (blockIdx, block) in rawBlocks.enumerated() {
            // Metadata-shape detection: a small block (≤ 2 lines)
            // where every line is a short digit-led pair without an
            // ampersand or fraction is almost certainly an OCR'd
            // metadata block ("8 servings\n20 min prep time") even
            // when the keyword itself misread ("8 serugs", "20 min
            // piep time"). The shape-based fallback below kicks in
            // only when the block matches this profile, so it can't
            // hijack ingredient blocks that legitimately lead with a
            // digit.
            let allLooksMetadata = blockIdx > 0
                && block.count <= 2
                && block.allSatisfy { lineLooksLikeMetadataShape($0) }

            var remaining: [String] = []
            for (lineIdx, line) in block.enumerated() {
                if blockIdx == 0 && lineIdx == 0 {
                    remaining.append(line)
                    continue
                }
                let lower = line.lowercased()
                if applyHeaderField(line, lower: lower, into: &draft) { continue }
                if allLooksMetadata,
                   applyMetadataShapeFallback(line, into: &draft) { continue }
                remaining.append(line)
            }
            if !remaining.isEmpty {
                blocks.append(remaining)
            }
        }
        guard !blocks.isEmpty else { return draft }

        // Caption-style fallback — single big block (or a runaway pair)
        // from TikTok / OCR with no blank-line separators. Hand off to
        // the per-line classifier that uses measurement markers to tell
        // ingredients from steps.
        let totalLines = blocks.reduce(0) { $0 + $1.count }
        if blocks.count <= 2, totalLines >= 6 {
            // Fold what we already extracted (title-less so far) into a
            // partial draft, then merge the unstructured-pass result on
            // top so metadata captured above doesn't get clobbered.
            var unstructured = parseUnstructuredLines(blocks.flatMap { $0 })
            if draft.servings.isEmpty { draft.servings = unstructured.servings }
            if draft.cookTimeMinutes.isEmpty { draft.cookTimeMinutes = unstructured.cookTimeMinutes }
            if draft.prepTimeMinutes.isEmpty { draft.prepTimeMinutes = unstructured.prepTimeMinutes }
            unstructured.servings = draft.servings
            unstructured.cookTimeMinutes = draft.cookTimeMinutes
            unstructured.prepTimeMinutes = draft.prepTimeMinutes
            return unstructured
        }

        // --- Block 1: title (+ summary)
        let titleBlock = blocks[0]
        if let firstLine = titleBlock.first {
            draft.title = stripTitleLabel(firstLine)
        }
        if titleBlock.count > 1 {
            let summaryLines = Array(titleBlock.dropFirst())
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
    ///
    /// The mixed-fraction part accepts both the space form ("1 1/2")
    /// and the ampersand form ("1&1/2", "1 & 1/2") — the latter is
    /// this app's canonical mixed-fraction display so users hand-write
    /// recipes that round-trip through OCR using `&`.
    private static func looksLikeIngredient(_ line: String) -> Bool {
        let stripped = stripLeadingBullet(line).trimmingCharacters(in: .whitespaces)
        // Quantity: integer, decimal, vulgar fraction, or simple
        // mixed/improper fraction. Forms recognized:
        //   "1 cup", "1.5 cup", "1½ cup",
        //   "1 1/2 cup", "1&1/2 cup", "1 & 1/2 cup",
        //   "1 & ½ cup"  (the OCR-repaired form for "1⅙½ cup"),
        //   "1/4 cup".
        // Then optional whitespace, then a known unit keyword. The
        // mixed-fraction inner alternation accepts EITHER a `\d+/\d+`
        // fraction OR a single Unicode vulgar fraction so handwritten
        // input ("1 & ½ cup") classifies as ingredient instead of
        // falling through to the step list.
        let pattern = #/(?i)^\d+(?:[.\u{00BC}-\u{215E}]\d*)?(?:(?:\s+|\s*&\s*)(?:\d+/\d+|[\u{00BC}-\u{215E}]))?(?:/\d+)?\s*(cup|cups|tbsp|tablespoon|tablespoons|tsp|teaspoon|teaspoons|oz|ounce|ounces|lb|lbs|pound|pounds|g|gram|grams|kg|kilogram|kilograms|mg|ml|milliliter|milliliters|l|liter|liters|litre|litres|pint|pints|quart|quarts|gallon|gallons|clove|cloves|pinch|pinches|dash|dashes|slice|slices|piece|pieces|can|cans|stick|sticks|sprig|sprigs|head|heads|bunch|bunches|handful|handfuls)\b/#
        return (try? pattern.firstMatch(in: stripped)) != nil
            || looksLikeBareCountIngredient(stripped)
    }

    private static func looksLikeBareCountIngredient(_ line: String) -> Bool {
        let words = line.split(separator: " ")
        guard words.count <= 6,
              let match = try? #/^(\d+(?:[.,\/]\d+)?)\s+(?:[\p{L}'-]+\s+){0,4}([\p{L}'-]+)\s*$/#.wholeMatch(in: line)
        else { return false }
        let lastWord = String(match.output.2)
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
        return bareCountFoods.contains(lastWord)
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
        s = stripLeadingDecoration(s)
        s = stripBioMarker(s)
        while let last = s.last,
              !last.isLetter,
              !last.isNumber,
              !last.isWhitespace {
            s = String(s.dropLast())
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLeadingDecoration(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = s.first,
              !first.isLetter,
              !first.isNumber {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let match = try? #/^(?i)(?:best\s+ever|easy|viral|famous)\s+[\p{P}\p{S}\p{Z}]+(.+)$/#.wholeMatch(in: s) {
            let candidate = String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { s = candidate }
        }
        return s
    }

    private static func stripBioMarker(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = try? #/(?i)\s*(?:[-–—]\s*)?(?:full\s+recipe\s+(?:in|on|at)|recipe\s+(?:in|on|at)|links?\s+in\s+(?:bio|profile)|linked\s+in\s+(?:bio|profile)|comment\s+\w+\s+for\s+the\s+link|see\s+(?:bio|profile|comments)).*$/#.firstMatch(in: s) else {
            return s
        }
        let head = s[..<match.range.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? s : String(head)
    }

    /// Try to interpret `line` as a header-style metadata row (Source:,
    /// Serves:, Cook time:, Yield:, Makes:, Prep:, Bake:, Total time:).
    /// Returns true when consumed so the caller can skip it in the
    /// summary / block flow. Cookbook synonyms folded in alongside the
    /// caption-style headers so the same parser works on OCR'd printed
    /// pages.
    ///
    /// Two shapes are recognized: forward-form ("Serves: 8", "Prep: 20
    /// min") common in shared captions, and reverse-form ("8 servings",
    /// "20 min prep time") common on handwritten cards and cookbook
    /// pages. Without the reverse-form match these lines fall through
    /// into steps and pollute the instruction list.
    private static func applyHeaderField(_ line: String, lower: String, into draft: inout DraftRecipe) -> Bool {
        if let s = extractNumber(after: #"(?i)^serves?\s*:?\s*"#, in: line) {
            draft.servings = s
            return true
        }
        // Yield: 12 cookies / Yield: 1 loaf — pull the numeric prefix
        // (caller's display layer handles the trailing noun).
        if let s = extractNumber(after: #"(?i)^yields?\s*:?\s*"#, in: line) {
            draft.servings = s
            return true
        }
        // "Makes:" — colon required so a step like "Makes a great
        // brunch" doesn't trip and zero-out servings.
        if let s = extractNumber(after: #"(?i)^makes\s*:\s*"#, in: line) {
            draft.servings = s
            return true
        }
        // Reverse-form servings: "8 servings", "12 portions". The label
        // word makes this unambiguous; we deliberately don't match bare
        // dish nouns ("12 muffins") here since those collide with
        // ingredient lines that lead with a count.
        if let match = try? #/(?i)^(\d+)\s+(?:servings?|portions?|helpings?)\b/#.firstMatch(in: line) {
            draft.servings = String(match.output.1)
            return true
        }
        // Prep: / Prep time: — separate from cook time when stated.
        // Colon REQUIRED — "Prep the onions" is a valid step, and a
        // bare `^prep` match with optional colon would eat the step's
        // first number into prepTimeMinutes. Same caution applies to
        // Cook / Bake / Total / Makes below.
        if let s = extractNumber(after: #"(?i)^prep(?:\s+time)?\s*:\s*"#, in: line) {
            draft.prepTimeMinutes = s
            return true
        }
        // Reverse-form prep: "20 min prep time", "30 minutes prep".
        if let match = try? #/(?i)^(\d+)\s+min(?:ute)?s?\s+prep(?:\s+time)?\b/#.firstMatch(in: line) {
            draft.prepTimeMinutes = String(match.output.1)
            return true
        }
        if let s = extractNumber(after: #"(?i)^cook(?:\s+time)?\s*:\s*"#, in: line) {
            draft.cookTimeMinutes = s
            return true
        }
        // Bake / Bake time / Total / Total time — all map to the same
        // cook-time slot. Colon required because "Bake at 425 degrees,
        // 10 mins" is a step — without the colon guard the regex
        // matched and pulled 425 (the oven temperature) into
        // cookTimeMinutes, eating the entire step in the process.
        if let s = extractNumber(after: #"(?i)^bake(?:\s+time)?\s*:\s*"#, in: line) {
            draft.cookTimeMinutes = s
            return true
        }
        if let s = extractNumber(after: #"(?i)^total(?:\s+time)?\s*:\s*"#, in: line) {
            draft.cookTimeMinutes = s
            return true
        }
        // Reverse-form cook/bake: "10 min bake time", "45 minutes cook".
        if let match = try? #/(?i)^(\d+)\s+min(?:ute)?s?\s+(?:cook|bake|baking|total)(?:\s+time)?\b/#.firstMatch(in: line) {
            draft.cookTimeMinutes = String(match.output.1)
            return true
        }
        if lower.hasPrefix("source:") {
            draft.sourceUrl = String(line.dropFirst("source:".count))
                .trimmingCharacters(in: .whitespaces)
            return true
        }
        return false
    }

    /// True when the line has the *shape* of a metadata row — short,
    /// digit-led, no ampersand or fraction — even if the keyword on
    /// the line is mis-spelled. Used by `parseBlocks` to decide
    /// whether to invoke the lenient `applyMetadataShapeFallback`
    /// extractor on lines that escaped the strict `applyHeaderField`
    /// matcher because their keyword OCR'd wrong ("8 serugs" instead
    /// of "8 servings", "20 min piep time" instead of "prep time").
    ///
    /// Restrictions kept tight on purpose: ampersand or a vulgar
    /// fraction in the line is a strong "this is an ingredient
    /// quantity, not metadata" signal, and word count > 5 lands us
    /// well past the "8 servings" / "20 min prep time" window.
    private static func lineLooksLikeMetadataShape(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("&") || trimmed.contains("/") { return false }
        if trimmed.unicodeScalars.contains(where: { (0x00BC...0x215E).contains(Int($0.value)) }) {
            return false
        }
        let pattern = #/^\d+(?:\s+[A-Za-z]+){1,4}\s*$/#
        return (try? pattern.wholeMatch(in: trimmed)) != nil
    }

    /// Lenient metadata extractor for lines that look like metadata
    /// but whose keyword OCR'd wrong. Fired only when the entire
    /// containing block has metadata shape (small, digit-led, no
    /// fraction markers) so we don't mis-classify ingredient lines.
    ///
    /// Two patterns recognized:
    ///   - `<digit> <word>` → servings (e.g. "8 serugs", "8 servings"),
    ///     skipping any word that's a known unit ("8 cups" stays an
    ///     ingredient).
    ///   - `<digit> min(s) <word> [time]` → time annotation. Defaulted
    ///     to prepTime when the middle word doesn't lead with `c`/`b`
    ///     (cook/bake). Cookbook lines tend to use "Bake X min" rather
    ///     than reverse-form anyway, so the c/b heuristic catches the
    ///     few cases where reverse-form bake time appears.
    private static func applyMetadataShapeFallback(_ line: String, into draft: inout DraftRecipe) -> Bool {
        // <digit> min <word> [time]
        if let m = try? #/(?i)^(\d+)\s+min(?:ute)?s?\s+([a-z]+)(?:\s+time)?\s*$/#.wholeMatch(in: line) {
            let value = String(m.output.1)
            let middle = String(m.output.2).lowercased()
            if middle.hasPrefix("c") || middle.hasPrefix("b") {
                if draft.cookTimeMinutes.isEmpty { draft.cookTimeMinutes = value }
            } else {
                if draft.prepTimeMinutes.isEmpty { draft.prepTimeMinutes = value }
            }
            return true
        }
        // <digit> <word>  (servings shape; reject when the word is a
        // known unit so "8 cups" stays an ingredient)
        if let m = try? #/(?i)^(\d+)\s+([a-z]+)\s*$/#.wholeMatch(in: line) {
            let word = String(m.output.2).lowercased()
            if !knownUnits.contains(word) {
                if draft.servings.isEmpty { draft.servings = String(m.output.1) }
                return true
            }
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
        "ingredients", "steps", "instructions", "directions", "method",
        "preparation", "procedure"
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
        s = normalizeQuantityRanges(s)
        s = splitFusedNumberUnit(s)
        s = repairCollapsedMixedFractionQuantities(s)
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
            } else if discreteCountWords.contains(candidate) {
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
        return t == "+" || t == "&" || t == "and" || t == "or" || t == "plus"
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

    private static func normalizeQuantityRanges(_ s: String) -> String {
        var result = s
        result = result.replacingOccurrences(
            of: #"(?i)(\d+(?:[./]\d+)?)\s+to\s+(\d+(?:[./]\d+)?)"#,
            with: "$1-$2",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(\d+(?:[./]\d+)?)\s*[-–—]\s*(\d+(?:[./]\d+)?)"#,
            with: "$1-$2",
            options: .regularExpression
        )
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
        if byNewline.count > 1 { return recursivelySplitSteps(byNewline) }

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
            if pieces.count >= 2 { return recursivelySplitSteps(pieces) }
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
        let commaBoundaryRegex = #/,\s+(?=[Tt]hen\b|\d+(?:[./]\d+)?\s+(?!(?:tsp|tbsp|teaspoons?|tablespoons?|cups?|ounces?|oz|grams?|g|kg|ml|milliliters?|liters?|litres?|pounds?|lbs?|cloves?|pinches?|dashes?|slices?|pieces?|cans?|sticks?|sprigs?|heads?|bunches?|handfuls?|pints?|quarts?|gallons?|inches?|inch|cm|mm|ft|feet)\b))/#
        let allCommas = Array(s.matches(of: commaBoundaryRegex))

        // Filter out splits where the trailing fragment is just a
        // duration annotation ("10 mins", "30 minutes", "1 hour").
        // "Bake at 425 degrees, 10 mins" should stay as ONE step;
        // splitting on the comma would orphan the duration as a
        // standalone "10 mins" step that means nothing on its own.
        // Splits that produce a real next-instruction (with "then" or
        // multi-word content) survive the filter unchanged.
        var commas: [Regex<Substring>.Match] = []
        for (i, m) in allCommas.enumerated() {
            let nextStart: String.Index = i + 1 < allCommas.count
                ? allCommas[i + 1].range.lowerBound
                : s.endIndex
            let trailing = String(s[m.range.upperBound..<nextStart])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !isPureDuration(trailing) {
                commas.append(m)
            }
        }
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
            if pieces.count >= 2 { return recursivelySplitSteps(pieces) }
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
            if pieces.count >= 2 { return recursivelySplitSteps(pieces) }
        }

        return [s]
    }

    private static func recursivelySplitSteps(_ pieces: [String]) -> [String] {
        pieces.flatMap { splitIntoSteps($0) }
    }

    /// True when the input is *only* a duration annotation, with no
    /// other content — "10 mins", "30 minutes", "1-2 hours", "1 hr".
    /// Used by the comma-digit step splitter to keep duration tails
    /// glued to their preceding action ("Bake 425 degrees, 10 mins"
    /// is one step, not two).
    private static func isPureDuration(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: " .!?;"))
        let pattern = #/^\d+(?:\s*[-–—]\s*\d+)?\s*(?:min|mins|minute|minutes|hr|hrs|hour|hours|sec|secs|second|seconds)\s*$/#
        return (try? pattern.wholeMatch(in: trimmed)) != nil
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
            if !inside.isEmpty, parentheticalLooksActionable(inside) {
                let before = String(text[..<parens.range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let after = String(text[parens.range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                let main = joinedAfterRemovingParenthetical(before: before, after: after)
                    .trimmingCharacters(in: .whitespaces)
                guard !main.isEmpty else { return step }
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

    private static func parentheticalLooksActionable(_ text: String) -> Bool {
        (try? #/^(?i)(?:while\b|start\b|begin\b|do not\b|don't\b|dont\b|about\s+\d|after\s+\d|once\b)/#
            .firstMatch(in: text)) != nil
    }

    private static func joinedAfterRemovingParenthetical(before: String, after: String) -> String {
        let punctLeaders: Set<Character> = [".", ",", ";", ":", "!", "?", ")"]
        if !before.isEmpty,
           let firstAfter = after.first,
           punctLeaders.contains(firstAfter) {
            return before + after
        }
        return [before, after]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Capitalize the first letter without touching the rest. Used on
    /// lifted parenthetical content so `"start preheating …"` reads as
    /// `"Start preheating …"` in the special-note callout.
    private static func capitalizingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    private static func hasCookingActionOrDuration(_ text: String) -> Bool {
        if hasTimerSignal(text) { return true }
        let firstWord = text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .first
            .map(String.init) ?? ""
        return cookingActionVerbs.contains(firstWord)
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
        if (try? #/^\d+(?:[./]\d+)?-\d+(?:[./]\d+)?$/.wholeMatch(in: s)) != nil { return true }
        return false
    }

    private static let captionURLTrimCharacters =
        CharacterSet(charactersIn: ".,!?;:)]}\"'")

    private static let discreteCountWords: Set<String> = [
        "unit", "units"
    ]

    private static let bareCountFoods: Set<String> = [
        "egg", "eggs", "tomato", "tomatoes", "onion", "onions",
        "cucumber", "cucumbers", "apple", "apples", "lemon", "lemons",
        "lime", "limes", "banana", "bananas", "pepper", "peppers",
        "potato", "potatoes", "avocado", "avocados", "carrot", "carrots",
        "clove", "cloves", "stalk", "stalks", "rib", "ribs",
        "leaf", "leaves", "sprig", "sprigs", "head", "heads",
        "scallion", "scallions", "shallot", "shallots",
        "chicken", "thigh", "thighs", "breast", "breasts",
        "drumstick", "drumsticks", "fillet", "fillets",
        "steak", "steaks"
    ]

    private static let cookingActionVerbs: Set<String> = [
        "preheat", "combine", "mix", "whisk", "stir", "beat", "fold",
        "knead", "shape", "bake", "roast", "fry", "sear", "sauté",
        "saute", "simmer", "boil", "steam", "chill", "cool", "rest",
        "freeze", "melt", "heat", "pour", "spread", "drizzle",
        "sprinkle", "place", "cover", "remove", "cook", "serve",
        "cut", "slice", "chop", "mince", "dice", "brush", "dust",
        "coat", "season", "transfer", "roll", "form"
    ]

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

    private static let collapsedMixedFractionUnitPattern = [
        "cup", "cups",
        "tbsp", "tablespoon", "tablespoons",
        "tsp", "teaspoon", "teaspoons",
        "stick", "sticks",
    ].joined(separator: "|")

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
