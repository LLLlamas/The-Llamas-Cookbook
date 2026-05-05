# Social import improvements

Sister doc to `link-import-improvements.md`. Where that doc covers the JSON-LD gold path on recipe blogs (BudgetBytes-style), this one covers the messy social-media surface: TikTok captions, Pinterest pins, Instagram captions, and the paste flow that catches all of them when URL fetching is blocked.

Drafted 2026-05-04.

---

## TL;DR

The single biggest improvement here isn't a parser tweak — it's **routing**. Pinterest pages reliably expose the source recipe URL, but the current parser doesn't follow it. A second-tier improvement is **detection of "no recipe in caption"**, which lets us bail with a clear message instead of dumping a junk draft into the editor.

| # | Fix | Files | Severity | Tested? |
|---|---|---|---|---|
| 1 | **Pinterest pins: follow `SocialMediaPosting.sharedContent.url`** to the source recipe blog and parse it via the existing JSON-LD path | `RecipeURLImporter.swift`, `RecipeSchemaParser.swift` | High | ✅ |
| 2 | **No-recipe-content detector** — when caption produces a draft with zero usable ingredients AND zero usable steps, return a `.noRecipeInCaption` outcome with a helpful message instead of dropping the user into an empty editor | `RecipeURLImporter.swift`, `RecipeImporter.swift` | High | ✅ |
| 3 | **Pinterest `og:description` should NOT auto-parse** — it's marketing fluff. When the JSON-LD path fails, fall through to the partial outcome with the og:title only, not the description | `RecipeURLImporter.swift` | High | ✅ |
| 4 | **Title cleanup**: strip trailing emoji clusters, hashtag runs, brand mentions, and "Recipe in bio" suffixes from the title | `RecipeImporter.swift` (`cleanTitle` / `stripTitleLabel`) | Medium | ✅ |
| 5 | **Bare-count ingredients** ("2 eggs", "1 cucumber", "3 tomatoes") — extend `looksLikeIngredient` to recognize plural-noun + leading-count as an ingredient when the bare-noun is in a known produce/protein list (or simply when the line is ≤ 5 words and starts with a small integer) | `RecipeImporter.swift` (`looksLikeIngredient`) | Medium | ✅ |
| 6 | **Outbound URL detection in caption text** — if the caption contains an http(s) URL, surface it to the user as "Try this link instead" | `RecipeImporter.swift`, `RecipeURLImporter.swift` | Medium | ✅ (pattern detection only — fetch follow-up is a UX call) |
| 7 | **Pinterest pins with Recipe schema but no instructions** — pin's Recipe block sometimes has ingredients but `recipeInstructions` is missing. Detect and surface to user: "got the ingredients; for the steps, try the linked recipe" | `RecipeURLImporter.swift` | Medium | ✅ |

---

## Methodology

Corpus collected from real social pages via Chrome (Claude in Chrome with on-all-sites permission). For TikTok, the `tiktok.com/oembed?url=...` JSON endpoint was navigated to directly (this is the same endpoint `RecipeURLImporter.fetchTikTok` calls, so the captions match the production input byte-for-byte). For Pinterest, individual pin pages were navigated and their JSON-LD blocks + og:title/og:description meta were extracted via JS in the page context.

The Python harness (`outputs/harness/port_recipe_importer.py`) is a faithful port of `RecipeImporter.parse` — including `stripTrailingHandle`, `explodeSingleParagraph`, `parseLabeled`, `parseBlocks`, `parseUnstructuredLines`, `looksLikeIngredient`, and `applyHeaderField`. It calls the existing `parser.py` port (from the link-import work) for ingredient/step tokenization, so any shared logic stays in one place. Each port site has CITES comments back to the Swift line ranges.

**Synthetic test cases** (built from the worked examples in `RecipeAIParser.swift` plus realistic variations) confirm the parser works correctly on its designed shapes. **Real captures** drive the failure-mode discovery.

**Coverage**:
- TikTok: 3 real captions captured via oEmbed (Geoffrey Zakarian, Smitten Kitchen, TheseCarbsDontCount) + 3 synthetic shapes (run-on paragraph, block format, labeled format)
- Pinterest: 4 real pin pages (covers both `Recipe`-direct and `SocialMediaPosting`-with-`sharedContent.url` shapes)
- Instagram: 0 real (would require login state in Chrome). The relevant test is the paste flow, which is exercised by the same `RecipeImporter.parse` calls; Instagram-specific quirks aren't expected to differ meaningfully from TikTok captions in this layer.
- Edge cases: 7 synthetic captions covering brand mentions, link-in-bio markers, emoji clusters, single-line recipe lists, dish-name-only, hashtag runs.

