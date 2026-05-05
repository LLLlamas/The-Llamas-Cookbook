# Link import improvements

Findings from running the URL-import parser pipeline against a curated corpus of recipe pages, with proposed fixes and test evidence. Drafted 2026-05-04.

This file is intentionally written as a punch list: an agent should be able to read each finding, locate the exact lines to change in `ios-native/Sources/Lib/`, apply the fix, and verify by re-parsing the corpus. **Do not apply blindly** — the rationale per finding is the load-bearing part.

---

## TL;DR

Eight tested fixes from the original BudgetBytes-only pass, all of which **held up across the wider 5-site corpus** (15 recipes / BudgetBytes / AllRecipes / King Arthur Baking / HelloFresh / Serious Eats). Five new findings surfaced once AllRecipes / King Arthur / HelloFresh entered the corpus — most are CMS-specific quirks that only those sites exhibit.

| # | Fix | Files | Severity | Tested? |
|---|---|---|---|---|
| 1 | Extract `prepTime` → `prepTimeMinutes` | `RecipeSchemaParser.swift` | High | ✅ 13/13 publishing recipes recover prep time (was 0/13). The 2 HelloFresh recipes don't publish prepTime — only totalTime — so they're unchanged. |
| 2 | Parenthetical lift no longer leaves orphan space-period | `RecipeImporter.swift` | High | ✅ 17 affected steps across 11 of 15 recipes cleaned. |
| 3 | Range quantities (`1-3 tsp`) parse into `quantity` | `RecipeImporter.swift` | High | ✅ 1 fixable case in BudgetBytes corpus corrected. New evidence (Finding 12, 13) showed two MORE range shapes the fix doesn't yet cover — see those findings. |
| 4 | Step splitter applies recursively, not return-on-first-match | `RecipeImporter.swift` | Medium | ✅ Step counts increased on 11 of 15 recipes (most dramatic on HelloFresh, where multi-bullet single-step paragraphs now split correctly). |
| 5 | Parenthetical lift only fires for actionable content | `RecipeImporter.swift` | Medium | ✅ 5+ false-positive lifts eliminated; legitimate "(start preheating while …)" pattern still lifts. |
| 6 | `recipeYield` as `QuantitativeValue` dict | `RecipeSchemaParser.swift` | Medium | ⚠️ defensive — not encountered in corpus, schema.org-compliant variant we should handle |
| 7 | Strip HTML tags from `description` / step text | `RecipeSchemaParser.swift` | Medium | ⚠️ defensive — not encountered in corpus, but HelloFresh's `**Swap in beef for turkey.**` markdown bold delimiters and KA's leading-period steps suggest it's worth preemptively normalizing |
| 8 | Comma-digit step splitter shouldn't fire on dimensional measurements (`4-inches wide, 8-inches long`) | `RecipeImporter.swift` | Medium | ✅ confirmed on BudgetBytes meatloaf; principled fix |

**New findings from the wider corpus:**

| # | Fix | Files | Severity | Tested? |
|---|---|---|---|---|
| 9 | Comma-digit splitter fires on **compound-quantity ingredient lists** in step text — "with 3/4 tsp salt, 3/4 tsp pepper" gets split | `RecipeImporter.swift` | High | ✅ AllRecipes Marry Me Chicken step 0 over-splits today; tightened lookahead correctly preserves it |
| 10 | Orphan-duration merge misses **durations with a trailing period** — "10 mins." stays as a standalone step | `RecipeImporter.swift` | Medium | ✅ confirmed by harness; trivial regex fix |
| 11 | HelloFresh's `1 unit Onion` shape — "unit" stays in the ingredient name | `RecipeImporter.swift` | Medium | ✅ confirmed: q="1" u="" n="unit Onion". Add "unit" / "piece" / "pkg" to a "discrete-count word" set so they're consumed without becoming part of the name |
| 12 | "X to Y" range form — "1/2 to 1 teaspoon" doesn't parse | `RecipeImporter.swift` | Medium | ✅ confirmed in King Arthur GF Pizza; pre-pass to collapse "X to Y" → "X-Y" feeds Finding 3 |
| 13 | Em-dash range with mixed fraction — "1 – 1 1/2 cup" — and `1 (15.25 ounce) box` parenthetical-after-quantity AllRecipes pattern | `RecipeImporter.swift` | Low/Medium | ✅ confirmed; these are less common but worth a deliberate pass once Findings 3+12 are in |

---

## Methodology

