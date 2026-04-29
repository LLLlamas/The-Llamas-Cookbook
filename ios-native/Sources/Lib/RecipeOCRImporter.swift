import Foundation
import Vision
import UIKit

/// Vision wrapper for the photo-import path. Takes one or more page
/// images (live document scan via VisionKit, or library picks) and
/// produces a single concatenated text blob the existing parser
/// (`RecipeAIParser.parseBestOf` → `RecipeImporter.parse`) can
/// consume.
///
/// On-device only. `VNRecognizeTextRequest` runs against the local
/// Vision framework — no network round-trip, no third-party SDKs,
/// no Required Reason API entries to declare.
///
/// **Why a cleanup pipeline rather than handing raw OCR to the
/// parser:** OCR output is noisier than caption input. Smart quotes
/// block regex matches, page numbers and chapter titles bleed in as
/// stray lines, fused section headers ("INGREDIENTS 2 cups flour…")
/// trip the labeled-format detector, and OCR confusions ("I/2 cup")
/// look like plausible content but never fire on the unit
/// recognizer. Each pass collapses one of those failure modes.
enum RecipeOCRImporter {
    /// Run text recognition on each scanned page in order, concatenate
    /// per-page outputs (newline-joined within page, double-newline
    /// between pages so the block parser sees natural section breaks),
    /// strip page headers / footers that repeat across pages, then
    /// run the unified text-cleanup pipeline (smart-quote normalize,
    /// bullet glyph normalize, page-number strip, section-header
    /// isolation, OCR confusion repair, whitespace collapse, de-
    /// hyphenate). Returns "" if Vision returned nothing — caller
    /// treats that as "ask the user to retry."
    static func recognize(_ pages: [Data]) async -> String {
        var perPage: [[String]] = []
        for data in pages {
            perPage.append(await recognizePage(data))
        }
        let cleanedPages = stripRepeatedHeaders(perPage)
        let concatenated = cleanedPages
            .map { $0.joined(separator: "\n") }
            .joined(separator: "\n\n")
        return cleanup(concatenated)
    }

    /// Run a single page through `VNRecognizeTextRequest`. Returns the
    /// recognized strings in approximate top-to-bottom reading order
    /// (Vision's bounding-box Y is bottom-up, so we sort descending).
    ///
    /// **Blank-line preservation**: Vision returns no observations for
    /// empty space between paragraphs, but the parser depends on blank
    /// lines as block separators (title vs ingredients vs steps). When
    /// the vertical gap between two consecutive observations exceeds
    /// 1.5x the median line height, we insert an empty string into the
    /// returned list — that materializes as a `\n\n` after the join in
    /// `recognize`, which `splitIntoBlocks` reads as a section break.
    /// Without this, every photo collapses to a single block and the
    /// caption-style fallback runs even on cleanly-laid-out cards.
    private static func recognizePage(_ data: Data) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            guard let cgImage = makeCGImage(from: data) else { return [] }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = supportedLanguages()
            request.customWords = customWords
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            let observations = request.results ?? []
            let sorted = observations.sorted {
                $0.boundingBox.origin.y > $1.boundingBox.origin.y
            }
            guard !sorted.isEmpty else { return [] }

            // Median observation height — robust against the occasional
            // tall-letter or low-confidence outlier. `<=` avoids the
            // off-by-one when count is even; we don't need a true median.
            let heights = sorted.map { $0.boundingBox.height }.sorted()
            let medianHeight = heights[heights.count / 2]
            let gapThreshold = medianHeight * 1.5