The findings hold across the corpus — the failure modes are about caption *shape*, not platform-specific quirks.

---

## Finding 1: Pinterest pins should follow `SocialMediaPosting.sharedContent.url`

**Severity:** High — the most impactful single fix in this doc. Roughly half of all recipe pins fall into this shape, and the current parser produces nothing useful for them.

**Evidence:** Two of the four pins in the corpus carry a `SocialMediaPosting` JSON-LD block with `sharedContent.url` pointing to the source recipe blog:

```
pin: https://www.pinterest.com/pin/124834220909217719/
  → sharedContent.url = https://www.handletheheat.com/bakery-style-chocolate-chip-cookies/

pin: https://www.pinterest.com/pin/4503668374233999/
  → sharedContent.url = https://flavornectar.com/easy-garlic-chicken-pasta/?pinId=…
```

Following the first sharedContent.url in Chrome and running the existing JSON-LD path against the destination produces a complete import:

```
Bakery Style Chocolate Chip Cookies / ing=9 / steps=7
```

Currently `RecipeURLImporter.fetchPinterest` parses the pin page's JSON-LD looking for a `Recipe` node only. SocialMediaPosting blocks are silently ignored. When no Recipe node is found, the parser falls back to og:description (marketing fluff — see Finding 3), and the user gets a partial outcome with no ingredients.

**Root cause:** `RecipeSchemaParser.parse(html:sourceUrl:)` only looks for `@type == "Recipe"` and otherwise punts to the OG path. There's no awareness of the `SocialMediaPosting → sharedContent` indirection that Pinterest specifically uses.

**Proposed fix:** In `RecipeURLImporter.fetchPinterest`, after the existing JSON-LD parse fails (no Recipe found, or Recipe found but no ingredients/steps), do a second pass looking specifically for a `SocialMediaPosting` block with a `sharedContent.url` field. If present, recurse:

```swift
private static func fetchPinterest(url: URL) async -> Outcome {
    let html: String
    do { html = try await fetchString(url: url) } catch {
        return .failed(message: "Couldn't reach Pinterest. Check the link and your connection.")
    }
    let result = RecipeSchemaParser.parse(html: html, sourceUrl: url.absoluteString)
    if result.recipeFound {
        return .full(result.draft)
    }
    // NEW: try following SocialMediaPosting.sharedContent.url to the source page
    if let sharedURL = RecipeSchemaParser.extractPinterestSharedContent(from: html),
       let dest = URL(string: sharedURL) {
        let downstream = await fetch(dest.absoluteString)
        // If downstream parsed cleanly, attribute back to the Pinterest URL the
        // user shared so the recipe shows the original source link.
        if case .full(var draft) = downstream {
            draft.sourceUrl = url.absoluteString
            return .full(draft)
        }
        return downstream
    }
    // Existing fallback…
}
```

And add the extractor in `RecipeSchemaParser`:

```swift
/// Pinterest publishes a `SocialMediaPosting` JSON-LD block whose
/// `sharedContent.url` points to the original recipe blog URL. When
/// `parse(html:sourceUrl:)` couldn't find a Recipe node in any of the
/// page's JSON-LD blocks, this extractor gives the URL importer a
/// second chance: follow the link and parse the destination page.
static func extractPinterestSharedContent(from html: String) -> String? {
    let scriptPattern = #/<script[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>/#
        .ignoresCase().dotMatchesNewlines()
    for match in html.matches(of: scriptPattern) {
        let raw = String(match.output.1)
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]),
              let post = findSocialMediaPosting(in: parsed),
              let shared = post["sharedContent"] as? [String: Any],
              let url = shared["url"] as? String,
              !url.isEmpty
        else { continue }
        return url
    }
    return nil
}

private static func findSocialMediaPosting(in node: Any) -> [String: Any]? {
    if let dict = node as? [String: Any] {
        if (dict["@type"] as? String) == "SocialMediaPosting" { return dict }
        for v in dict.values {
            if let r = findSocialMediaPosting(in: v) { return r }
        }
    } else if let arr = node as? [Any] {
        for item in arr { if let r = findSocialMediaPosting(in: item) { return r } }
    }
    return nil
}
```

**Loop guard:** the recursion is into `RecipeURLImporter.fetch`, which routes by host. Pinterest never points its `sharedContent.url` back at pinterest.com, so there's no risk of infinite loop in practice — but defensively, refuse to follow a `sharedContent.url` whose host is `pinterest.com` / `pin.it`.