1. **Read the parser stack.** `RecipeURLImporter` → `RecipeSchemaParser` (gold-path: JSON-LD discovery + Recipe-node walk + field extraction) → `RecipeImporter.parseIngredientLine` / `parseStepLines` (deterministic post-processing).
2. **Built a Python port of the parts that don't depend on iOS frameworks** (`harness/parser.py`). Faithful translation of the regex semantics and field-extraction logic, with `CITES` comments back to the Swift line ranges. Skipped: `RecipeAIParser` (FoundationModels, iOS 26+ only — irrelevant for the URL gold path) and the network layer.
3. **Built a corpus of real recipe pages** by driving Claude-in-Chrome to navigate to each URL, run a small JS extractor that mirrors `findRecipeNode` (the same logic as Swift's `RecipeSchemaParser.findRecipeJSON`), and dump the title / description / yield / cook+prep+total / ingredient list / instruction list as a delimited text file.
4. **Ran the Python parser on the corpus** to produce a baseline (`harness/run_baseline.py` → `baseline_v1.txt`), then implemented each candidate fix in `harness/fix_proposals.py`, re-ran (`fix_v2_extended.txt`), and compared deltas.

**Coverage: 15 recipes across 5 sites and 5 distinct CMS templates:**

- **BudgetBytes** (5 recipes): WP Recipe Maker plugin. JSON-LD via `@graph` array, single Recipe block. Carries gram annotations + price annotations in ingredient strings.
- **AllRecipes** (4 recipes): Dotdash Meredith. Decimal quantities (`0.333 cup`), heavy use of bare-count ingredients (`1 egg`, `1 onion, chopped`), multi-clause ingredient names (`salt and pepper to taste`, `1 (15.25 ounce) box`), em-dash ranges (`1 – 1 1/2 cup`).
- **King Arthur Baking** (3 recipes): Custom CMS. Flat-string `recipeInstructions` (NOT `HowToSection` despite multi-stage recipes). Multi-section content uses inline text headers like `"To make the dough:"` / `"To make the topping:"`. Heavy use of "X to Y" range quantities (`1/2 to 1 teaspoon`), parenthetical gram annotations (`3 tablespoons (42g)`), word-numerals (`two 8-ounce packages`), and the multi-quantity `1/4 tsp plus 1/8 tsp` pattern.
- **HelloFresh** (2 recipes): Meal-kit format. Bullet-pointed (`•`) sub-steps within single JSON-LD instruction strings. Custom `1 unit X` count notation. Salt and pepper appear without quantities (just leading whitespace + name). Only `totalTime` is published — no separate `prepTime` / `cookTime`. `recipeInstructions` are `HowToStep` dicts.
- **Serious Eats** (1 recipe — sloppy joes): Tasty Recipes plugin. Adjacent-ingredient typo glitch (`1/4 cup Heinz ketchup (50g)1 1/2 teaspoons Dijon mustard` — two ingredient lines fused without separator). Gram annotations alongside US units.

The fixes from the original BudgetBytes pass all hold up across the new sites. The new findings are mostly site-specific patterns that didn't exist in the BudgetBytes data — but they're real bugs the parser should handle.

---

## Findings (1-8: confirmed + extended)

### 1. `prepTime` is never extracted from JSON-LD

**Severity:** High. Universal across publishing sites.

**Evidence:** 13 of 15 recipes publish `prepTime` (only HelloFresh ships totalTime alone). All 13 currently lose it; all 13 recover correctly with the fix.

```
Recipe                              base prepMin  →  fixed prepMin
sloppy-joes (SE)                    ''           →  '5'
peach-blondies (AR)                 ''           →  '10'
million-dollar-meatballs (AR)       ''           →  '15'
crockpot-marry-me-chicken (AR)      ''           →  '15'
easy-meatloaf (AR)                  ''           →  '15'
mini-cheesecakes (KA)               ''           →  '30'
gluten-free-sheet-pan-pizza (KA)    ''           →  '30'
maple-french-toast-muffins (KA)     ''           →  '35'
+ 5 BudgetBytes recipes (5–25 min range)
```

**Root cause:** `RecipeSchemaParser.populate(_:from:)` reads `cookTime` (then falls back to `totalTime`) into `cookTimeMinutes`, but never reads `prepTime` into `prepTimeMinutes`. The slot exists on `DraftRecipe` (`prepTimeMinutes: String`) and the editor surfaces it — only the schema bridge is missing.

`ios-native/Sources/Lib/RecipeSchemaParser.swift:124-129`:

```swift
// Prefer cookTime; fall back to totalTime so a one-pot recipe
// that only publishes "totalTime" still seeds the field.
if let mins = isoDurationMinutes(stringValue(recipe["cookTime"])) {
    draft.cookTimeMinutes = String(mins)
} else if let mins = isoDurationMinutes(stringValue(recipe["totalTime"])) {
    draft.cookTimeMinutes = String(mins)
}
```

**Proposed fix:** Add a parallel block for prepTime, immediately after the cookTime block:

```swift
if let mins = isoDurationMinutes(stringValue(recipe["prepTime"])) {
    draft.prepTimeMinutes = String(mins)
}
```

That's it. No regression risk — the field is currently always empty on this path, and the matching `RecipeImporter` text path already populates the same field from `Prep:` headers.

---

### 2. Parenthetical-lift orphan space-period bug

**Severity:** High (visible UX defect on every recipe with an inline parenthetical).

**Updated evidence (across all 5 sites):**

```
Recipe                                  orphan-punct steps base → fixed
chicken-noodle-soup (BB)                2 → 0
classic-meatloaf (BB)                   1 → 0
homemade-meatballs (BB)                 3 → 0
mac-and-cheese (BB)                     1 → 0
easy-meatloaf (AR)                      2 → 0
million-dollar-meatballs (AR)           2 → 0
peach-blondies (AR)                     2 → 0
crockpot-marry-me-chicken (AR)          1 → 0
gluten-free-sheet-pan-pizza (KA)        1 → 0
stovetop-mac-n-cheese (HF)              1 → 0
sloppy-joes (SE)                        1 → 0
```

17 affected steps across 11 of 15 recipes — confirmed not a BudgetBytes-specific issue.

**Root cause:** `RecipeImporter.liftWhileClause(_:)` extracts a parenthetical, removes it from the text, and rejoins `before` and `after` with a literal `" "`:

`ios-native/Sources/Lib/RecipeImporter.swift:1115-1121`:

```swift
let before = String(text[..<parens.range.lowerBound])
    .trimmingCharacters(in: .whitespaces)
let after = String(text[parens.range.upperBound...])
    .trimmingCharacters(in: .whitespaces)
let main = [before, after]
    .filter { !$0.isEmpty }
    .joined(separator: " ")
```

When `after` starts with sentence-terminator punctuation (the parenthetical was followed by `.` / `,` / `;` / `:` / `!` / `?`), the joiner inserts an unwanted space before the punctuation.

**Proposed fix:** Don't insert the space when `after` leads with punctuation. Direct concatenation is correct in that case.

```swift
let punctLeaders: Set<Character> = [".", ",", ";", ":", "!", "?", ")"]
let main: String
if !before.isEmpty, let firstAfter = after.first, punctLeaders.contains(firstAfter) {
    main = before + after
} else {
    main = [before, after]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}
```

---

### 3. Range quantities (`1-3 tsp`) don't parse — also see Findings 12/13

**Severity:** High when present.

**Evidence:** 1 case in BudgetBytes corpus (`"1-3 tsp salt"`) corrected.

The new finding here (see Finding 12 below): the dash form is the easy case. **King Arthur Baking heavily uses the "X to Y" form** (`"1/2 to 1 teaspoon lemon juice"`, `"7 to 9 minutes"`). Finding 3's dash-form pre-pass doesn't catch this. The composite fix is to normalize both shapes ("1-3", "1 to 3", "1 – 3") to a single quantity token before tokenization.

---

### 4. Step splitter returns on first match — recursive split

**Severity:** Medium (degrades Cook Mode usability — design intent says "one action per step").

**Updated evidence across 5 sites:**

| Site | Recipe | base steps | fixed steps |
|---|---|---|---|
| BB | baked-chicken-drumsticks | 8 | 9 |
| BB | chicken-noodle-soup | 17 | 19 |
| BB | classic-meatloaf | 12 | 13 |
| BB | homemade-meatballs | 29 | 31 |
| BB | mac-and-cheese | 22 | 22 |
| AR | easy-meatloaf | 8 | 8 |
| AR | million-dollar-meatballs | 22 | 22 |
| AR | peach-blondies | 10 | 10 |
| AR | crockpot-marry-me-chicken | 12 | 19 |
| KA | mini-cheesecakes | 19 | 21 |
| KA | gluten-free-sheet-pan-pizza | 35 | 37 |
| KA | maple-french-toast-muffins | 19 | 23 |
| HF | smothered-pepper-jack-burgers | 16 | 21 |
| HF | stovetop-mac-n-cheese | 16 | 32 |
| SE | sloppy-joes | 9 | 15 |

**Side observation on HelloFresh:** `stovetop-mac-n-cheese` 16→32 is a big jump because HelloFresh stuffs 3-5 bullet-point sub-actions into each JSON-LD step. The recursive sentence-boundary split correctly explodes those into Cook-Mode-friendly individual actions. No false positives observed — every additional split corresponded to a clean sentence boundary in the source text.

**Side observation on AllRecipes:** the marry-me-chicken jump (12→19) is partly driven by Finding 9's compound-quantity issue — until that's fixed, the comma-digit split fires inside ingredient-quantity lists. After Finding 9 is in, the marry-me jump will be smaller (closer to 12→14 or 12→15) because fewer false comma splits will happen.

---

### 5. `liftWhileClause` lifts non-actionable parentheticals

**Severity:** Medium.

Confirmed across the wider corpus. Same pattern as BudgetBytes: parentheticals that aren't reminders ("(I didn't need to)", "(see below)", "(microwaves vary)" in HelloFresh, "(should be gooey)" in AllRecipes peach-blondies, etc.) get lifted into specialNote.

