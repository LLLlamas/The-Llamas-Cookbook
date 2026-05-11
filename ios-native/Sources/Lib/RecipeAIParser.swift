import Foundation
import FoundationModels

/// On-device LLM recipe parser, gated to iOS 26+ with Apple Intelligence
/// enabled. Used as the *first* attempt on the messy URL-import paths
/// (TikTok captions, Pinterest pin descriptions, blog OG-fallback
/// summaries) and on the OCR-import path (cookbook pages, magazine
/// clippings, handwritten cards) where free-form prose hides the
/// structure. Returns nil when the model is unavailable so the caller
/// can fall back to `RecipeImporter.parse` — the regex pipeline stays
/// the universal floor for older devices, devices without Apple
/// Intelligence, and the model-not-ready window after first install.
///
/// **Why only the messy paths**: a user who pastes pre-structured text
/// already did the hard work; spending 2-5 seconds running the LLM on
/// clean input would be a regression. Schema.org JSON-LD likewise has
/// real structure already, no LLM needed. The LLM earns its keep on
/// social-media captions and OCR'd cookbook pages where the structure
/// is implicit.
enum RecipeAIParser {

    /// True when the on-device language model is ready to answer.
    /// Returns false on iOS < 26, on devices without Apple Intelligence,
    /// when the user hasn't enabled it, or when the model is still
    /// downloading after first launch — every "no" path bows to the
    /// regex fallback rather than throwing.
    static var isAvailable: Bool {
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        return false
    }