            var lines: [String] = []
            var prevBox: CGRect? = nil
            for obs in sorted {
                let bbox = obs.boundingBox
                if let prev = prevBox {
                    // Vision Y is bottom-up: prev (above) has higher
                    // origin.y. Vertical gap = prev.bottom - curr.top
                    // = prev.origin.y - (curr.origin.y + curr.height).
                    let gap = prev.origin.y - (bbox.origin.y + bbox.height)
                    if gap > gapThreshold {
                        lines.append("")
                    }
                }
                if let text = obs.topCandidates(1).first?.string {
                    lines.append(text)
                }
                prevBox = bbox
            }
            return lines
        }.value
    }

    private static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Locale-aware language list, intersected with what the current
    /// Vision revision actually supports. Always includes "en-US" as
    /// fallback.
    private static func supportedLanguages() -> [String] {
        let candidates: [String] = {
            var langs: [String] = []
            if let code = Locale.current.language.languageCode?.identifier {
                let region = Locale.current.region?.identifier
                let combined = region.map { "\(code)-\($0)" } ?? code
                langs.append(combined)
                if combined != code { langs.append(code) }
            }
            langs.append("en-US")
            // Order-preserving dedup via NSOrderedSet.
            return Array(NSOrderedSet(array: langs)) as? [String] ?? langs
        }()
        let request = VNRecognizeTextRequest()
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let filtered = candidates.filter { supported.contains($0) }
        return filtered.isEmpty ? ["en-US"] : filtered
    }

    /// Cooking-domain custom-words list. Biases the recognizer toward
    /// canonical units and common cookbook vocabulary so it stops
    /// misreading "tbsp" as "tbsq" and similar. Intentionally focused
    /// on words demonstrably trip Vision's confidence — a longer list
    /// produces diminishing returns past ~150 entries.
    private static let customWords: [String] = {
        var words: [String] = []
        // Section headers cookbooks use
        words += [
            "INGREDIENTS", "Ingredients",
            "DIRECTIONS", "Directions",
            "INSTRUCTIONS", "Instructions",
            "METHOD", "Method",
            "STEPS", "Steps",
            "PREPARATION", "Preparation",
            "PROCEDURE", "Procedure",
        ]
        // Units — pulled from the canonical list in RecipeImporter.
        // Plurals included so language correction doesn't fight the user.
        words += [
            "cup","cups","tbsp","tablespoon","tablespoons",
            "tsp","teaspoon","teaspoons","oz","ounce","ounces",
            "lb","lbs","pound","pounds","g","gram","grams","kg",
            "kilogram","kilograms","mg","milligram","milligrams",
            "ml","milliliter","milliliters","l","liter","liters",
            "pint","pints","quart","quarts","gallon","gallons",
            "clove","cloves","pinch","pinches","dash","dashes",
            "slice","slices","piece","pieces","can","cans",
            "stick","sticks","sprig","sprigs","head","heads",
            "bunch","bunches","handful","handfuls",
        ]
        // Time phrases + temperature
        words += [
            "minutes", "minute", "hours", "hour", "seconds", "second",
            "min", "mins", "hrs", "hr",
            "Fahrenheit", "Celsius", "degrees", "degree",
        ]
        // Yield / serving vocabulary — without these, Vision misreads
        // handwritten "servings" as "serugs" / "serungs" and the
        // metadata extractor never fires. Same for "prep" → "piep".
        words += [
            "servings", "serving", "serves",
            "portions", "portion",
            "helpings", "helping",
            "yield", "yields", "makes",
            "prep", "preparation",
        ]
        // Common cookbook nouns / verbs (incl. equipment + actions
        // that recur in step text — "bowl" was missing and Vision
        // came back with "boul" as a result).
        words += [
            "flour","sugar","butter","salt","pepper","egg","eggs",
            "yeast","starter","sourdough","baking","powder","soda",
            "vanilla","cinnamon","oregano","basil","garlic","onion",
            "olive","oil","milk","cream","yogurt","cheese","stock",
            "broth","water","oven","skillet","saucepan","parchment",
            "paprika","cumin","turmeric","ginger","nutmeg","cilantro",
            "parsley","cardamom","chocolate","chips",
            "bowl","bowls","pan","pans","sheet","tray","whisk",
            "spatula","mixer","blender","preheat","preheated",
        ]
        // Dish names — cookbooks and handwritten cards put the dish at
        // the top of the page, and small / curly type lets Vision drop
        // the trailing `n` ("Muffins" → "Muffies"). Biasing the
        // recognizer toward these whole words is cheaper than a
        // post-OCR repair for every variant misread.
        words += [
            "Muffin","Muffins","Pancake","Pancakes","Waffle","Waffles",
            "Cookie","Cookies","Brownie","Brownies","Biscuit","Biscuits",
            "Scone","Scones","Cupcake","Cupcakes","Cake","Cakes",
            "Bread","Loaf","Loaves","Roll","Rolls","Bun","Buns",
            "Pie","Pies","Tart","Tarts","Donut","Donuts","Doughnut",
            "Doughnuts","Bagel","Bagels","Pretzel","Pretzels",
            "Croissant","Croissants","Pastry","Pastries","Crepe","Crepes",
            "Pizza","Pasta","Risotto","Soup","Stew","Salad","Sandwich",
            "Burger","Taco","Tacos","Burrito","Burritos","Quesadilla",
            "Enchilada","Enchiladas","Casserole","Curry","Stir-fry",
        ]
        words += [
            "Preheat","Combine","Knead","Refrigerate","Bake","Roast",
            "Simmer","Boil","Whisk","Stir","Beat","Fold","Pour",
            "Drizzle","Sprinkle","Place","Remove","Cover","Heat",
            "Cool","Toast","Sear","Reduce","Bring","Allow","Cook",
            "Cut","Chop","Slice","Dice","Mince","Brush","Season",
            "Transfer","Roll","Form","Shape","Stretch",
        ]
        return words
    }()

    // MARK: - Cleanup pipeline

    /// Run the OCR text through every cleanup pass in dependency order.
    /// Each pass collapses a known failure mode of the downstream
    /// parser. Order matters — earlier passes prepare the text for
    /// later regex matching.
    private static func cleanup(_ raw: String) -> String {
        var s = raw
        s = normalizeSmartQuotes(s)
        s = normalizeBullets(s)
        s = stripPageNumbers(s)
        s = isolateSectionHeaders(s)
        s = repairMeasurementOCR(s)
        s = repairHandwritingMisreads(s)
        s = collapseWhitespace(s)
        s = deHyphenate(s)
        return s
    }

    /// Smart quotes are common in cookbook printing. `’` (U+2019)
    /// blocks regex matches that expect `'` (don't, possessives).
    /// `“` `”` similarly. One-shot replacement.
    private static func normalizeSmartQuotes(_ s: String) -> String {
        var out = s
        for (from, to) in [
            ("\u{2018}", "'"), ("\u{2019}", "'"),
            ("\u{201C}", "\""), ("\u{201D}", "\""),
            ("\u{2032}", "'"), ("\u{2033}", "\""),
        ] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
    }

    /// Cookbooks use ●, ▪, ◦, ▸, ▫, ▶ as ingredient bullets. Vision
    /// recognizes them as text. The downstream `stripLeadingBullet`
    /// only handles `• - * – —`, so pre-normalize the family of
    /// glyphs that show up on printed pages to plain `•` here.
    private static func normalizeBullets(_ s: String) -> String {
        var out = s
        for glyph in ["●", "■", "▪", "◦", "▸", "▶", "▫", "◆", "◇", "▼", "▽", "★", "☆"] {
            out = out.replacingOccurrences(of: glyph, with: "•")
        }
        return out
    }

    /// Drop lines that are exclusively 1-3 digits (common at top/
    /// bottom of cookbook pages), `Page \d+`, or `\d+ of \d+`. Bare
    /// page-number lines are noise the section parser would otherwise
    /// classify as a stub step.
    private static func stripPageNumbers(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return true }
            // Pure 1-3 digit line.
            if (try? #/^\d{1,3}$/#.wholeMatch(in: trimmed)) != nil { return false }
            // "Page 4" / "page 4"
            if (try? #/^(?i)page\s+\d{1,3}$/#.wholeMatch(in: trimmed)) != nil { return false }
            // "4 of 12"
            if (try? #/^\d{1,3}\s+of\s+\d{1,3}$/#.wholeMatch(in: trimmed)) != nil { return false }
            return true
        }
        return kept.joined(separator: "\n")
    }

    /// When OCR returns "INGREDIENTS 2 cups flour…" as a single line
    /// (the headline rendered close to the body), the labeled-format
    /// parser fails because it expects "Ingredients" on its own line.
    /// Insert a newline after the recognized header word when it's
    /// followed by content on the same line.
    private static func isolateSectionHeaders(_ s: String) -> String {
        var out = s
        let headers = [
            "INGREDIENTS", "Ingredients",
            "DIRECTIONS", "Directions",
            "INSTRUCTIONS", "Instructions",
            "METHOD", "Method",
            "STEPS", "Steps",
            "PREPARATION", "Preparation",
            "PROCEDURE", "Procedure",
        ]
        for h in headers {
            let pattern = "(?m)^(\(h))\\s*[:.\\-]?\\s+(?=\\S)"
            out = out.replacingOccurrences(
                of: pattern,
                with: "$1\n",
                options: .regularExpression
            )
        }
        return out
    }

    /// OCR commonly mis-reads `1` as `I` or `l` in tight kerning, `&`
    /// as `%` (or as a stray vulgar-fraction glyph) when handwritten,
    /// and `0` as `o` when the digit is drawn open at the top. Naive
    /// global swap would corrupt names ("Italian" → "1talian", a step
    /// like "5% milk", "log of cinnamon"). Constrain each repair to
    /// *measurement contexts only* — leading digit + the misread glyph
    /// + a fraction or unit suffix. Conservative on purpose; risk-of-
    /// corruption outweighs benefit outside tight unit contexts.
    private static func repairMeasurementOCR(_ s: String) -> String {
        let unitClass = "(?:cup|cups|tbsp|tsp|oz|lb|g|kg|ml|tablespoon|teaspoon|pound|ounce|gram|grams)"
        var out = s
        // "I/2 cup" / "l/2 cup" → "1/2 cup"
        out = out.replacingOccurrences(
            of: "\\b[Il]/(\\d)\\s+(\(unitClass))\\b",
            with: "1/$1 $2",
            options: .regularExpression
        )
        // "1/I cup" / "1/l cup" → "1/1 cup" — rare, but symmetrical.
        out = out.replacingOccurrences(
            of: "\\b(\\d)/[Il]\\s+(\(unitClass))\\b",
            with: "$1/1 $2",
            options: .regularExpression
        )
        // "I cup of flour" / "l cup of flour" → "1 cup of flour".
        // Bare-letter mis-reads where the kerning ate the `1`'s serif.
        // Scoped via lookahead to a known unit so step text like
        // "Lay flat" or "Italian seasoning" stays untouched.
        out = out.replacingOccurrences(
            of: "\\b[Il](?=\\s+\(unitClass)\\b)",
            with: "1",
            options: .regularExpression
        )
        // "1og chocolate chips" → "10g chocolate chips". Open-top `0`
        // mis-read as `o` when handwritten — only ever ambiguous when
        // wedged between a digit and a unit letter, so the pattern
        // anchors with a digit lookbehind and a whitespace/end
        // lookahead. Without this fix, every "10g" / "20g" / "100g"
        // handwritten ingredient line falls out of the ingredient
        // classifier. Lookbehind-only replacement avoids the `$10`
        // capture-group ambiguity NSRegularExpression replacements
        // would otherwise hit.
        out = out.replacingOccurrences(
            of: "(?<=\\d)og(?=\\s|$)",
            with: "0g",
            options: .regularExpression
        )
        // "1%1/2 cup" → "1 & 1/2 cup". Handwritten `&` regularly comes
        // back from Vision as `%` because the lobes line up. Scoped to
        // <digit>%<digit>/<digit> followed (with any spacing) by a
        // known unit so legitimate uses of `%` (a step calling for 5%
        // milk) survive untouched.
        out = out.replacingOccurrences(
            of: "(\\d)\\s*%\\s*(\\d)/(\\d)\\s+(\(unitClass))\\b",
            with: "$1 & $2/$3 $4",
            options: .regularExpression
        )
        // "1⅙½ cup" / "1⅛½ cup" / "1¼½ cup" → "1 & ½ cup". Handwritten
        // `&` next to a vulgar fraction (e.g. "1 & ½") routinely
        // misreads as a stray vulgar-fraction glyph from Vision —
        // observed: ⅙, ⅛, ¼, ⅜. Two adjacent vulgar fractions never
        // make sense in a real recipe quantity, so the second
        // fraction is the legitimate one and the first is a misread
        // `&`. Drop the first, keep the second, insert the explicit
        // `& ` separator the parser expects. Scoped to a unit suffix
        // to avoid corrupting any step text that mentions the glyph.
        // Replacement uses literal-space separators rather than back-
        // to-back `$N` references to avoid NSRegularExpression's
        // greedy `$23` parsing ambiguity.
        out = out.replacingOccurrences(
            of: "(\\d)[\u{00BC}-\u{215E}]([\u{00BC}-\u{215E}])\\s*(\(unitClass))\\b",
            with: "$1 & $2 $3",
            options: .regularExpression
        )
        // "1%½ cup" — same misread shape but with `%` for the misread
        // glyph (lobes line up with handwritten `&`). Existing rule
        // earlier handled `\d%\d/\d` — the vulgar-fraction trailing
        // shape was missed. Drop the `%`, keep the vulgar fraction.
        out = out.replacingOccurrences(
            of: "(\\d)\\s*%\\s*([\u{00BC}-\u{215E}])\\s*(\(unitClass))\\b",
            with: "$1 & $2 $3",
            options: .regularExpression
        )
        // "14 1/2 cup" / "13 1/2 cup" / "19 1/2 cup" → "1 1/2 cup".
        // When a handwritten "1" gets a small upward stroke, Vision
        // routinely reads it as "14" (or some other 1X digit pair).
        // Real recipes essentially never call for 10-19 cups of a
        // single ingredient — that would be 2-5 liters, far past the
        // single-cup-tier quantities that "1/2 cup" sits next to.
        // Scoped to a `1` tens-digit + `\d` ones-digit + ` 1/2 ` +
        // `cup`/`cups` to limit the corruption blast radius. Won't
        // fire on legitimate "5 1/2 cup" or "1 1/2 cup".
        out = out.replacingOccurrences(
            of: "(?<!\\d)1\\d\\s+1/2\\s+(cups?)\\b",
            with: "1 1/2 $1",
            options: .regularExpression
        )
        // "1' 1/2 cup" → "1 1/2 cup". Handwritten "1½" frequently
        // arrives from Vision as "1'" + "1/2" — the small ½ glyph
        // gets decomposed into an apostrophe-shaped misread (the
        // narrow vertical of `½`'s `1` reads as `'`) and a `1/2`.
        // Without this fix, `hoistInlineMeasurement` correctly grabs
        // `1/2 cup` as the measurement but leaves the `1'` stranded
        // in the ingredient name ("1' water"). Scoped via lookahead
        // to a fraction-then-unit shape to avoid corrupting
        // legitimate dimensional uses ("1' diameter pan"), which are
        // rare in recipe text but worth not breaking.
        out = out.replacingOccurrences(
            of: "(\\d)'(?=\\s+(?:\\d/\\d|[\u{00BC}-\u{215E}])\\s+\(unitClass)\\b)",
            with: "$1",
            options: .regularExpression
        )
        // "4a5 degrees" / "1l0 mins" / "2o0 g" — digit-letter-digit
        // shapes where the middle character is a Vision misread of a
        // digit. Specifically: handwritten `2` with an open-top loop
        // reads as `a`; `0` reads as `o`/`O`; `1` reads as `l`/`I`.
        // Constrained to letter-wedged-between-digits via lookbehind
        // and lookahead so step text mentioning real letters stays
        // untouched ("preheat to 350" has digits before/after but no
        // letter between them). Order matters: the more aggressive
        // `a` → `2` runs last so the safer corrections land first.
        out = out.replacingOccurrences(
            of: "(?<=\\d)[oO](?=\\d)",
            with: "0",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?<=\\d)[lI](?=\\d)",
            with: "1",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?<=\\d)a(?=\\d)",
            with: "2",
            options: .regularExpression
        )
        return out
    }

    /// Targeted repairs for OCR misreads of handwritten *words* that
    /// `customWords` biasing alone hasn't been enough to prevent.
    /// Listed only when observed in real test runs and when the
    /// misread token has no plausible recipe-context meaning of its
    /// own — that's what makes unconditional replacement safe.
    private static func repairHandwritingMisreads(_ s: String) -> String {
        var out = s
        // "Mix in a bow!" → "Mix in a bowl". Lowercase `l` in
        // handwriting is a vertical stroke that Vision regularly
        // mis-classifies as `!`. "bow!" as an exclamation in cooking
        // text would be unusual; "bowl" is the only plausible
        // intended word, so unconditional replacement is safe.
        out = out.replacingOccurrences(
            of: "\\bbow!",
            with: "bowl",
            options: .regularExpression
        )
        return out
    }

    /// Multi-space runs collapse to a single space; multiple blank
    /// lines collapse to a single blank line so the block-format
    /// parser sees clean separators between title / ingredients /
    /// steps blocks.
    private static func collapseWhitespace(_ s: String) -> String {
        var out = s
        // Collapse runs of horizontal whitespace inside lines.
        out = out.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        // Collapse runs of 3+ newlines to exactly two (block separator).
        out = out.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return out
    }

    /// "ingre-\nients" → "ingredients". OCR's most common artifact on
    /// printed cookbook pages, where right-edge hyphenation breaks
    /// across lines. Conservative pattern: lowercase letter, hyphen,
    /// newline, lowercase letter — collapses to the two letters.
    /// Skip cases where the post-newline letter is uppercase (likely
    /// a new sentence) so we don't accidentally fuse step boundaries.
    private static func deHyphenate(_ s: String) -> String {
        s.replacingOccurrences(
            of: #"([a-z])-\n([a-z])"#,
            with: "$1$2",
            options: .regularExpression
        )
    }

    /// Drop short lines that appear identically across multiple pages
    /// — running headers, page numbers, "Chapter 4" decorations.
    /// Only fires for multi-page inputs; single-page scans pass
    /// through unchanged. Threshold: line ≤ 24 chars (chapter titles,
    /// page numbers, recipe name in header) AND appears in ≥ 2 pages.
    private static func stripRepeatedHeaders(_ pages: [[String]]) -> [[String]] {
        guard pages.count >= 2 else { return pages }
        var counts: [String: Int] = [:]
        for page in pages {
            let unique = Set(page.filter { $0.count <= 24 })
            for line in unique {
                counts[line, default: 0] += 1
            }
        }
        let dropSet = Set(counts.filter { $0.value >= 2 }.keys)
        guard !dropSet.isEmpty else { return pages }
        return pages.map { page in page.filter { !dropSet.contains($0) } }
    }
}