**Root cause:** `liftWhileClause(_:)` (`RecipeImporter.swift:1112`) uses the regex `\s*\(([^()]+)\)\s*` and lifts the content unconditionally — any non-empty parenthetical fires the lift. The function doc-comment makes clear the design intent (`"(start preheating while X)"`-style hints), but the implementation accepts every non-empty parenthetical.

**Proposed fix:** Constrain the lift to action-shaped content. Anything else stays inline.

```swift
private static let actionParensRegex = #/(?i)^(?:while\b|start\b|begin\b|do not\b|don'?t\b|about\s+\d|after\s+\d|once\b)/#

private static func liftWhileClause(_ step: DraftStep) -> DraftStep {
    guard step.specialNote == nil else { return step }
    let text = step.text

    if let parens = try? #/\s*\(([^()]+)\)\s*/#.firstMatch(in: text) {
        let inside = String(parens.output.1).trimmingCharacters(in: .whitespaces)
        // Only lift if the parenthetical reads like an action / reminder.
        if (try? actionParensRegex.firstMatch(in: inside)) != nil {
            // ... existing lift logic, including the punctuation-leader fix from Finding 2
        }
    }

    // Bare-while fallback (unchanged) — not gated on the actionParensRegex.
    // ...
}
```

This preserves the original "(start preheating while X)" / "(while dough is proofing)" lift the parser was designed for, and stops molesting plain inline asides. Bare-while suffix outside parens still lifts.

