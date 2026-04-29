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
            return sorted.compactMap { $0.topCandidates(1).first?.string }
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
        // Time phrases
        words += [
            "minutes", "minute", "hours", "hour", "seconds", "second",
            "min", "mins", "hrs", "hr",
            "Fahrenheit", "Celsius",
        ]
        // Common cookbook nouns / verbs
        words += [
            "flour","sugar","butter","salt","pepper","egg","eggs",
            "yeast","starter","sourdough","baking","powder","soda",
            "vanilla","cinnamon","oregano","basil","garlic","onion",
            "olive","oil","milk","cream","yogurt","cheese","stock",
            "broth","water","oven","skillet","saucepan","parchment",
            "paprika","cumin","turmeric","ginger","nutmeg","cilantro",
            "parsley","cardamom",
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

    /// OCR commonly mis-reads `1` as `I` or `l` in tight kerning.
    /// Naive global swap would corrupt names ("Italian" → "1talian").
    /// Constrain to *measurement contexts only* — character `[Il]`
    /// followed by `/<digit>` followed by space + known unit.
    /// Conservative on purpose; risk-of-corruption outweighs benefit
    /// outside tight unit contexts.
    private static func repairMeasurementOCR(_ s: String) -> String {
        let unitClass = "(?:cup|cups|tbsp|tsp|oz|lb|g|kg|ml|tablespoon|teaspoon|pound|ounce)"
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