    /// Parse a free-form recipe blob into a structured draft. Returns
    /// nil when the model is unavailable, when the result fails the
    /// minimum-quality gate (no usable steps or ingredients), or when
    /// the model errors mid-generation. The caller treats nil as
    /// "fall back to regex" rather than as a hard failure.
    ///
    /// `sourceUrl` is folded into the returned draft so the editor
    /// preserves attribution even when the AI didn't surface it itself.
    @available(iOS 26.0, *)
    static func parse(_ text: String, sourceUrl: String?) async -> DraftRecipe? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isAvailable else { return nil }

        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Recipe text to parse:\n\n\(trimmed)"
        do {
            let response = try await session.respond(
                to: prompt,
                generating: ParsedRecipe.self
            )
            let draft = response.content.toDraft(sourceUrl: sourceUrl)
            return passesQualityGate(draft) ? draft : nil
        } catch {
            // Any LM error (model-not-ready race, generation timeout,
            // schema validation failure) drops us to the regex path.
            // We deliberately swallow rather than surface, since the
            // user gets a working result either way.
            return nil
        }
    }

    /// Best-of parse: run an AI parser and the regex pipeline against
    /// the same text, then pick whichever produced the more usable
    /// draft. Centralized here so each call site (URL importer for
    /// TikTok / Pinterest / OG-fallback, OCR importer for cookbook
    /// pages) calls one line.
    ///
    /// Returns nil only when *both* parsers produce nothing worth
    /// previewing — at which point each call site falls back to the
    /// existing seed-text-and-edit flow rather than dropping the user
    /// into an empty editor.
    ///
    /// **Parser priority:**
    /// 1. Claude API (Haiku) — best step splitting and ingredient
    ///    extraction; available on all iOS versions and device tiers
    ///    when an API key is configured. Used when `isConfigured`.
    /// 2. Apple Intelligence — on-device, iOS 26+ capable-hardware
    ///    only. Falls back to here when Claude is unconfigured or
    ///    returns nil (API error, quality gate fail).
    /// 3. Regex pipeline — universal baseline; always runs in parallel
    ///    so `pickBetterDraft` can compare any AI result against it.
    static func parseBestOf(_ text: String, sourceUrl: String?) async -> DraftRecipe? {
        let urlString = sourceUrl ?? ""
        let regexDraft = makeRegexDraft(text, sourceUrl: urlString)

        // Claude API path — preferred when configured. Works on all iOS
        // versions, all device tiers; no Apple Intelligence requirement.
        if AnthropicRecipeParser.isConfigured {
            let claudeDraft = await AnthropicRecipeParser.parse(text, sourceUrl: sourceUrl)
            if let winner = pickBetterDraft(ai: claudeDraft, regex: regexDraft) {
                return winner
            }
            // Claude returned nil (key valid but API error / quality
            // gate fail) — fall through to Apple Intelligence rather
            // than returning only the regex result.
        }

        // Apple Intelligence path — iOS 26+, A17/M-chip hardware only.
        guard #available(iOS 26.0, *), isAvailable else {
            return regexDraft
        }
        let aiDraft = await parse(text, sourceUrl: sourceUrl)
        return pickBetterDraft(ai: aiDraft, regex: regexDraft)
    }

    /// Run the regex pipeline and stamp the source URL on it, gated
    /// by the same minimum bar the AI quality gate uses (title + at
    /// least one ingredient or step). Anything weaker isn't worth
    /// auto-jumping to the editor for.
    private static func makeRegexDraft(_ text: String, sourceUrl: String) -> DraftRecipe? {
        var draft = RecipeImporter.parse(text)
        if !sourceUrl.isEmpty { draft.sourceUrl = sourceUrl }
        let hasTitle = !draft.title.trimmed.isEmpty
        let hasContent = !draft.ingredients.isEmpty || !draft.steps.isEmpty
        return (hasTitle && hasContent) ? draft : nil
    }

    /// Compare two parser outputs and pick the higher-quality one.
    /// Heuristics, in order:
    ///
    /// 1. If only one side produced a draft, use it.
    /// 2. If the AI's longest step is implausibly long (> 200 chars)
    ///    it almost certainly mashed several actions together — regex
    ///    wins. A healthy cooking step is typically 50-100 chars; the
    ///    threshold is well above that to avoid false positives on
    ///    legitimately wordy single-action steps.
    /// 3. If the AI extracted noticeably more ingredients than regex
    ///    (≥ 3 ingredients AND > 2x regex's count), trust AI — it's
    ///    reading the structure correctly while regex is dumping
    ///    ingredient lines into the step list. Common failure mode
    ///    on OCR'd handwritten cards where typos like "I cup of flar"
    ///    or "1og chocolate chips" fall through `looksLikeIngredient`
    ///    and end up as steps. This short-circuits the step-count
    ///    tie-breaker below, which would otherwise reward regex's
    ///    bloated step list.
    /// 4. If the regex pulled out 5+ steps and the AI got fewer than
    ///    70% of that count, the AI under-split — regex wins.
    /// 5. If the regex pulled out 3+ ingredients and the AI got fewer
    ///    than half of that count, the AI mis-classified ingredient
    ///    lines as steps — regex wins. Mirror of the step under-split
    ///    guard above.
    /// 6. Otherwise the AI wins. It generally beats regex on title
    ///    cleanup, ingredient quantity/unit splitting, and lifting
    ///    "while X" reminders into special notes.
    private static func pickBetterDraft(ai: DraftRecipe?, regex: DraftRecipe?) -> DraftRecipe? {
        guard let ai = ai else { return regex }
        guard let regex = regex else { return ai }

        let aiLongest = ai.steps.map(\.text.count).max() ?? 0
        if aiLongest > 200 { return regex }

        let aiIngredients = ai.ingredients.count
        let regexIngredients = regex.ingredients.count

        // AI is reading ingredients much better than regex → trust
        // AI's overall structure even if its step count looks small
        // by comparison. Without this short-circuit, noisy OCR input
        // where regex parses ingredients-shaped lines as steps
        // (inflating its step count) would beat AI's correct
        // interpretation.
        if aiIngredients >= 3, regexIngredients * 2 < aiIngredients {
            return ai
        }

        let aiSteps = ai.steps.count
        let regexSteps = regex.steps.count
        if regexSteps >= 5, aiSteps * 10 < regexSteps * 7 {
            return regex
        }

        if regexIngredients >= 3, aiIngredients * 2 < regexIngredients {
            return regex
        }

        return ai
    }

    /// Minimum bar for "AI got something useful": title and at least
    /// one ingredient OR one step. Below that we'd be handing the
    /// editor an empty preview, which is worse UX than letting the
    /// regex parser take a swing at the same input.
    private static func passesQualityGate(_ draft: DraftRecipe) -> Bool {
        let hasTitle = !draft.title.trimmed.isEmpty
        let hasContent = !draft.ingredients.isEmpty || !draft.steps.isEmpty
        return hasTitle && hasContent
    }

    /// Instructions tuned for both caption-style and cookbook-page
    /// input. Each rule maps to a real failure mode we've seen in the
    /// wild: TikTok handle suffixes, glued steps, parenthetical
    /// "while X" hints, ranges, and OCR'd cookbook headers. Kept
    /// compact — the model behaves better with directives than with
    /// prose. Two worked examples (caption + cookbook) pin the most
    /// common shapes the parser sees.
    /// Shared system-prompt used by both the on-device Apple Intelligence
    /// path and the Claude API path in `AnthropicRecipeParser`. Keeping
    /// one canonical copy ensures both paths behave identically when
    /// the instructions are updated. Internal (not private) so
    /// `AnthropicRecipeParser` can reference it without duplication.
    static let instructions: String = """
    You parse messy recipe text into structured fields. Inputs vary: \
    social-media captions (TikTok, Instagram, Pinterest, recipe blogs) \
    and OCR'd printed pages (cookbooks, magazines, handwritten cards). \
    Follow these rules:

    1. Title: the dish name. Usually the first non-empty line. Strip \
       social-media decorations like @handles, #hashtags, emoji runs, \
       and "RECIPE:" / "Recipe -" / "Recipe👇" prefixes.
    2. Summary: short blurb if the caption has one. Empty otherwise.
    3. Servings: numeric prefix when stated ("Serves 4" -> "4", \
       "Yield: 1 loaf" -> "1", "Makes 12 cookies" -> "12", \
       "8 servings" -> "8", "12 portions" -> "12"). Reverse-form \
       ("8 servings", "4 portions") is common on handwritten cards \
       and cookbook pages — match it, do NOT classify it as a step. \
       Empty when not stated.
    4. cookTimeMinutes: total cook/bake minutes when stated ("Cook \
       45 min", "Bake: 60 min", "Total: 1 hour" -> "60", \
       "10 min bake time" -> "10", "45 minutes cook" -> "45"). Empty \
       when not stated.
    5. prepTimeMinutes: prep minutes when stated separately from \
       cook time ("Prep: 15 min" -> "15", "20 min prep time" -> "20", \
       "30 minutes prep" -> "30"). Reverse-form is common on \
       handwritten cards — pull it into the field, do NOT leave it \
       in the step list. Empty when not stated or when the source \
       only gives a single total.
    6. Ingredients: split each into quantity / unit / name. \
       "2 cups flour" -> quantity "2", unit "cup", name "flour". \
       "salt to taste" -> quantity "", unit "", name "salt to taste". \
       "1 1/2 tbsp butter" -> quantity "1 1/2", unit "tbsp", name "butter". \
       Use canonical singular units (cup, tbsp, tsp, oz, lb, g, kg, ml, l).
    7. Steps: ONE cooking action per step — never glue multiple \
       actions into a single step. Each line break, each "then", each \
       comma-then transition, and each separate sentence is its own \
       step. "Let sit for 1 hour, then do 8 stretch and folds" is TWO \
       steps. "Mix dough. Wait 1 hour. Bake 30 min." is THREE steps. \
       Strip leading numbering like "Step 1:" or "1.". When in doubt, \
       split into MORE steps rather than fewer — keeping waits and \
       actions on separate lines is what makes Cook Mode work.
    8. needsTimer: true when a step mentions a duration ("for 30 \
       minutes", "1-2 hours"). False when the duration is part of a \
       compound noun ("8 hour sourdough", "30 minute meal").
    9. specialNote: only set this when the step has a parenthetical \
       reminder or a "while X is happening" clause. Move that phrase \
       to specialNote and keep the main action in the step text. \
       Empty otherwise.
    10. Strip trailing creator handles (@username) and hashtag runs \
        from every field; they aren't part of the recipe.
    11. Ingredient vs. step boundary: INGREDIENTS contain food items \
        with quantities only. Any line that contains a cooking verb \
        (preheat, mix, add, stir, cook, bake, heat, toss, drain, \
        combine, arrange, spread, serve, set, blend, break, pat, \
        coat) belongs in STEPS — even if OCR placed it between \
        ingredient lines. When in doubt, ask: "is this something I \
        buy at the store or something I do?" If it's something I do, \
        it's a step.
    12. Action-prefix step headers: Lines beginning with "Prep:", \
        "To Bake:", "To Air Fry:", "To Cook:", "To Make:", "Serve:", \
        or "To Serve:" are ALWAYS steps. Strip the prefix label and \
        put the action text into steps. NEVER classify these as \
        ingredients — even if they appear between ingredient lines \
        in the OCR output.
    13. Alternative cooking methods: When a recipe offers two methods \
        separated by "or" (e.g. oven vs. air fryer), include both as \
        consecutive steps with a short method label: "Oven: ..." then \
        "Air fryer: ...". Do not drop either method.
    14. Sidebars and bonus sections: Printed cookbook pages often \
        contain sidebars ("DIY X", "Make your own", "Variation", \
        "Tips", "Homemade X"). These are separate from the main \
        recipe. Collect the sidebar content as a single specialNote \
        on the last step, or omit it. NEVER split sidebar content \
        into main recipe steps or ingredients.
    15. OCR correction — numbers and fractions: Printed-book OCR \
        frequently misreads characters. Apply these corrections by \
        context: '#' or a capital 'A' as a standalone quantity → '1'; \
        a garbled fraction before a spice in a clearly small-amount \
        context (e.g. "15 tsp salt", "1/5 tsp salt") → '½ tsp'; \
        temperatures "4257F" / "4257°F" → "425°F", "3757F" → \
        "375°F", "3507F" → "350°F" (oven temps 300–500°F; air fryer \
        325–425°F — pick the closest plausible value). Apply silently.

    Worked example #1 (TikTok caption):

    INPUT:
    Recipe👇🏻Same day sourdough is the best sourdough!😍🙌🏻 100g \
    active starter 390g water 530g bread flour 10g salt Combine into \
    shaggy dough Let sit for 1 hour, then do 8 stretch and folds. Let \
    sit on counter for 3-4 hours. Preheat Dutch oven inside oven to \
    450° (start preheating while dough is proofing) Bake for 30 \
    minutes with lid on. Enjoy your 8 hour sourdough!🥰

    OUTPUT:
    title: "Same day sourdough"
    summary: ""
    servings: ""
    cookTimeMinutes: ""
    prepTimeMinutes: ""
    ingredients:
      - quantity "100", unit "g", name "active starter"
      - quantity "390", unit "g", name "water"
      - quantity "530", unit "g", name "bread flour"
      - quantity "10",  unit "g", name "salt"
    steps:
      - text "Combine into shaggy dough", needsTimer false, specialNote ""
      - text "Let sit for 1 hour", needsTimer true, specialNote ""
      - text "Do 8 stretch and folds", needsTimer false, specialNote ""
      - text "Let sit on counter for 3-4 hours", needsTimer true, specialNote ""
      - text "Preheat Dutch oven inside oven to 450°", needsTimer false, \
        specialNote "Start preheating while dough is proofing"
      - text "Bake for 30 minutes with lid on", needsTimer true, specialNote ""
      - text "Enjoy your 8 hour sourdough!", needsTimer false, specialNote ""

    Note how "Let sit for 1 hour, then do 8 stretch and folds" became \
    TWO steps; how the parenthetical moved into specialNote with the \
    main action kept clean; and how "8 hour sourdough" did NOT get \
    needsTimer because the duration is part of the dish name, not a \
    timing instruction.

    Worked example #2 (printed cookbook page, OCR'd):

    INPUT:
    Classic Banana Bread
    Yield: 1 loaf • Prep: 15 min • Bake: 60 min

    INGREDIENTS
    3 ripe bananas, mashed
    1/3 cup melted butter
    3/4 cup sugar
    1 egg, beaten
    1 tsp vanilla extract
    1 tsp baking soda
    Pinch of salt
    1 1/2 cups all-purpose flour

    DIRECTIONS
    1. Preheat oven to 350°F. Grease a 4x8-inch loaf pan.
    2. In a large bowl, mash bananas until smooth.
    3. Stir melted butter into bananas. Mix in sugar, egg, and vanilla.
    4. Sprinkle baking soda and salt over mixture; mix in.
    5. Add flour; mix until just combined.
    6. Pour batter into prepared pan. Bake 60 minutes.
    7. Cool on rack before slicing.

    OUTPUT:
    title: "Classic Banana Bread"
    summary: ""
    servings: "1"
    cookTimeMinutes: "60"
    prepTimeMinutes: "15"
    ingredients:
      - quantity "3", unit "", name "ripe bananas, mashed"
      - quantity "1/3", unit "cup", name "melted butter"
      - quantity "3/4", unit "cup", name "sugar"
      - quantity "1", unit "", name "egg, beaten"
      - quantity "1", unit "tsp", name "vanilla extract"
      - quantity "1", unit "tsp", name "baking soda"
      - quantity "", unit "pinch", name "salt"
      - quantity "1 1/2", unit "cup", name "all-purpose flour"
    steps:
      - text "Preheat oven to 350°F", needsTimer false, \
        specialNote "Grease a 4x8-inch loaf pan"
      - text "In a large bowl, mash bananas until smooth", needsTimer false, specialNote ""
      - text "Stir melted butter into bananas. Mix in sugar, egg, and vanilla", needsTimer false, specialNote ""
      - text "Sprinkle baking soda and salt over mixture; mix in", needsTimer false, specialNote ""
      - text "Add flour; mix until just combined", needsTimer false, specialNote ""
      - text "Pour batter into prepared pan. Bake 60 minutes", needsTimer true, specialNote ""
      - text "Cool on rack before slicing", needsTimer false, specialNote ""

    Notice how "Yield: 1 loaf" became servings "1" (the numeric prefix); \
    "Prep: 15 min" became prepTimeMinutes "15"; "Bake: 60 min" became \
    cookTimeMinutes "60". Numbered "1." / "2." prefixes were stripped \
    from each step. The parenthetical-equivalent "Grease a 4x8-inch \
    loaf pan" stayed grouped with the preheat step as a specialNote \
    since it's a setup hint, not a separate cooking action.

    Worked example #3 (handwritten card, OCR'd, reverse-form metadata):

    INPUT:
    Muffins
    8 servings
    20 min prep time

    1 cup of flour
    1 & 1/2 cup water
    2 tsp sugar
    10g chocolate chips

    Mix in bowl
    Shape into muffins
    Bake at 425 degrees, 10 mins

    OUTPUT:
    title: "Muffins"
    summary: ""
    servings: "8"
    cookTimeMinutes: ""
    prepTimeMinutes: "20"
    ingredients:
      - quantity "1",     unit "cup", name "flour"
      - quantity "1 1/2", unit "cup", name "water"
      - quantity "2",     unit "tsp", name "sugar"
      - quantity "10",    unit "g",   name "chocolate chips"
    steps:
      - text "Mix in bowl", needsTimer false, specialNote ""
      - text "Shape into muffins", needsTimer false, specialNote ""
      - text "Bake at 425 degrees, 10 mins", needsTimer true, specialNote ""

    Critical: "8 servings" became servings "8" — NOT a step. \
    "20 min prep time" became prepTimeMinutes "20" — NOT a step. \
    Reverse-form metadata is a recurring shape on handwritten cards \
    and cookbook pages; lifting it into the right field is what keeps \
    the step list clean. "of" in "1 cup of flour" is a connector and \
    is dropped from the name.

    Worked example #4 (printed cookbook page, OCR'd — action headers \
    bled into ingredient list, two cooking methods, DIY sidebar):

    INPUT:
    Quick Crispy Tofu
    Serves 4 · 20 Minutes
    A simple dish celebrating bold seasoning.

    1 (14-oz) block firm tofu, drained
    Prep: Preheat oven to 4257F. Pat tofu dry, break into chunks. In \
    a bowl, toss with cornstarch and seasoning until evenly coated.
    # tablespoon cornstarch
    A tablespoon seasoning blend
    15 tsp — salt
    To Bake: Arrange pieces on a greased sheet pan; bake 25 minutes, \
    flipping halfway, until crispy.
    or
    To Air Fry: Preheat air fryer to 3757F. Cook 10-15 minutes, \
    shaking pan occasionally.
    Serve: Serve warm with rice or veggies.

    DIY SEASONING BLEND
    Mix 2 tbsp black pepper, 1 tbsp flaky sea salt, 1 tsp onion \
    powder, 1 tsp garlic powder. Blitz in a spice grinder.

    OUTPUT:
    title: "Quick Crispy Tofu"
    summary: "A simple dish celebrating bold seasoning."
    servings: "4"
    cookTimeMinutes: "20"
    prepTimeMinutes: ""
    ingredients:
      - quantity "1", unit "", name "(14-oz) block firm tofu, drained"
      - quantity "1", unit "tbsp", name "cornstarch"
      - quantity "1", unit "tbsp", name "seasoning blend"
      - quantity "½", unit "tsp", name "salt"
    steps:
      - text "Preheat oven to 425°F", needsTimer false, specialNote ""
      - text "Pat tofu dry, then break into chunks", needsTimer false, specialNote ""
      - text "In a bowl, toss tofu with cornstarch and seasoning until evenly coated", needsTimer false, specialNote ""
      - text "Oven: Arrange on a greased sheet pan; bake 25 minutes, flipping halfway, until crispy", needsTimer true, specialNote ""
      - text "Air fryer: Preheat to 375°F. Cook 10-15 minutes, shaking occasionally", needsTimer true, specialNote ""
      - text "Serve warm with rice or veggies", needsTimer false, specialNote "DIY seasoning blend: Mix 2 tbsp black pepper, 1 tbsp flaky salt, 1 tsp onion powder, 1 tsp garlic powder."

    Notice: "Prep:" content moved to steps, not ingredients — even \
    though OCR placed it between ingredient lines. "#" and "A" OCR \
    errors corrected to "1". "15 tsp — salt" → "½ tsp salt". \
    "4257F" → "425°F", "3757F" → "375°F". Both oven and air fryer \
    methods preserved with labels. DIY sidebar collapsed into a \
    specialNote on the final step, not broken into main steps.
    """
}