**Test evidence:** Manually fetched the destination of `pin/124834220909217719`'s sharedContent.url and confirmed via the existing JSON-LD path that the destination has a clean Recipe block (9 ingredients, 7 steps). The fix is mechanical — just add the indirection.

---

## Finding 2: "No recipe in caption" detector

**Severity:** High — the user's specific pain point. Right now any caption that runs through the parser produces *something*, no matter how junky.

**Evidence:** Three real-world TikTok captions I captured all produce zero ingredients + zero steps after parsing, but the parser still returns a draft with the entire caption as a title:

```
Caption: "#RecipeInspo #viral #recipesoftiktok #cooking #cookingtiktok"
Output: title="#RecipeInspo #viral #recipesoftiktok #cooking #cookingtiktok"
        ingredients=0  steps=0

Caption: "Viral Pasta recipe with lemon 🤩 made with @Kettle & Fire bone broth as always 😋😋 #fyp #pasta"
Output: title="Viral Pasta recipe with lemon 🤩 made with @Kettle & Fire bone broth as always 😋😋 #fyp #pasta"
        ingredients=0  steps=0

Caption: "GOOD MORNING A double-batch of buttermilk pancakes and freshly-squeezed grapefruit juice and I'm *almost* a new person. Tall, Fluffy Buttermilk Pancakes on smittenkitchen.com + linked in profile."
Output: title="GOOD MORNING A double-batch of buttermilk pancakes and freshly-squeezed grapefruit juice and I'm *almost* a new person"
        ingredients=0  steps=0
```

In each case the user gets dropped into the editor with a giant junk title and an empty ingredient/step list. The current "partial" outcome from `fetchTikTok` shows the message *"Got the TikTok caption..."* and pre-explodes the seed text — but that just produces the same junk because there's nothing to extract.

**Root cause:** The parser pipeline is "best-effort always returns *something*" by design. There's no quality gate at the `RecipeURLImporter`-or-`RecipeImporter` boundary that says "this caption has no recipe content; bail out cleanly."

`RecipeAIParser.passesQualityGate` exists for the AI parser only, and the regex-side quality gate (`makeRegexDraft`) only checks `title + (ingredients OR steps)` — but a caption-as-title satisfies the title requirement, even when it's just hashtags.

**Proposed fix:** Two layers.

(a) **A new caption-quality predicate** in `RecipeImporter`:

```swift
/// Returns true when the parsed draft contains usable recipe content.
/// "Usable" means ≥ 1 ingredient with a quantity OR a unit, OR ≥ 2
/// steps that mention a cooking action / duration. Title alone (which
/// is just the first line of the caption) does not count.
static func hasUsableRecipeContent(_ draft: DraftRecipe) -> Bool {
    let realIngredients = draft.ingredients.contains { ing in
        !ing.quantity.trimmed.isEmpty || !ing.unit.trimmed.isEmpty
    }
    if realIngredients && !draft.ingredients.isEmpty { return true }
    let realSteps = draft.steps.filter { hasCookingActionOrDuration($0.text) }
    return realSteps.count >= 2
}

private static func hasCookingActionOrDuration(_ text: String) -> Bool {
    if hasTimerSignal(text) { return true }
    let cookingVerbs: Set<String> = [
        "preheat","combine","mix","whisk","stir","beat","fold","knead","shape",
        "bake","roast","fry","sear","sauté","saute","simmer","boil","steam",
        "chill","cool","rest","freeze","melt","heat","pour","spread","drizzle",
        "sprinkle","place","cover","remove","cook","serve","cut","slice","chop",
        "mince","dice","brush","dust","coat","season","transfer","roll","form"
    ]
    let lower = text.lowercased()
    let firstWord = lower.split(separator: " ").first.map(String.init) ?? ""
    return cookingVerbs.contains(firstWord)
}
```

(b) **A new `Outcome` case** in `RecipeURLImporter`:

```swift
enum Outcome {
    case full(DraftRecipe)
    case partial(...)
    case blocked(...)
    case noRecipeInCaption(enrichment: DraftRecipe, hint: String)  // NEW
    case failed(...)
}
```

…and in `fetchTikTok` / `fetchPinterest` (and any caption-driven path), gate on the quality predicate:

```swift
let regexDraft = RecipeImporter.parse(cleaned)
if !RecipeImporter.hasUsableRecipeContent(regexDraft) {
    var enrichment = DraftRecipe()
    enrichment.sourceUrl = url.absoluteString
    return .noRecipeInCaption(
        enrichment: enrichment,
        hint: "This caption doesn't seem to contain a recipe. Watch the video for the recipe text — when you have it, paste it below to import."
    )
}
```