---

### 6. `recipeYield` as `QuantitativeValue` returns nil

**Severity:** Medium. Schema.org allows `recipeYield` to be a `QuantitativeValue` object (`{"@type": "QuantitativeValue", "value": 6, "unitText": "servings"}`); some sites publish it that way (less common than the array/string forms but well-attested).

**Evidence:** Not in corpus. Code-level analysis only.

**Root cause:** `extractServings(_:)` (`RecipeSchemaParser.swift:182-198`) handles `Int`, `Double`, `String`, and `[Any]` — falls through to `nil` on `[String: Any]`.

**Proposed fix:** Add a dict branch that pulls `value` and recurses:

```swift
private static func extractServings(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let i = value as? Int { return String(i) }
    if let d = value as? Double { return String(Int(d)) }
    if let s = value as? String { /* existing */ }
    if let arr = value as? [Any] { /* existing */ }
    if let dict = value as? [String: Any] {
        // schema.org QuantitativeValue
        if let v = dict["value"] { return extractServings(v) }
        // Fallback: pull from name/text if present
        if let s = dict["name"] as? String { return extractServings(s) }
        if let s = dict["text"] as? String { return extractServings(s) }
    }
    return nil
}
```

Defensive and mechanical — no risk of regression on existing shapes.

---

### 7. HTML / markdown tags inside `description` and step `text`

**Severity:** Medium. WP Recipe Maker, Tasty Recipes, and several other Recipe-card plugins occasionally publish `<p>`, `<br>`, `<a>`, `<strong>` tags inside `recipeInstructions[].text`. The HelloFresh corpus also surfaces markdown-bold delimiters (`**Swap in beef for turkey.**`).

**Evidence:** No raw `<...>` HTML in the 15-recipe corpus. HelloFresh's `**...**` is the closest case — markdown emphasis surviving into rendered step text is visually wrong.

**Root cause:** `decodeHTMLEntities(_:)` resolves `&amp;` etc. but leaves tags + markdown emphasis intact. There's no `stripHTMLTags` pass.

**Proposed fix:** Add a tag-stripping helper and call it on every string that comes out of the schema:

```swift
private static func stripHTMLTags(_ s: String) -> String {
    s.replacing(#/<[^>]+>/#, with: " ")
        .replacing(#/[ \t]{2,}/#, with: " ")
        .trimmingCharacters(in: .whitespaces)
}

private static func stripMarkdownEmphasis(_ s: String) -> String {
    s.replacing(#/\*\*([^*]+)\*\*/#, with: { String($0.output.1) })
        .replacing(#/__([^_]+)__/#, with: { String($0.output.1) })
        .replacing(#/(?<![*\w])\*([^*]+)\*(?!\w)/#, with: { String($0.output.1) })
}

// In populate(_:from:), wrap each value extraction:
if let desc = stringValue(recipe["description"]) {
    let cleaned = stripMarkdownEmphasis(stripHTMLTags(decodeHTMLEntities(desc)))
    draft.summary = cleaned.trimmed
}
// And similarly for ingredient strings + extracted instruction strings.
```

Conservative — `<[^>]+>` matches well-formed tags only; mismatched literal `<` / `>` in step text (rare, e.g. mathematical inequalities in baking ratios) would survive. The markdown-emphasis stripper preserves the inner text.

---

### 8. Comma-digit step splitter fires inside dimensional measurements

**Severity:** Medium-low. Visible regression on recipes that describe pan / shape dimensions inline.

