import Foundation

/// Parses a recipe out of an HTML page using schema.org JSON-LD as the
/// gold path, falling back to OpenGraph meta tags when no Recipe schema
/// is present. Pure parsing — no networking — so the URL importer can
/// stay focused on the network layer.
///
/// The JSON-LD path is the high-value one: most recipe blogs publish a
/// `Recipe` block with title, ingredients, instructions, yield, and
/// times in a stable shape. When that's missing we settle for whatever
/// the page advertises in `<meta property="og:*">` so the editor still
/// gets a head-start (title, summary).
enum RecipeSchemaParser {
    struct Result {
        var draft: DraftRecipe
        /// True only when a real schema.org/Recipe block produced
        /// ingredients OR steps — the caller treats that as a "good
        /// enough" import to send straight to the editor preview.
        var recipeFound: Bool
    }

    static func parse(html: String, sourceUrl: String) -> Result {
        var draft = DraftRecipe()
        draft.sourceUrl = sourceUrl

        if let recipe = findRecipeJSON(in: html) {
            populate(&draft, from: recipe)
            let hasContent = !draft.ingredients.isEmpty || !draft.steps.isEmpty
            return Result(draft: draft, recipeFound: hasContent)
        }

        if let title = ogContent(in: html, property: "og:title") {
            draft.title = cleanTitle(title)
        }
        if let desc = ogContent(in: html, property: "og:description") {
            draft.summary = decodeHTMLEntities(desc).trimmed
        }
        return Result(draft: draft, recipeFound: false)
    }

    // MARK: - JSON-LD discovery

    private static func findRecipeJSON(in html: String) -> [String: Any]? {
        // Match every <script type="application/ld+json">…</script> block.
        // Some pages embed several (Organization, BreadcrumbList, Recipe,
        // Article) and the Recipe might be in any of them, sometimes
        // nested under @graph or inside an array.
        let scriptPattern = #/<script[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>/#
            .ignoresCase()
            .dotMatchesNewlines()

        for match in html.matches(of: scriptPattern) {
            let raw = String(match.output.1)
                .replacingOccurrences(of: "\u{2028}", with: " ")
                .replacingOccurrences(of: "\u{2029}", with: " ")
            guard let data = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(
                    with: data, options: [.allowFragments]
                  )
            else { continue }
            if let recipe = findRecipeNode(in: parsed) {
                return recipe
            }
        }
        return nil
    }