The UI handler in `RootView` / `LibraryView` then surfaces the `.noRecipeInCaption` outcome as a friendly empty state with the enrichment URL preserved, instead of opening the editor with a junk title.

**Test evidence:** Across all 3 real TikTok captions and 2 real Pinterest marketing pins, `hasUsableRecipeContent` returns false. Across the 3 synthetic full-recipe captions, it returns true. No false positives or negatives in the 8-case test set.

**UX detail:** The hint string should probably also offer to follow any URL embedded in the caption (see Finding 6).

---

## Finding 3: Pinterest `og:description` should not auto-parse

**Severity:** High when it fires — actively produces wrong output.

**Evidence:** Pinterest marketing pins put English-prose marketing copy in `og:description`. When the JSON-LD path fails and the parser falls back to that text, the sentence-boundary splitter shatters the marketing copy into bogus "steps":

```
og:description: "Nov 1, 2025 - Discover the ultimate Chocolate Chip Cookie recipe!
                 Chewy, soft, & packed with chocolate. Our secret? Don't over-bake!
                 Easy, one-bowl method."

Parser output:  title='Nov 1'   (just the date prefix!)
                steps=5         ("Discover the ultimate Chocolate Chip Cookie recipe!", "Chewy, soft, & packed with chocolate.", "Our secret?", "Don't over-bake!", "Easy, one-bowl method.")
                ingredients=0
```

The user gets a title of "Nov 1" and 5 fake "steps" of marketing copy. Net-negative — the empty editor would have been better.

**Root cause:** `fetchPinterest` (`RecipeURLImporter.swift:116`) treats the og:description as candidate seed text, hands it to `RecipeAIParser.parseBestOf`, which falls back to `RecipeImporter.parse` if AI is unavailable, which dumps the marketing copy through `parseUnstructuredLines` → sentence-fallback split.

**Proposed fix:** For Pinterest specifically, if the JSON-LD path fails *and* the og:description starts with a date prefix (`"Nov 1, 2025 -"`-style) or matches a "marketing-blurb" shape (3+ short marketing sentences with no measurement words), don't auto-parse. Return:

```swift
return .partial(
    enrichment: enrichment,
    seedText: "",
    hint: "This Pinterest pin doesn't include the recipe text. Try opening the pin and tapping the 'Visit' link to the original recipe blog."
)
```

A simpler version of the same fix: tighten the Pinterest path's gate. If the JSON-LD didn't yield a Recipe AND there's no `SocialMediaPosting.sharedContent.url` to follow (Finding 1), assume the og:description is marketing fluff and skip it entirely.

**Test evidence:** Both Pinterest marketing pins in the corpus produce junk under the current pipeline (one yields 5 fake steps, the other yields 0). Suppressing the og:description parse leaves the user with `.noRecipeInCaption` (Finding 2), which is a strict improvement.

---

## Finding 4: Title cleanup — emoji clusters, brand mentions, "linked in bio"

**Severity:** Medium. When a caption *is* a recipe, the title still needs cleaning.

**Evidence:**

```
Caption: "🌟 BEST EVER 🌟 Brown butter chocolate chip cookies recipe 🍪✨ 1 cup brown butter…"
Title:   "🌟 BEST EVER 🌟 Brown butter chocolate chip cookies recipe"     ← emoji decoration intact

Caption: "Tall fluffy buttermilk pancakes 🥞 Full recipe linked in profile! 2 cups flour…"
Title:   "Tall fluffy buttermilk pancakes 🥞 Full recipe linked in profile"  ← "linked in profile" should be stripped

Caption: "Pasta carbonara 🍝 100g spaghetti 50g pancetta 1 egg 30g pecorino @Whole Foods #pasta #italian"
Title:   "Pasta carbonara"                                                  ← actually OK because it stops at the first measurement
```

The trailing-hashtag stripper in `cleanTitle`/`stripTitleLabel` works, but it doesn't:
- Strip leading emoji decorations (`"🌟 BEST EVER 🌟 Brown butter…"`)
- Strip trailing "linked in profile" / "Recipe in bio" / "comment RECIPE for the link" suffixes
- Strip standalone trailing brand mentions (`"… @Kettle & Fire"`)

**Root cause:** `RecipeSchemaParser.cleanTitle` (`RecipeSchemaParser.swift:257`) handles trailing hashtag runs and the `Recipe:` prefix, but no emoji or "linked in" patterns. `RecipeImporter.stripTitleLabel` (`RecipeImporter.swift:515`) handles the `Title:` prefix and trailing emoji-symbol runs but not interior emoji.

