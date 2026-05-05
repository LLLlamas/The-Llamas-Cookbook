# Link import improvements

Findings from running the URL-import parser pipeline against a curated corpus of recipe pages, with proposed fixes and test evidence. Drafted 2026-05-04.

This file is intentionally written as a punch list: an agent should be able to read each finding, locate the exact lines to change in `ios-native/Sources/Lib/`, apply the fix, and verify by re-parsing the corpus. **Do not apply blindly** — the rationale per finding is the load-bearing part.

---

## TL;DR

Six tested fixes (numbers below are aggregated across the 5-recipe BudgetBytes corpus; see Test results section):

| # | Fix | Files | Severity | Tested? | Net effect |
|---|---|---|---|---|---|
| 1 | Extract `prepTime` → `prepTimeMinutes` | `RecipeSchemaParser.swift` | High | ✅ | 5/5 recipes now show prep time (was 0/5) |
| 2 | Parenthetical lift no longer leaves orphan space-period | `RecipeImporter.swift` | High | ✅ | 7 orphan-punct steps cleaned across 4 recipes |
| 3 | Range quantities (`1-3 tsp`) parse into `quantity` | `RecipeImporter.swift` | High | ✅ | 1 broken ingredient corrected |
| 4 | Step splitter applies recursively, not return-on-first-match | `RecipeImporter.swift` | Medium | ✅ | 5 multi-action steps split into single-action steps |
| 5 | Parenthetical lift only fires for actionable content (`while X`, `start`, `about <N> minutes`, …) | `RecipeImporter.swift` | Medium | ✅ | 5 author-commentary parens stay inline (instead of polluting `specialNote`) |
| 6 | `recipeYield` as `QuantitativeValue` dict | `RecipeSchemaParser.swift` | Medium | ⚠️ defensive | Not in corpus; schema.org-compliant variant we should handle |

Two additional fixes recommended on principle (not yet evidenced in corpus, but well-known patterns):

| # | Fix | Files | Why |
|---|---|---|---|
| 7 | Strip HTML tags from `description` / step text | `RecipeSchemaParser.swift` | Many WP Recipe Maker / SchemaPro sites ship `<p>` / `<br>` inside `recipeInstructions[].text` |
| 8 | Comma-digit split shouldn't fire on dimensional measurements (`4-inches wide, 8-inches long`) | `RecipeImporter.swift` | Observed in BudgetBytes meatloaf; the lookahead `(?=\d)` doesn't distinguish "next instruction" from "next dimension" |

---

## Methodology