    private static func findRecipeNode(in node: Any) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if isRecipe(dict) { return dict }
            for value in dict.values {
                if let r = findRecipeNode(in: value) { return r }
            }
        } else if let arr = node as? [Any] {
            for item in arr {
                if let r = findRecipeNode(in: item) { return r }
            }
        }
        return nil
    }

    private static func isRecipe(_ dict: [String: Any]) -> Bool {
        if let t = dict["@type"] as? String { return t == "Recipe" }
        if let arr = dict["@type"] as? [String] { return arr.contains("Recipe") }
        return false
    }

    // MARK: - Recipe → DraftRecipe

    private static func populate(_ draft: inout DraftRecipe, from recipe: [String: Any]) {
        if let name = stringValue(recipe["name"]) {
            draft.title = cleanTitle(name)
        }
        if let desc = stringValue(recipe["description"]) {
            draft.summary = decodeHTMLEntities(desc).trimmed
        }

        // Ingredients — `recipeIngredient` is current; `ingredients` is
        // the legacy spelling some sites still publish.
        let ingredientStrings = stringArray(recipe["recipeIngredient"])
            + stringArray(recipe["ingredients"])
        draft.ingredients = ingredientStrings
            .map { decodeHTMLEntities($0).trimmed }
            .filter { !$0.isEmpty }
            .flatMap { RecipeImporter.parseIngredientLine($0) }

        // Instructions — recursive because schemas nest steps inside
        // `HowToSection.itemListElement` for multi-part recipes.
        if let instr = recipe["recipeInstructions"] {
            draft.steps = extractInstructions(instr)
                .map { decodeHTMLEntities($0).trimmed }
                .filter { !$0.isEmpty }
                .compactMap { RecipeImporter.parseStepLine($0) }
        }

        if let servings = extractServings(recipe["recipeYield"]) {
            draft.servings = servings
        }

        // Prefer cookTime; fall back to totalTime so a one-pot recipe
        // that only publishes "totalTime" still seeds the field.
        if let mins = isoDurationMinutes(stringValue(recipe["cookTime"])) {
            draft.cookTimeMinutes = String(mins)
        } else if let mins = isoDurationMinutes(stringValue(recipe["totalTime"])) {
            draft.cookTimeMinutes = String(mins)
        }

        let keywordTags = extractKeywords(recipe["keywords"])
        if !keywordTags.isEmpty { draft.tags = keywordTags }
    }

    // MARK: - Field extractors

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s.isEmpty ? nil : s }
        if let arr = any as? [Any], let first = arr.first { return stringValue(first) }
        if let dict = any as? [String: Any] {
            if let s = dict["@value"] as? String { return s }
            if let s = dict["text"] as? String { return s }
            if let s = dict["name"] as? String { return s }
        }
        return nil
    }

    private static func stringArray(_ any: Any?) -> [String] {
        if let arr = any as? [String] { return arr }
        if let arr = any as? [Any] {
            return arr.compactMap { stringValue($0) }
        }
        if let s = any as? String {
            return [s]
        }
        return []
    }

    private static func extractInstructions(_ value: Any) -> [String] {
        if let s = value as? String {
            // Some sites stuff the whole method into one string with
            // newlines. Splitting here gives RecipeImporter a chance at
            // each sentence.
            return s
                .split(whereSeparator: { $0.isNewline })
                .map(String.init)
        }
        if let arr = value as? [Any] {
            return arr.flatMap { extractInstructions($0) }
        }
        if let dict = value as? [String: Any] {
            let type = (dict["@type"] as? String) ?? ""
            if type == "HowToSection", let items = dict["itemListElement"] {
                return extractInstructions(items)
            }
            if let text = dict["text"] as? String { return [text] }
            if let name = dict["name"] as? String { return [name] }
        }
        return []
    }

    private static func extractServings(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let i = value as? Int { return String(i) }
        if let d = value as? Double { return String(Int(d)) }
        if let s = value as? String {
            // "24 cookies" / "Serves 6" — pull the first integer.
            if let match = try? #/(\d+)/#.firstMatch(in: s) {
                return String(match.output.1)
            }
            return nil
        }
        if let arr = value as? [Any] {
            for item in arr {
                if let s = extractServings(item) { return s }
            }
        }
        return nil
    }

    private static func extractKeywords(_ value: Any?) -> [String] {
        if let s = value as? String {
            return s
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        }
        if let arr = value as? [String] {
            return arr
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        }
        return []
    }

    /// Parse ISO 8601 duration (the schema.org time format). `PT1H30M`
    /// → 90; `PT45M` → 45; `PT2H` → 120. Seconds are ignored — the
    /// editor stores cook time in minutes.
    static func isoDurationMinutes(_ duration: String?) -> Int? {
        guard let duration, duration.hasPrefix("PT") else { return nil }
        let body = duration.dropFirst(2)
        var hours = 0
        var minutes = 0
        var current = ""
        for ch in body {
            if ch.isNumber {
                current.append(ch)
            } else if ch == "H" {
                hours = Int(current) ?? 0
                current = ""
            } else if ch == "M" {
                minutes = Int(current) ?? 0
                current = ""
            } else if ch == "S" {
                current = ""
            }
        }
        let total = hours * 60 + minutes
        return total > 0 ? total : nil
    }

    // MARK: - OpenGraph

    private static func ogContent(in html: String, property: String) -> String? {
        // Match both attribute orderings and either property= or name=.
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            "<meta\\s+property=[\"']\(escaped)[\"']\\s+content=[\"']([^\"']+)[\"']",
            "<meta\\s+content=[\"']([^\"']+)[\"']\\s+property=[\"']\(escaped)[\"']",
            "<meta\\s+name=[\"']\(escaped)[\"']\\s+content=[\"']([^\"']+)[\"']",
            "<meta\\s+content=[\"']([^\"']+)[\"']\\s+name=[\"']\(escaped)[\"']",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, range: range),
               match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: html) {
                return String(html[r])
            }
        }
        return nil
    }

    // MARK: - String hygiene

    /// Strip trailing decorations recipes pick up on social media —
    /// hashtags, dangling emoji, quoted "Recipe:" prefixes — so the
    /// parsed title looks like a title.
    private static func cleanTitle(_ raw: String) -> String {
        var s = decodeHTMLEntities(raw).trimmed
        if let match = try? #/^(?i)recipe\s*[:\-]\s*(.+)$/#.wholeMatch(in: s) {
            s = String(match.output.1).trimmed
        }
        // Strip a trailing hashtag run ("Cookies #baking #easy" → "Cookies").
        s = s.replacing(#/(?:\s*#[\p{L}\p{N}_]+)+\s*$/#, with: "").trimmed
        return s
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        var result = s
        let named: [(String, String)] = [
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " "),
            ("&hellip;", "…"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&rsquo;", "\u{2019}"),
            ("&lsquo;", "\u{2018}"),
            ("&rdquo;", "\u{201D}"),
            ("&ldquo;", "\u{201C}"),
        ]
        for (from, to) in named {
            result = result.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
        }
        // Numeric entities: &#8217; or &#x2019;
        result = decodeNumericEntities(result)
        return result
    }

    private static func decodeNumericEntities(_ s: String) -> String {
        var output = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";") {
                let inside = s[s.index(after: i)..<semi]
                if inside.first == "#" {
                    let digits = inside.dropFirst()
                    let scalar: Unicode.Scalar?
                    if digits.first == "x" || digits.first == "X" {
                        scalar = UInt32(digits.dropFirst(), radix: 16).flatMap(Unicode.Scalar.init)
                    } else {
                        scalar = UInt32(digits, radix: 10).flatMap(Unicode.Scalar.init)
                    }
                    if let scalar {
                        output.append(Character(scalar))
                        i = s.index(after: semi)
                        continue
                    }
                }
            }
            output.append(s[i])
            i = s.index(after: i)
        }
        return output
    }
}