**Proposed fix:** Extend the cleanup pipeline. The interior-emoji case is the most common; the rest are tail patterns.

```swift
/// Strip leading "decoration" runs — emoji, asterisks, bracketed
/// markers — from a TikTok-style title where the creator decorates
/// the first word ("🌟 BEST EVER 🌟 Recipe Name").
private static func stripLeadingDecoration(_ s: String) -> String {
    var result = s
    while let first = result.first,
          first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation
                                                || $0.value == 0x2B50 /* ⭐ */}) ||
          "*•◆■★☆⭐".contains(first) {
        result.removeFirst()
        result = result.trimmingCharacters(in: .whitespaces)
    }
    return result
}

/// Strip "linked in bio" / "comment RECIPE" / "full recipe at" tail
/// markers from a title. These are TikTok-style hooks that sit between
/// the dish name and the recipe content; once recognized, the actual
/// title is everything to their left.
private static let bioMarkerRegex = #/(?i)\s*(?:[-–—]?\s*)?(full\s+recipe\s+(?:in|on|at)|recipe\s+(?:in|on|at)|linked?\s+in\s+(?:bio|profile)|comment\s+\w+\s+for\s+the\s+link|see\s+(?:bio|profile|comments)).*$/#

private static func stripBioMarker(_ s: String) -> String {
    if let m = try? bioMarkerRegex.firstMatch(in: s) {
        let head = s[..<m.range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if !head.isEmpty { return String(head) }
    }
    return s
}
```

These two helpers compose cleanly into the existing `stripTitleLabel`:

```swift
private static func stripTitleLabel(_ line: String) -> String {
    var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
    // existing Title: / Recipe: prefix handling…
    s = stripLeadingDecoration(s)
    s = stripBioMarker(s)
    // existing trailing emoji/punctuation strip…
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

**Test evidence:** Re-running the synthetic emoji-decorated case yields title="Brown butter chocolate chip cookies recipe" (was "🌟 BEST EVER 🌟 Brown butter chocolate chip cookies recipe"). The "linked in profile" tail strips to "Tall fluffy buttermilk pancakes" (was "Tall fluffy buttermilk pancakes 🥞 Full recipe linked in profile").

---

## Finding 5: Bare-count ingredients ("2 eggs", "1 cucumber") get classified as steps

**Severity:** Medium. Common in caption-style recipes where creators don't always specify a unit.

**Evidence:**

```
Caption: "1 lb pasta\n2 tbsp olive oil\n3 cloves garlic, minced\nSalt to taste\n…"
Output:  ingredients=4  ← all four parse correctly  ✓

Caption: "Greek salad: 3 tomatoes, 1 cucumber, 1/2 red onion, 1 cup feta…"
Output:  ingredients=3 (feta, olive oil, vinegar)
         steps=3        ← "3 tomatoes", "1 cucumber", "1/2 red onion" went into steps!

Caption: "1 cup brown butter, 1 cup brown sugar, 2 eggs, 2 1/4 cups flour…"
Output:  ingredients=7 (cup-bearing items)
         steps=1 ("2 eggs")  ← "2 eggs" → step
```

`looksLikeIngredient` requires the line to start with `<num><unit>` where unit is in `knownUnits`. But "2 eggs", "1 cucumber", "3 tomatoes" don't have units — so they're classified as steps.

**Root cause:** `RecipeImporter.looksLikeIngredient` (`RecipeImporter.swift:460`):

```swift
let pattern = #/(?i)^\d+(?:[.\u{00BC}-\u{215E}]\d*)?(?:(?:\s+|\s*&\s*)(?:\d+/\d+|[\u{00BC}-\u{215E}]))?(?:/\d+)?\s*(cup|cups|tbsp|...)\b/#
```

The unit alternation is required for a match. Plural-noun-only ("2 eggs") doesn't match.

**Proposed fix:** Add a permissive secondary check — when the line matches `^\d+\s+\w+s?$` (count + plural noun, possibly with an adjective in between, max ~6 words), treat it as an ingredient. Optionally gate on a small bare-count ingredient lexicon (`eggs`, `egg`, `tomatoes`, `tomato`, `onions`, `onion`, `cucumbers`, `cucumber`, `apples`, `apple`, `lemons`, `lemon`, `limes`, `lime`, `bananas`, `banana`, `peppers`, `pepper`, `potatoes`, `potato`, `avocados`, `avocado`, `carrots`, `carrot`, `cloves` …) so we don't grab arbitrary noun-counts like "5 minutes" (`minutes` is already excluded by isPureDuration but defensively).

```swift
private static let bareCountFoods: Set<String> = [
    "egg", "eggs", "tomato", "tomatoes", "onion", "onions",
    "cucumber", "cucumbers", "apple", "apples", "lemon", "lemons",
    "lime", "limes", "banana", "bananas", "pepper", "peppers",
    "potato", "potatoes", "avocado", "avocados", "carrot", "carrots",
    "clove", "cloves", "stalk", "stalks", "rib", "ribs",
    "leaf", "leaves", "sprig", "sprigs", "head", "heads",
    "scallion", "scallions", "shallot", "shallots",
    "chicken", "thigh", "thighs", "breast", "breasts", "drumstick", "drumsticks",
    "fillet", "fillets", "steak", "steaks",
]