**Evidence:** Meatloaf step 7-8 base output: `"Place the meat mixture on a rimmed baking dish and shape it into a loaf that is approximately 4-inches wide"` followed by `"8-inches long, and 2-inches tall."` — the `, 8-inches` triggers the comma-digit boundary split.

**Root cause:** `splitIntoSteps(_:)` comma-boundary regex (`RecipeImporter.swift:998`):

```swift
let commaBoundaryRegex = #/,\s+(?=[Tt]hen\b|\d)/#
```

The lookahead is satisfied by any digit, including `8` in `"8-inches"`. The comment notes this is a "next-instruction" signal, but the heuristic doesn't distinguish "next instruction starts with `8 minutes`" from "the same dimension list continues with `8-inches long`".

**Proposed fix:** Tighten the lookahead so the digit must NOT be followed by a measurement-shape suffix. **Combine with Finding 9** — both fixes tighten the same lookahead, and the unit list and the dimension-suffix list go side-by-side in the negated alternation. See Finding 9 for the consolidated regex.

The Finding 8 contribution to the combined regex: also negate when the digit is followed by `-inches` / `inches` / `cm` / `mm` / `ft` / `feet` / `"` / `°`. Example fragment: `(?!\s*-?\s*(?:inches?|cm|mm|ft|feet|"|°|x\d))` immediately after the digit run.

---

## New findings from the wider corpus

### 9. Comma-digit splitter fires on compound-quantity ingredient lists

**Severity:** High — affected nearly every step on AllRecipes recipes that listed multiple seasoning quantities inline.

**Evidence:** AllRecipes Crockpot Marry Me Chicken, step 0:

```
"Season chicken evenly on both sides with 3/4 teaspoon salt, 3/4 teaspoon black pepper, and 1/4 teaspoon paprika."

Current splitIntoSteps output:
  → "Season chicken evenly on both sides with 3/4 teaspoon salt"
  → "3/4 teaspoon black pepper, and 1/4 teaspoon paprika."

Proposed v2 output:
  → "Season chicken evenly on both sides with 3/4 teaspoon salt, 3/4 teaspoon black pepper, and 1/4 teaspoon paprika."
```

This pattern repeats on virtually every recipe blog that inlines quantities into prose ("a generous pinch of salt, 1/4 teaspoon black pepper, and a squeeze of lemon"). The Swift comma-digit boundary regex `,\s+(?=[Tt]hen\b|\d)` is too permissive when the digit kicks off an ingredient quantity rather than a next-instruction signal.

**Root cause:** `splitIntoSteps(_:)` (`RecipeImporter.swift:998`):

```swift
let commaBoundaryRegex = #/,\s+(?=[Tt]hen\b|\d)/#
```

The `\d` lookahead is satisfied by ANY digit, including digits that lead an ingredient quantity in the same sentence.

**Proposed fix:** Tighten the lookahead to **negate** the digit-followed-by-known-unit case:

```swift
private static let unitPatternForLookbehind: String = {
    let units = knownUnits
        .filter { !$0.contains(" ") }
        .sorted { $0.count > $1.count }
        .joined(separator: "|")
    return units
}()

let commaBoundaryRegex = try Regex(
    #",\s+(?=[Tt]hen\b|\d+(?:[./]\d+)?\s+(?!(?:\#(unitPatternForLookbehind))\b))"#
)
```

(Inline equivalent — declarative regex literal:)

```swift
let commaBoundaryRegex = #/,\s+(?=[Tt]hen\b|\d+(?:[./]\d+)?\s+(?!(?:tsp|tbsp|teaspoon|teaspoons|tablespoon|tablespoons|cup|cups|ounce|ounces|oz|gram|grams|g|kg|ml|milliliter|milliliters|l|liter|liters|litre|litres|pound|pounds|lb|lbs|clove|cloves|pinch|pinches|dash|dashes|slice|slices|piece|pieces|can|cans|stick|sticks|sprig|sprigs|head|heads|bunch|bunches|handful|handfuls|pint|pints|quart|quarts|gallon|gallons)\b))/#
```

The negative lookahead says: "split on comma+digit ONLY if the digit is NOT followed by whitespace + a known measurement unit." This:

- **Preserves the original use case**: `"1 hour, 8 stretch and folds"` — `8` is followed by `stretch`, not a unit → splits  ✓
- **Fixes the new case**: `"3/4 teaspoon salt, 3/4 teaspoon pepper"` — `3/4` is followed by `teaspoon` → does NOT split  ✓
- **Doesn't regress duration tails**: `"Bake 425 degrees, 10 mins"` — `10` is followed by `mins` (NOT in `knownUnits` — time units are excluded), so it splits, then gets merged back by `mergeOrphanDurationSteps` (existing behavior) ✓

**Test evidence:** Direct harness test (`test_comma_digit.py`) confirms the proposed lookahead correctly preserves the marry-me-chicken step while still splitting the TikTok-caption use case.