1. **Read the parser stack.** `RecipeURLImporter` → `RecipeSchemaParser` (gold-path: JSON-LD discovery + Recipe-node walk + field extraction) → `RecipeImporter.parseIngredientLine` / `parseStepLines` (deterministic post-processing).
2. **Built a Python port of the parts that don't depend on iOS frameworks** (`harness/parser.py` in the outputs folder of this Cowork session). Faithful translation of the regex semantics and field-extraction logic, with `CITES` comments back to the Swift line ranges so the agent can verify fidelity later. Skipped: `RecipeAIParser` (FoundationModels, iOS 26+ only — irrelevant for the URL gold path) and the network layer.
3. **Built a corpus of real recipe pages** by driving Claude-in-Chrome to navigate to each URL, run a small JS extractor that mirrors `findRecipeNode` (the same logic as Swift's `RecipeSchemaParser.findRecipeJSON`), and dump the title / description / yield / cook+prep+total / ingredient list / instruction list as a delimited text file. The Chrome content-filter blocks JSON-shaped responses, so the corpus uses `KEY: value` plain text — see `harness/corpus_format.py` for the parser.
4. **Ran the Python parser on the corpus** to produce a baseline output (`harness/baseline_v1.txt`), then implemented each candidate fix in `harness/fix_proposals.py`, re-ran, and compared deltas (`harness/diff_detail.py`).

**Corpus coverage gap**: only the 5 BudgetBytes recipes (`harness/run_baseline.py`) made it into the corpus; AllRecipes / KingArthur / HelloFresh navigations were blocked by the Chrome extension's site-permission dialog (denied during the session). The findings here are robust against the BudgetBytes data, and most of the bugs are obvious enough from the Swift source that they'll repeat on any JSON-LD-publishing site. **Re-run on the other 3 sites once Chrome perms are unblocked** to catch site-specific quirks (HelloFresh tends to use `@graph` nesting; King Arthur uses `HowToSection` for multi-stage recipes).

---

## Findings

### 1. `prepTime` is never extracted from JSON-LD

**Severity:** High. Every recipe loses prep-time on URL import, even though the field is universally published.

**Evidence:** All 5 BudgetBytes recipes publish `prepTime: "PT5M"` / `"PT15M"` / `"PT25M"`, but `draft.prepTimeMinutes` is `""` after `RecipeSchemaParser.parse(...)`.

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

**Test evidence:** All 5 recipes go from `prepMin=''` to `prepMin='5'` / `'15'` / `'25'` — the value matches the JSON-LD's `prepTime`.

---

### 2. Parenthetical lift leaves an orphan space-period

**Severity:** High (visible UX defect: every blog recipe with an inline parenthetical gets a stray ` .` in the step body).

**Evidence:** Chicken Noodle Soup step 14 base output: `"Add the egg noodles to the pot, turn the heat up to high, and boil the noodles until tender . Return the shredded chicken to the pot."` — note the orphan ` .` after `tender`. Source instruction was `"…until tender (about 7 minutes). Return…"`. Meatloaf step 9 has the same shape.

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

**Test evidence:** All 7 orphan-punctuation cases (`steps containing " ."` or `" ,"`) across the 5 recipes eliminated. Counts: `chicken-noodle-soup` 2→0, `classic-meatloaf` 1→0, `homemade-meatballs` 3→0, `mac-and-cheese` 1→0, `baked-chicken-drumsticks` 0→0.

---

### 3. Range quantities (`1-3 tsp`, `1–2 cups`) don't parse

**Severity:** High when present; about 1 in 15 ingredients in real-world recipes uses a range.

**Evidence:** Chicken Noodle Soup ingredient `"1-3 tsp salt (divided, $0.02)"` →

```
base:   q=''      u=''   n='1-3 tsp salt (divided, $0.02)'      ❌ entire line as name
fixed:  q='1-3'   u='tsp' n='salt (divided, $0.02)'              ✓
```

**Root cause:** `RecipeImporter.isQuantityToken(_:)` (`ios-native/Sources/Lib/RecipeImporter.swift:1180-1185`) accepts integers, decimals, and bare/improper fractions — but not ranges. So `"1-3"` is rejected, the leading-quantity scan in `buildIngredient` finds zero quantity tokens, and `hoistInlineMeasurement` then can't promote `"tsp"` to a unit because the token *before* it (`"1-3"`) didn't qualify as quantity.

**Proposed fix:** Two-step.

(a) In `parseIngredients(_:)` (`RecipeImporter.swift:719`), add a normalization pass that collapses `"1 - 3"` / `"1– 3"` / `"1-3"` into a single token `"1-3"`:

```swift
// After the existing fraction-repair pass:
s = s.replacingOccurrences(of: #"(\d+)\s*[-–—]\s*(\d+)"#, with: "$1-$2", options: .regularExpression)
```

(b) Extend `isQuantityToken(_:)`:

```swift
private static func isQuantityToken(_ s: String) -> Bool {
    if s == "&" { return true }
    if Double(s) != nil { return true }
    if s.contains("/"), s.split(separator: "/").allSatisfy({ Int($0) != nil }) { return true }
    // Ranges: "1-3", "1–3", "1—3"
    if let m = try? #/^\d+[-–—]\d+$/#.wholeMatch(in: s) { _ = m; return true }
    return false
}
```

The collapse pass runs before tokenization in `parseIngredients`, so `"1 - 3"` becomes a single quantity token that survives. The display layer already handles dash-containing strings as a quantity (chips, list rows) — no UI change needed.

**Test evidence:** 1/1 unparsed-range cases in corpus corrected. No regressions on numeric, fractional, or mixed-fraction quantities.

**Edge case to check post-fix:** an ingredient like `"3-4 cloves garlic"` — the dash form should now parse; verify the cloves unit still picks up. (Should work: `"3-4"` → quantity, `"cloves"` → unit, `"garlic"` → name.)

---

### 4. Step splitter returns on first match, leaves multi-sentence remainders

**Severity:** Medium (degrades Cook Mode usability — the parser's own design intent in `RecipeAIParser.instructions` is "ONE cooking action per step").

**Evidence:** Chicken Noodle Soup base step 8: `"Then reduce the heat to low and simmer for one hour. Make sure the pot continues to simmer for the whole hour. If the heat is turned down too low and it is not bubbling away, the chicken will not shred easily."` — three sentences, three actions, one step.

After fix: split into 3 steps. Same for meatballs (29→31 steps, gaining `"Pour in the crushed tomatoes"` + `"Then add the basil…"` and similar). Drumsticks 8→9.

**Root cause:** `splitIntoSteps(_:)` (`RecipeImporter.swift:961`) tries splitters in priority order (newline → numbered marker → comma-then → sentence) and returns as soon as one yields ≥2 pieces. When comma-then splits a paragraph in half, the half that contains additional sentence boundaries is never visited by the sentence-fallback splitter.

**Proposed fix:** Apply the splitter recursively to each piece. After any successful split, re-run `splitIntoSteps` against each piece; collect the leaf pieces. Bound the recursion to depth 3-4 to prevent pathological loops.

In `splitIntoSteps`, replace the existing return-on-first-match flow with a wrapper:

```swift
static func splitIntoSteps(_ raw: String) -> [String] {
    splitIntoStepsRecursive(raw, depth: 0)
}

private static func splitIntoStepsRecursive(_ raw: String, depth: Int) -> [String] {
    let pieces = splitIntoStepsOnePass(raw)  // body of current splitIntoSteps, renamed
    if depth >= 3 || pieces.count <= 1 { return pieces }
    var out: [String] = []
    for piece in pieces {
        let sub = splitIntoStepsRecursive(piece, depth: depth + 1)
        out.append(contentsOf: sub)
    }
    return out
}
```

**Test evidence:** Across the 5 recipes:

| Recipe | base steps | fixed steps |
|---|---|---|
| baked-chicken-drumsticks | 8 | 9 |
| chicken-noodle-soup | 17 | 19 |
| classic-meatloaf | 12 | 13 |
| homemade-meatballs | 29 | 31 |
| mac-and-cheese | 22 | 22 |

All increases came from breaking up a multi-sentence remainder of an earlier comma-then split. No false positives observed (i.e., no genuinely-single-action steps got broken up).

**Risk to watch:** the `splitIntoStepsOnePass` function relies on the comma-then filter (lines ~999-1018) to swallow `", 10 mins"`-style duration tails into the previous piece. Recursion preserves that — `mergeOrphanDurationSteps` runs after the recursion and still catches any orphan duration that did slip through.

---

### 5. `liftWhileClause` lifts non-actionable parentheticals into `specialNote`

**Severity:** Medium. Splits into two faces:

- **(a) Inline asides become "Special Note" callouts** — random author commentary like `"(I didn't need to)"` or `"(see below)"` ends up in the dedicated reminder slot, where it reads like a UX accident.
- **(b) Useful inline content disappears from the step body** — Meatloaf step 9 base: glaze ingredient list `"(ketchup, brown sugar, Worcestershire sauce, and mustard)"` lifted into a special note, leaving the visible step as `"…stir together the glaze ingredients . Spread the glaze evenly…"`. The inline list was the entire point of the step.

**Evidence:** 5 false-positive lifts in the BudgetBytes corpus (chicken-noodle-soup S14/S15, meatloaf S9, meatballs S11/S12). Pattern: any non-empty `(…)` triggers the lift, regardless of what's inside.

**Root cause:** `liftWhileClause(_:)` (`RecipeImporter.swift:1112`) uses the regex `\s*\(([^()]+)\)\s*` and lifts the content unconditionally:

```swift
if let parens = try? #/\s*\(([^()]+)\)\s*/#.firstMatch(in: text) {
    let inside = String(parens.output.1).trimmingCharacters(in: .whitespaces)
    // ...
    if !main.isEmpty, !inside.isEmpty {
        var copy = step
        copy.text = main
        copy.specialNote = capitalizingFirst(inside)
        return copy
    }
}
```

The function doc-comment makes clear the design intent (`"start preheating while X"`-style hints), but the implementation accepts every non-empty parenthetical.

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

This preserves the original "(start preheating while X)" / "(while dough is proofing)" lift the parser was designed for, and stops molesting plain inline asides.

**Test evidence:** All 5 false-positive lifts in the corpus eliminated. Bare-`while X` tail still lifts (verified with synthetic input: `"Stir mixture while butter melts"` → `text="Stir mixture"`, `note="While butter melts"`).

**Why no regression risk on TikTok captions:** the AI-parser path already catches `while X` clauses via the LLM. The regex pipeline's job is to be *deterministic* and *correct*. A few "real" parenthetical reminders that *don't* start with the gated keywords (e.g., a creator who writes `"Preheat oven (oven should be hot before next step)"` — no `while`/`start`/`begin`) would no longer auto-lift, but those edge cases are rare and the visible step text reads fine when they don't lift.

---

### 6. `recipeYield` as `QuantitativeValue` returns nil

**Severity:** Medium. Schema.org allows `recipeYield` to be a `QuantitativeValue` object (`{"@type": "QuantitativeValue", "value": 6, "unitText": "servings"}`); some sites publish it that way (less common than the array/string forms but well-attested).

**Evidence:** Not in BudgetBytes corpus. Code-level analysis only.

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

**Test evidence:** None yet (no QuantitativeValue in corpus). Fix is defensive and mechanical.

---

### 7. HTML tags inside `description` and step `text`

**Severity:** Medium. WP Recipe Maker, Tasty Recipes, and several other Recipe-card plugins occasionally publish `<p>`, `<br>`, `<a>`, `<strong>` tags inside `recipeInstructions[].text`. The current parser keeps them in step text.

**Evidence:** Not in BudgetBytes corpus (their JSON-LD ships plaintext). Code-level analysis + general knowledge of the WP-plugin ecosystem.

**Root cause:** `decodeHTMLEntities(_:)` resolves `&amp;` etc. but leaves tags intact. There's no `stripHTMLTags` pass.

**Proposed fix:** Add a tag-stripping helper and call it on every string that comes out of the schema:

```swift
private static func stripHTMLTags(_ s: String) -> String {
    s.replacing(#/<[^>]+>/#, with: " ")
        .replacing(#/[ \t]{2,}/#, with: " ")
        .trimmingCharacters(in: .whitespaces)
}

// In populate(_:from:), wrap each value extraction:
if let desc = stringValue(recipe["description"]) {
    draft.summary = stripHTMLTags(decodeHTMLEntities(desc)).trimmed
}
// And similarly for ingredient strings + extracted instruction strings.
```

**Test evidence:** None yet. Fix is conservative — `<[^>]+>` matches well-formed tags only; mismatched literal `<` / `>` in step text (rare, e.g. mathematical inequalities in baking ratios) would survive.

---

### 8. Comma-digit step splitter fires inside dimensional measurements

**Severity:** Medium-low. Visible regression on recipes that describe pan / shape dimensions inline.

**Evidence:** Meatloaf step 7-8 base output: `"Place the meat mixture on a rimmed baking dish and shape it into a loaf that is approximately 4-inches wide"` followed by `"8-inches long, and 2-inches tall."` — the `, 8-inches` triggers the comma-digit boundary split.

**Root cause:** `splitIntoSteps(_:)` comma-boundary regex (`RecipeImporter.swift:998`):

```swift
let commaBoundaryRegex = #/,\s+(?=[Tt]hen\b|\d)/#
```

The lookahead is satisfied by any digit, including `8` in `"8-inches"`. The comment explicitly notes this is a "next-instruction" signal — but the heuristic doesn't distinguish "next instruction starts with `8 minutes`" from "the same dimension list continues with `8-inches long`".

**Proposed fix:** Tighten the lookahead so the digit must NOT be followed by a measurement-shape suffix:

```swift
let commaBoundaryRegex = #/,\s+(?=[Tt]hen\b|\d+(?!\s*-?\s*(?:inches?|cm|mm|ft|feet|"|°|x\d)))/#
```

This excludes `"\d+ inches"`, `"\d+-inches"`, `"\d+x\d+"` patterns. The `(?:°|"|x\d)` covers degree-suffixed temperatures (`"…to 425°, 8-inches…"` rare but possible) and product-style dimensions (`"4x8-inch loaf pan, 2…"`).

**Test evidence:** Not yet validated post-fix because the meatloaf case also requires recursive splitting (Finding 4) to fully recover — the fix would prevent the false split, but the legit sentence boundary later in the same step still needs splitting via the recursive pass. Combined: `"…that is approximately 4-inches wide, 8-inches long, and 2-inches tall."` stays as one step (correct), and the surrounding sentence boundaries continue to split as appropriate.

---

## Test results

The Python harness (`outputs/harness/`) was run twice on the BudgetBytes corpus:

```
Baseline (current Swift behavior):
- 5 recipes parsed, all with empty prepTimeMinutes
- 7 steps with orphan space-punctuation (across 4 recipes)
- 5 false-positive parenthetical lifts
- 1 unparsed range-quantity ingredient

After fixes 1-5:
- 5 recipes with correctly-extracted prepTime ("5", "5", "15", "15", "25")
- 0 steps with orphan space-punctuation
- 0 false-positive parenthetical lifts
- 0 unparsed range-quantity ingredients
- Step counts: 17→19 / 12→13 / 8→9 / 29→31 / 22→22 — gains came from recursive sentence-boundary splits of multi-sentence remainders
```

Re-running once Chrome perms unblock the other three sites is the right next step. I'd expect:
- **AllRecipes** (Dotdash Meredith CMS): typically clean JSON-LD, may surface fix 7 (HTML in description) and fix 6 (`recipeYield` as QuantitativeValue); historical pattern is high publishing volume + some legacy-formatted recipes mixed in.
- **King Arthur Baking**: heavy use of `HowToSection` for multi-stage recipes (the dough vs. the topping vs. the glaze). Their existing handling (`extractInstructions` recurses into `HowToSection.itemListElement`) should work, but section labels are silently dropped — possible UX improvement (preserve `HowToSection.name` as a step-prefix) but not a bug.
- **HelloFresh**: `@graph`-nested Recipe + frequent use of nested `step` substructures; possible quirks in their metric/imperial duplication of ingredients.

---

## Files to modify (line-level)

| Finding | File | Function | Approx. lines |
|---|---|---|---|
| 1 | `ios-native/Sources/Lib/RecipeSchemaParser.swift` | `populate(_:from:)` | after L129 |
| 2 | `ios-native/Sources/Lib/RecipeImporter.swift` | `liftWhileClause(_:)` | L1115-1121 |
| 3 | `ios-native/Sources/Lib/RecipeImporter.swift` | `parseIngredients(_:)` + `isQuantityToken(_:)` | L729-735 + L1180-1185 |
| 4 | `ios-native/Sources/Lib/RecipeImporter.swift` | `splitIntoSteps(_:)` | L961 (rename body to `splitIntoStepsOnePass`, add recursive wrapper) |
| 5 | `ios-native/Sources/Lib/RecipeImporter.swift` | `liftWhileClause(_:)` | L1112 (gate the parenthetical-extraction branch) |
| 6 | `ios-native/Sources/Lib/RecipeSchemaParser.swift` | `extractServings(_:)` | L182-198 |
| 7 | `ios-native/Sources/Lib/RecipeSchemaParser.swift` | new `stripHTMLTags(_:)` helper + 3 call sites in `populate(_:from:)` | L88-135 |
| 8 | `ios-native/Sources/Lib/RecipeImporter.swift` | `splitIntoSteps(_:)` comma-boundary regex | L998 |

The Swift parser regex literals (`#/.../#`) are Swift 5.7+ — same syntax as elsewhere in the file.

---

## Things I couldn't verify in this pass

- **AllRecipes / KingArthurBaking / HelloFresh corpus**: blocked on Chrome extension site permissions during the session. Suggested rerun once perms are sorted.
- **`RecipeAIParser` interaction**: the AI parser is a different code path, only fires on TikTok / Pinterest / OG-fallback, and uses FoundationModels. Out of scope here. The deterministic `RecipeImporter` fixes propagate into `parseBestOf` because it calls `RecipeImporter.parse` for the regex-side draft.
- **Any code path that runs in iOS 26 simulator/device but not in Foundation alone** (e.g., `Foundation.URLSession` quirks, `Data` decoding edge cases). The harness uses Python's network and JSON stack, which are functionally equivalent for the JSON-LD parsing pieces but not byte-identical.

---

## Where the harness lives

The Python harness, corpus, and run scripts are in the Cowork session's outputs folder (not committed). For an agent picking this up later: the harness can be re-created from `RecipeSchemaParser.swift` and `RecipeImporter.swift` in about an hour by porting the same regex/string logic. Keeping it out of the repo (it's not Swift, it's not part of the build) avoids a "second source of truth" drift problem.

If you want to keep it long-term: move it to a separate `tools/parser-harness/` directory with its own README, and treat it as advisory only — the Swift source is canonical.