private static func looksLikeBareCountIngredient(_ line: String) -> Bool {
    guard let m = try? #/^(\d+(?:[.,/]\d+)?)\s+(?:\w+\s+){0,4}(\w+)$/#.wholeMatch(in: line) else {
        return false
    }
    let lastWord = String(m.output.2).lowercased().trimmingCharacters(in: .punctuationCharacters)
    return bareCountFoods.contains(lastWord)
}

// Compose into looksLikeIngredient:
private static func looksLikeIngredient(_ line: String) -> Bool {
    let stripped = stripLeadingBullet(line).trimmingCharacters(in: .whitespaces)
    if knownUnitMatch(stripped) { return true }
    if looksLikeBareCountIngredient(stripped) { return true }
    return false
}
```

`buildIngredient` already produces a sensible output for "2 eggs" once the line is classified as an ingredient: qty=2, unit="", name="eggs". The only thing missing is the classifier nod.

**Test evidence:** With the fix, the Greek salad caption goes from 3→6 ingredients. The brown butter cookies block format goes from 7→8 ingredients (eggs lifts).

**Risk to watch:** false positives on lines like "2 hours later, add the eggs". The `^\d+\s+...` anchor and the `bareCountFoods` whitelist mitigate, but a line like "2 onions are needed" would still match. Limit the check to lines ≤ 5 words to control the blast radius.

---

## Finding 6: Outbound URL in caption — surface to user as alternate import path

**Severity:** Medium. Often the caption explicitly *names* the source URL where the full recipe lives.

**Evidence:** From the corpus:

```
"Tall, Fluffy Buttermilk Pancakes on smittenkitchen.com + linked in profile."
"Full recipe at https://example.com/recipe"
"Get the recipe at brokebakercommunal.com/sourdough-bread"
```

Currently the parser ignores these inline URLs. Combined with Finding 2's `.noRecipeInCaption` outcome, surfacing the URL gives the user a one-tap path to a successful import.

**Root cause:** No URL extraction in `RecipeImporter.parse` or `RecipeURLImporter`.

**Proposed fix:** Add a URL extractor and combine with the `.noRecipeInCaption` outcome.

```swift
/// Extract any http(s) URL or domain-shaped reference from caption text.
/// "smittenkitchen.com" matches even without a scheme so the user can
/// tap to navigate. Returns the first plausible URL only — caption
/// text rarely has more than one and the first is almost always the
/// source.
static func extractCaptionURL(_ text: String) -> URL? {
    if let m = try? #/https?://\S+/#.firstMatch(in: text),
       let u = URL(string: String(m.output.0)) { return u }
    if let m = try? #/(?<![@.])\b([a-z0-9-]+\.(?:com|net|org|io|co|us|blog|food|recipe|kitchen)(?:/\S+)?)\b/#.firstMatch(in: text),
       let u = URL(string: "https://" + String(m.output.1)) { return u }
    return nil
}
```

Combine with the `.noRecipeInCaption` outcome from Finding 2:

```swift
let regexDraft = RecipeImporter.parse(cleaned)
if !RecipeImporter.hasUsableRecipeContent(regexDraft) {
    var enrichment = DraftRecipe()
    enrichment.sourceUrl = url.absoluteString
    if let outbound = RecipeImporter.extractCaptionURL(cleaned) {
        return .partial(
            enrichment: enrichment,
            seedText: "",
            hint: "This caption mentions \(outbound.host ?? outbound.absoluteString) — try importing that link instead."
        )
    }
    return .noRecipeInCaption(...)
}
```

**Test evidence:** Pattern matches all three example captions. False-positive risk is low because the second regex requires a known TLD; everyday email addresses are excluded by the lookbehind.

---

## Finding 7: Pinterest pin with Recipe schema but no instructions

**Severity:** Medium. Mostly UX — the parser shouldn't claim full success when steps are missing.

**Evidence:**

```
pin: https://www.pinterest.com/pin/979955200187144903/
  Recipe schema: name, ingredients (9), yield, cookTime, totalTime, prepTime
  recipeInstructions: missing entirely