// MARK: - Generable schema

/// Schema the model fills in. Top-level fields mirror `DraftRecipe` so
/// the conversion at the edge is straight passthrough; nested types use
/// the same vocabulary the rest of the app already speaks (quantity /
/// unit / name for ingredients; text + needsTimer + specialNote for
/// steps). `@Guide` strings are short on purpose — the heavy guidance
/// lives in the session instructions, leaving room here for field-level
/// reminders that catch the most common drift.
@available(iOS 26.0, *)
@Generable
private struct ParsedRecipe {
    @Guide(description: "The recipe name. Strip @-handles and hashtags.")
    let title: String

    @Guide(description: "Short blurb if any; empty otherwise.")
    let summary: String

    @Guide(description: "Servings count if stated ('Serves 4', 'Yield: 12 cookies'). Empty otherwise.")
    let servings: String

    @Guide(description: "Total cook/bake minutes if stated. Empty otherwise.")
    let cookTimeMinutes: String

    @Guide(description: "Prep minutes if stated separately from cook time. Empty otherwise.")
    let prepTimeMinutes: String

    @Guide(description: "Each ingredient broken into pieces.")
    let ingredients: [ParsedIngredient]

    @Guide(description: "Cooking steps in order, one action per step.")
    let steps: [ParsedStep]