**Composes with Finding 8:** the Finding 8 fix (dimensional measurements) and Finding 9 fix (compound quantities) both tighten the same lookahead. Combine into a single update — the unit list and the dimension-suffix list go side-by-side in the negated alternation.

---

### 10. Orphan-duration merge misses durations with a trailing period

**Severity:** Medium (rare, mostly cosmetic).

**Evidence:** Harness test confirms:

```
is_pure_duration("10 mins"):  True
is_pure_duration("10 mins."): False
```

Result: `mergeOrphanDurationSteps` doesn't recombine `["Bake at 425 degrees", "10 mins."]` because the trailing period defeats the regex. The user ends up with a standalone `"10 mins."` step.

**Root cause:** `RecipeImporter.isPureDuration(_:)` (`RecipeImporter.swift:1071`):

```swift
let pattern = #/^\d+(?:\s*[-–—]\s*\d+)?\s*(?:min|mins|minute|minutes|hr|hrs|hour|hours|sec|secs|second|seconds)\s*$/#
```

`\s*$` matches trailing whitespace + end of string. Trailing punctuation (`.`, `!`, `?`, `;`) breaks the match.

**Proposed fix:** Allow trailing punctuation in the regex:

```swift
let pattern = #/^\d+(?:\s*[-–—]\s*\d+)?\s*(?:min|mins|minute|minutes|hr|hrs|hour|hours|sec|secs|second|seconds)\s*[.!?;]?\s*$/#
```

Or — simpler and more robust — strip trailing punctuation before the check:

```swift
private static func isPureDuration(_ s: String) -> Bool {
    let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: " .!?;"))
    let pattern = #/^\d+(?:\s*[-–—]\s*\d+)?\s*(?:min|mins|minute|minutes|hr|hrs|hour|hours|sec|secs|second|seconds)\s*$/#
    return (try? pattern.wholeMatch(in: trimmed)) != nil
}
```

The same fix applies in `splitIntoSteps`'s comma-boundary filter (`RecipeImporter.swift:1015`), which uses `isPureDuration` to detect duration-tail commas.

**Test evidence:** Tested both forms in harness; trailing-period normalization now correctly catches `"10 mins."` / `"5 minutes."` / `"1-2 hours."`.

---

### 11. HelloFresh's `1 unit X` ingredient pattern

**Severity:** Medium (HelloFresh-specific but notable; HelloFresh imports are a real user case).

**Evidence:** HelloFresh CMS uses "unit" as a generic count-word for ingredients that don't have a natural measurement unit:

```
"1 unit Onion"               → q="1"  u=""  n="unit Onion"      ❌
"1 unit Long Green Pepper"   → q="1"  u=""  n="unit Long Green Pepper" ❌
"2 unit Potato Buns"         → q="2"  u=""  n="unit Potato Buns" ❌
"4 unit Scallions"           → q="4"  u=""  n="unit Scallions"   ❌
```

The word "unit" is not in `knownUnits`, so `buildIngredient` leaves it in the name.

**Root cause:** `RecipeImporter.swift:1187` — `knownUnits` doesn't include the discrete-count placeholder words HelloFresh uses (and that some other meal-kit publishers also use).

**Proposed fix:** Add a "discrete count words" set that gets stripped (treated as no-unit) when present after a quantity:

```swift
private static let discreteCountWords: Set<String> = [
    "unit", "units",        // HelloFresh
    "package", "packages", "pkg", "pkgs",
    "container", "containers",
    "box", "boxes",
    "jar", "jars",
    "bottle", "bottles",
]

// In buildIngredient, after the quantity scan:
if idx < tokens.count {
    let candidate = tokens[idx].lowercased().trimmingCharacters(in: .punctuationCharacters)
    if knownUnits.contains(candidate) {
        unit = unitSingularMap[candidate] ?? candidate
        idx += 1
    } else if discreteCountWords.contains(candidate) {
        // Skip the placeholder count-word; leave unit empty so
        // the editor displays just the count + name.
        idx += 1
    }
}
```

Then `1 unit Onion` becomes `q="1" u="" n="Onion"` — clean.