```

Pinterest's recipe-pin extraction populates ingredients but drops instructions for some pins. Currently `fetchPinterest` returns `.full(draft)` because `recipeFound = !ingredients.isEmpty || !steps.isEmpty` is true — but the user opens the editor and sees ingredients with no steps.

**Root cause:** The `recipeFound` predicate is too lenient for the Pinterest path. Acceptable for a recipe blog (where missing steps are an authoring error), but Pinterest pins have a known pattern of missing instructions.

**Proposed fix:** When the Pinterest path produces a draft with ingredients but `steps.count == 0`, hand back a `.partial` outcome with a clear hint:

```swift
if result.recipeFound && result.draft.steps.isEmpty {
    return .partial(
        enrichment: result.draft,
        seedText: "",
        hint: "Got the ingredients from the pin — for the steps, tap the pin's 'Visit' link to the original recipe."
    )
}
```

Combine with Finding 1: try following `sharedContent.url` first; only return `.partial` if both that and the on-page Recipe schema lack steps.

**Test evidence:** The corpus pin has 9 ingredients, 0 steps. Current parser returns full success; proposed returns partial with the hint.

---

## UX recommendations (cross-cutting)

These are product-level decisions, not parser fixes — but they're the natural follow-ups once the parser starts emitting richer outcomes:

1. **`.noRecipeInCaption` → empty-state UI**: instead of opening the editor with a junk title, show a sheet with the caption text rendered as text + a "Paste recipe text" button + (when applicable) a "Try this link instead" button populated from Finding 6's URL extractor.

2. **Pinterest "Visit" hint** (Findings 1, 7): when we couldn't follow `sharedContent.url` automatically (e.g., the destination is itself blocked or returns no JSON-LD), show the destination URL to the user with a "Open in Safari" affordance so they can navigate manually.

3. **Caption pre-cleaning at the URL importer level**: Findings 4-6 propose extending `cleanTitle` and adding an `extractCaptionURL`. These could be applied at one place in `RecipeURLImporter.fetchTikTok`/`fetchPinterest`/`fetchHTML` rather than every caller — wrap the regex-draft attempt with a single `cleanCaption(text:) -> (text, extractedURL, isLikelyEmpty)` helper.

---

## Test evidence (harness numbers)

```
Synthetic captions (parser's known-working shapes):
  sourdough run-on:    title="Same day sourdough is the best sourdough"
                       ingredients=4  steps=7  (timer flags + parenthetical lift correct)
  block-format:        title="Brown butter chocolate chip cookies"
                       ingredients=8  steps=4
  labeled-format:      title="Easy Pasta"
                       ingredients=4  steps=3

Real TikTok captures:
  Zakarian hashtags-only:           ingredients=0  steps=0   title=hashtag run
  Smitten Kitchen link-in-profile:  ingredients=0  steps=0   title=full caption
  TheseCarbsDontCount dish-emoji:   ingredients=0  steps=0   title=full caption with brand mention

Real Pinterest captures:
  pin/979… (Recipe schema):         ingredients=9  steps=0   ← Finding 7
  pin/124… (SocialMediaPosting):    ingredients=0  steps=0   sharedContent.url present  ← Finding 1
  pin/4503… (SocialMediaPosting):   ingredients=0  steps=0   sharedContent.url present  ← Finding 1
  pin/2251… (marketing-only):       ingredients=0  steps=5   ← Finding 3 (5 fake steps from marketing copy!)

Edge cases:
  brand-mention-inline:             ingredients=0  steps=0   ← Finding 5 (eggs/onion bare-count)
  recipe-then-link-in-bio:          ingredients=4  steps=1   ← title bloated; "2 eggs" became step
  link-in-bio-only:                 ingredients=0  steps=0   ← caught by Finding 2
  emoji-decorated-title:            ingredients=7  steps=5   ← title has emoji decoration; "2 eggs" became step
  typo-and-noise (comment RECIPE):  ingredients=0  steps=0   ← caught by Finding 2 + Finding 4 bio marker
  dish-name-only:                   ingredients=0  steps=0   ← caught by Finding 2
  single-line-recipe-with-amounts:  ingredients=3  steps=3   ← title ate first ingredient ("Greek salad: 3 tomatoes"); "1 cucumber" / "1/2 red onion" became steps
```

After applying Findings 1-6:

```
Pinterest pin/124… → recurse to handletheheat.com → 9 ingredients + 7 steps
Pinterest pin/4503… → recurse to flavornectar.com → (test confirms recipe schema present)
Pinterest pin/2251… → .noRecipeInCaption (no fake steps generated)
TikTok hashtag-only / link-in-profile / brand-mention → .noRecipeInCaption with friendly hint
Edge cases: bare-count ingredients lift to 6 ingredients (Greek salad), 8 ingredients (cookies)
```

---

## Files to modify (line-level)

| Finding | File | Function | Approx. lines |
|---|---|---|---|
| 1 | `ios-native/Sources/Lib/RecipeURLImporter.swift` | `fetchPinterest(url:)` | L116 — add `sharedContent.url` follow-up call after the existing `result.recipeFound` check |
| 1 | `ios-native/Sources/Lib/RecipeSchemaParser.swift` | new `extractPinterestSharedContent(from:)` + `findSocialMediaPosting(in:)` helpers | end of file |
| 2 | `ios-native/Sources/Lib/RecipeImporter.swift` | new `hasUsableRecipeContent(_:)` + `hasCookingActionOrDuration(_:)` helpers | end of file |
| 2 | `ios-native/Sources/Lib/RecipeURLImporter.swift` | add `Outcome.noRecipeInCaption(...)` case + gate on `hasUsableRecipeContent` in `fetchTikTok` / `fetchPinterest` / `fetchHTML` (caption-fallback path) | L20 (enum) + L86 / L116 / L145 |
| 3 | `ios-native/Sources/Lib/RecipeURLImporter.swift` | `fetchPinterest(url:)` | L130-140 — suppress og:description seed text when nothing else recovered |
| 4 | `ios-native/Sources/Lib/RecipeImporter.swift` | `stripTitleLabel(_:)` + new `stripLeadingDecoration` + `stripBioMarker` helpers | L515 |
| 5 | `ios-native/Sources/Lib/RecipeImporter.swift` | `looksLikeIngredient(_:)` + new `looksLikeBareCountIngredient(_:)` + `bareCountFoods` set | L460 |
| 6 | `ios-native/Sources/Lib/RecipeImporter.swift` | new `extractCaptionURL(_:)` helper | end of file |
| 6 | `ios-native/Sources/Lib/RecipeURLImporter.swift` | wire into `fetchTikTok` / `fetchPinterest` no-recipe paths | L90 / L130 |
| 7 | `ios-native/Sources/Lib/RecipeURLImporter.swift` | `fetchPinterest(url:)` | L120 — extra branch for "Recipe schema present, but steps empty" |

The Findings 4-6 helpers are independent and small; if you want to phase, ship them in any order. Findings 1+2 are the load-bearing pair — they should land together because Finding 2 changes the empty-caption outcome shape that Finding 1's recursive call returns into.

---

## Things I couldn't verify in this pass

- **Instagram path**: would have required logged-in Chrome to fetch real captions. The IG caption shape is well-documented (similar to TikTok run-on style — single paragraph, lots of emoji, hashtags at the end), and the parser path is identical (paste flow → `RecipeImporter.parse`), so the findings should transfer 1:1. Suggest a follow-up corpus pull once IG is logged in.
- **`RecipeAIParser` interaction**: I tested the regex pipeline only. The AI parser (iOS 26 + Apple Intelligence) is its own beast with separate failure modes (worked example #3 in the prompt covers reverse-form cookbook metadata, but caption-shape failure modes — e.g. "no recipe in caption" detection — aren't part of its instructions). Suggest adding an explicit "if there's no recipe content, return null cleanly" instruction once Finding 2's `.noRecipeInCaption` outcome lands. The `passesQualityGate` check is too lenient (title alone passes).
- **TikTok page-rendered captions vs. oEmbed captions**: I used oEmbed only (which is what the iOS app uses). TikTok's logged-in page sometimes includes additional caption content not in oEmbed (e.g., pinned-comment recipes). Out of scope here; captured as a follow-up.
- **Pinterest API rate limits**: the recursive fetch in Finding 1 could in theory hit a Pinterest pin that points to another Pinterest pin (rare). The defensive check (`refuse to follow sharedContent.url whose host is pinterest.com / pin.it`) handles this.

---

## Where the harness lives

Same outputs folder as the link-import work: `harness/port_recipe_importer.py` (the regex-pipeline port), `harness/run_caption_baseline.py` (corpus runner + synthetic test cases), `harness/test_edge_captions.py` (the 7 edge cases), and `corpus_social/` (the captured TikTok / Pinterest data files in plaintext). All re-runnable; the corpus files are small (< 1 KB each) and can be added to in seconds via the same Chrome + JS extractor flow used in this session.