    @Generable
    struct ParsedIngredient {
        @Guide(description: "Number(s) with optional fraction: '2', '1 1/2'. Empty if none.")
        let quantity: String
        @Guide(description: "Singular unit: cup, tbsp, tsp, oz, lb, g, kg, ml, l. Empty if none.")
        let unit: String
        @Guide(description: "Ingredient name only — no quantity, no unit.")
        let name: String
    }

    @Generable
    struct ParsedStep {
        @Guide(description: "The cooking action. No leading 'Step N:' or '1.'.")
        let text: String
        @Guide(description: "True when the step mentions a duration to time.")
        let needsTimer: Bool
        @Guide(description: "Parenthetical reminder or 'while X' clause. Empty otherwise.")
        let specialNote: String
    }
}

@available(iOS 26.0, *)
private extension ParsedRecipe {
    /// Convert the model's structured response into a `DraftRecipe`.
    /// Each field is run through the regex pipeline's deterministic
    /// post-process (`cleanTitle`, `enrichAIStep`) so the AI gets the
    /// hard structural call but regex gets the last word on the rules
    /// it's already encoding — title decoration stripping and the
    /// compound-noun timer guard. Belt and suspenders for the cases
    /// where small on-device models drift from the prompt.
    func toDraft(sourceUrl: String?) -> DraftRecipe {
        var draft = DraftRecipe()
        draft.title = RecipeImporter.cleanTitle(title.trimmed)
        draft.summary = summary.trimmed
        draft.servings = servings.trimmed
        draft.cookTimeMinutes = cookTimeMinutes.trimmed
        draft.prepTimeMinutes = prepTimeMinutes.trimmed
        if let sourceUrl, !sourceUrl.isEmpty {
            draft.sourceUrl = sourceUrl
        }
        draft.ingredients = ingredients.compactMap { ing in
            let name = ing.name.trimmed
            guard !name.isEmpty else { return nil }
            return DraftIngredient(
                quantity: ing.quantity.trimmed,
                unit: ing.unit.trimmed,
                name: name
            )
        }
        draft.steps = steps.compactMap { step in
            let text = step.text.trimmed
            guard !text.isEmpty else { return nil }
            let note = step.specialNote.trimmed
            let raw = DraftStep(
                text: text,
                needsTimer: step.needsTimer,
                specialNote: note.isEmpty ? nil : note
            )
            return RecipeImporter.enrichAIStep(raw)
        }
        // Orphan-duration merge — the regex pipeline applies the same
        // pass via `RecipeImporter.parse`. Running it here keeps the
        // best-of picker comparing two drafts that have both gone
        // through the same final-shape normalization.
        draft.steps = RecipeImporter.mergeOrphanDurationSteps(draft.steps)
        return draft
    }
}