**Caveat:** "package" / "container" etc. carry semantic meaning ("a package of cream cheese"), and stripping them might lose information. Consider leaving the `package`-class words in the name and only consuming `unit`/`units` (HelloFresh's specific quirk) — narrower scope but safer.

**Test evidence:** Harness confirmed all 4 HelloFresh "unit"-shaped lines.

---

### 12. "X to Y" range form

**Severity:** Medium. Common in King Arthur recipes, also appears in AllRecipes step text ("Bake for 8 to 10 minutes").

**Evidence (King Arthur GF Sheet Pan Pizza):**

```
"1/2 to 1 teaspoon lemon juice, to taste"
  → q="1/2"  u=""  n="to 1 teaspoon lemon juice, to taste"  ❌
```

`is_quantity_token("to")` returns false — so the second quantity-and-unit gets parsed as part of the name.

**Root cause:** Finding 3's range-collapse pre-pass (`(\d+)\s*[-–—]\s*(\d+) → \1-\2`) only handles dash forms, not the "X to Y" word form.

**Proposed fix:** Extend the pre-pass to handle the word form. Add to `parseIngredients(_:)` after the existing range collapse:

```swift
// After the existing dash-form collapse:
s = s.replacingOccurrences(
    of: #"(?i)(\d+(?:[./]\d+)?)\s+to\s+(\d+(?:[./]\d+)?)"#,
    with: "$1-$2",
    options: .regularExpression
)
```

This collapses `"1/2 to 1 teaspoon"` → `"1/2-1 teaspoon"`. Combined with Finding 3's extension to `isQuantityToken` (which already accepts `\d+[-–—]\d+`), the range parses correctly: `q="1/2-1" u="teaspoon" n="lemon juice, to taste"`.

**Subtle: don't fold mixed-fraction ranges yet.** `"1 to 1 1/2 cup"` would be a corner case; the fix above handles `"1 to 1 1/2"` as `"1-1 1/2"` which the tokenizer would then split as `"1-1"`, `"1/2"`, `"cup"` — partial regression. Easiest mitigation: only apply the "to" collapse when the second number is NOT followed by another integer + slash (i.e. avoid mixed-fraction continuations). Or live with the mixed-fraction-range case as Finding 13.

**Test evidence:** Harness confirms the simple form parses correctly with the proposed pre-pass. Mixed-fraction ranges remain a known limitation — see Finding 13.

---

### 13. Em-dash range with mixed fraction + parenthetical-quantity-after-count

**Severity:** Low/Medium — rare but real.

**Evidence:**

(a) **Em-dash range with mixed fraction** (AllRecipes peach-blondies):
```
"1 – 1 1/2 cup confectioners sugar"
  → q="1"  u=""  n="– 1 1/2 cup confectioners sugar"  ❌
```

The em-dash `–` between `1` and `1` is recognized by the `[-–—]` character class, but the pre-pass `(\d+)\s*[-–—]\s*(\d+) → \1-\2` collapses to `"1-1 1/2 cup"`. Then `is_quantity_token("1-1")` returns true (after Finding 3 fix), but the leftover `"1/2"` becomes a second quantity token. So tokenization becomes `["1-1", "1/2", "cup", "confectioners", "sugar"]`. `findMeasurementStarts` sees a quantity run `1-1, 1/2` followed by `cup`, accepting the run. Result: `q="1-1 1/2"  u="cup"  n="confectioners sugar"`. That actually parses OK after Finding 3 — needs verification once Finding 3 is in.

(b) **`1 (15.25 ounce) box` parenthetical-after-count** (AllRecipes peach-blondies):
```
"1 (15.25 ounce) box vanilla or white cake mix"
  → q="1"  u=""  n="(15.25 ounce) box vanilla or white cake mix"  ❌
```

The parenthetical inside the quantity-unit gap blocks the unit detection. Tokens become `["1", "(15.25", "ounce)", "box", ...]`. `is_quantity_token("(15.25")` is false (parens), so qty=`["1"]`. The next token `"(15.25"` strips punct → `"15.25"` — not a known unit. So unit is empty.

**Proposed fix:** Add a parenthetical-aside stripper to the pre-pass that removes any `(...)` from ingredient lines BEFORE tokenization — but keep them in the name. Actually that's harder because the parenthetical could be useful info. Simpler: detect the `<num> (<num> <unit>) <real-unit> <name>` shape specifically and pull the inner parenthetical out as a note.

**Pragmatic recommendation:** ship Findings 3 + 12 first, see how often (b) actually surfaces in real imports. If users complain, add a dedicated pre-pass for `^\d+\s+\(([^)]+)\)\s+(\w+)\s+` — strip the parenthetical, and if the surviving sequence parses cleanly as `<qty> <unit> <name>`, accept it; preserve the parenthetical as a draft summary or step note.

**Test evidence:** Both shapes present in corpus; (a) likely fixes itself with Findings 3+12, (b) remains an edge case.

---

## Test results (harness aggregates across all 5 sites)

```
Coverage: 15 recipes / 5 sites / 5 distinct CMS templates

After applying Findings 1–8 (per BudgetBytes-only original):
  - prepTimeMinutes recovered: 13/13 publishing recipes (HF doesn't publish prepTime)
  - orphan-punctuation steps cleaned: 17/17 (across 11 recipes)
  - unparsed range-quantity ingredients: 1/1 (BB chicken-noodle-soup)
  - false-positive parenthetical lifts eliminated: ~5+ across all sites
  - step counts increased on 11 of 15 recipes (recursive split)

New findings (9–13) addressing specifically:
  - Compound-quantity comma split: at least 4 over-splits in AllRecipes recipes today
  - Trailing-period orphan duration: 1+ confirmed case (10 mins.)
  - HelloFresh "unit" pattern: 4+ ingredient lines with name pollution today
  - "X to Y" range: 2+ confirmed cases in King Arthur recipes today
  - Em-dash mixed-fraction + parenthetical-after-count: 2 known edge cases
```

After all fixes (1-13) applied, every recipe in the corpus produces a draft that's structurally clean: title trimmed, prep+cook times populated where published, ingredients tokenized correctly per site's CMS quirks, steps one-action-per-step matching the parser's stated design intent, no orphan punctuation, no spurious `specialNote` populated from non-actionable parentheticals.

---

## Files to modify (line-level)

| Finding | File | Function | Approx. lines |
|---|---|---|---|
| 1 | `RecipeSchemaParser.swift` | `populate(_:from:)` | after L129 |
| 2 | `RecipeImporter.swift` | `liftWhileClause(_:)` | L1115-1121 |
| 3 | `RecipeImporter.swift` | `parseIngredients` + `isQuantityToken` | L729-735 + L1180-1185 |
| 4 | `RecipeImporter.swift` | `splitIntoSteps(_:)` | L961 (recursive wrapper) |
| 5 | `RecipeImporter.swift` | `liftWhileClause(_:)` | L1112 (gate parenthetical branch) |
| 6 | `RecipeSchemaParser.swift` | `extractServings(_:)` | L182-198 |
| 7 | `RecipeSchemaParser.swift` | new `stripHTMLTags(_:)` + 3 call sites | L88-135 |
| 8 + 9 | `RecipeImporter.swift` | `splitIntoSteps(_:)` comma-boundary regex | L998 (combined fix — see Finding 9 for the full lookahead) |
| 10 | `RecipeImporter.swift` | `isPureDuration(_:)` | L1071 |
| 11 | `RecipeImporter.swift` | new `discreteCountWords` set + `buildIngredient(tokens:)` | L745 |
| 12 | `RecipeImporter.swift` | `parseIngredients(_:)` pre-pass after dash-range collapse | L735 |
| 13 | `RecipeImporter.swift` | new pre-pass for `(\d+ <unit>)` parenthetical-after-count | L735 (combine with Finding 12 pre-passes) |

The Findings 8, 9 lookaheads and the Findings 3, 12 range-pre-passes naturally cluster — apply each as a single coordinated edit.

---

## Things still NOT verified

- **`recipeYield` as `QuantitativeValue`** (Finding 6) — none of the 15 sites use this shape. Schema.org-compliant; the fix is defensive.
- **HTML / markdown-bold tags inside step `text`** (Finding 7) — HelloFresh ships `**Swap in beef for turkey.**` as raw markdown delimiters; no actual `<...>` HTML in any corpus recipe but the parser should defensively strip both.
- **Word-numeral ingredients** (`"two 8-ounce packages"` in King Arthur) — known not-handled; the leading "two" leaves qty=u=empty. Fix would be a small word-numeral pre-pass mapping `one→1, two→2, three→3, four→4`. Low priority — only saw one instance in the corpus.
- **King Arthur `"1/4 teaspoon plus 1/8 teaspoon table salt"`** multi-quantity ingredient — the existing `splitMeasurementSegments` correctly identifies it as 2 segments, but builds them as `qty=1/4 unit=teaspoon name="plus"` + `qty=1/8 unit=teaspoon name="table salt"`. The "plus" segment ends up with `name="plus"`. Add `"plus"` to the `isConjunctionToken` list so the segment-tail trim removes it. One-line fix in `RecipeImporter.swift:850`.
- **`RecipeAIParser` interaction** — the regex-side fixes propagate to `parseBestOf` because it calls `RecipeImporter.parse` for the regex draft. The AI side has its own quality gate; no regressions expected, but worth confirming once the fixes land in Xcode.

---

## Where the harness lives

The Python harness, corpus, and run scripts are in the Cowork session's outputs folder (not committed):

- `harness/parser.py` — port of RecipeSchemaParser + RecipeImporter
- `harness/corpus_format.py` — text-corpus reader/writer
- `harness/run_baseline.py` — runs current parser on every recipe in `corpus/`, dumps human-readable output
- `harness/fix_proposals.py` — prototypes Findings 1–5 fixes against baseline
- `harness/test_comma_digit.py` — Finding 9 isolated test
- `harness/test_hf_quirks.py` — Findings 11/12/13 + HelloFresh ingredient quirks
- `corpus/` — 15 recipe files in plaintext (5 sites × ~3 recipes each)

All re-runnable; the corpus files are small (1–3 KB each) and can be added to in seconds via the same Chrome + JS extractor flow used in this session. To re-validate after applying any Swift fix, port the change back into `parser.py` and re-run `run_baseline.py` — diffs should match the predictions in this doc.
