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
    /// - Parameter preferHighQuality: When true, routes the Claude call
    ///   through Sonnet instead of Haiku. Use for photo import where OCR
    ///   noise warrants stronger instruction following. Link import should
    ///   leave this false (Haiku handles clean text well at lower cost).
    static func parseBestOf(_ text: String, sourceUrl: String?, preferHighQuality: Bool = false) async -> DraftRecipe? {
        let urlString = sourceUrl ?? ""
        let regexDraft = makeRegexDraft(text, sourceUrl: urlString)

        // Claude API path — preferred when configured. Works on all iOS
        // versions, all device tiers; no Apple Intelligence requirement.
        if AnthropicRecipeParser.isConfigured {
            let model = preferHighQuality ? AnthropicRecipeParser.Model.sonnet : AnthropicRecipeParser.Model.haiku
            let claudeDraft = await AnthropicRecipeParser.parse(text, sourceUrl: sourceUrl, model: model)
            if let winner = pickBetterDraft(ai: claudeDraft, regex: regexDraft, sourceText: text) {
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
        return pickBetterDraft(ai: aiDraft, regex: regexDraft, sourceText: text)
    }

    /// Vision-first parse: send up to 3 page images directly to Claude
    /// vision (Sonnet) via the Cloudflare proxy. Returns a
    /// `VisionParseOutcome` so the caller can distinguish quota/auth
    /// errors from parse failures.
    ///
    /// - `.error` is non-nil → surface the appropriate UI state (auth
    ///   gate, upsell card, daily-limit card); do not fall through to OCR.
    /// - `.error` is nil, `.draft` is nil → parse failed; fall through to OCR.
    /// - `.error` is nil, `.draft` is non-nil → success; apply quality gate.
    ///
    /// - Parameter images: JPEG-encoded page bytes prepared via
    ///   `ImageProcessing.prepare(_:for:.aiVision)`.
    /// - Parameter sourceUrl: Optional source URL stamped on the draft.
    static func parseImages(_ images: [Data], sourceUrl: String?) async -> VisionParseOutcome {
        guard !images.isEmpty else { return VisionParseOutcome() }
        guard AnthropicRecipeParser.isConfigured else { return VisionParseOutcome() }
        var outcome = await AnthropicRecipeParser.parseImages(
            images,
            sourceUrl: sourceUrl,
            model: AnthropicRecipeParser.Model.sonnet
        )
        // Apply quality gate to the draft; keep error and cacheHit unchanged.
        if let draft = outcome.draft, !passesQualityGate(draft) {
            outcome.draft = nil
        }
        return outcome
    }

    /// Streaming variant — same as `parseImages` but Anthropic returns
    /// SSE deltas and the preview UI binds to `streamingState` to render
    /// title / ingredients / steps as they arrive. Used by the photo
    /// import path so users see the recipe materialize ~1.5 s after
    /// request fires instead of waiting 6-8 s for the buffered response.
    static func parseImagesStreaming(
        _ images: [Data],
        sourceUrl: String?,
        streamingState: StreamingRecipeState
    ) async -> VisionParseOutcome {
        guard !images.isEmpty else { return VisionParseOutcome() }
        guard AnthropicRecipeParser.isConfigured else { return VisionParseOutcome() }
        var outcome = await AnthropicRecipeParser.parseImagesStreaming(
            images,
            sourceUrl: sourceUrl,
            streamingState: streamingState,
            model: AnthropicRecipeParser.Model.sonnet
        )
        if let draft = outcome.draft, !passesQualityGate(draft) {
            outcome.draft = nil
        }
        return outcome
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
    /// 3. If the AI title contains dish-name words that do not appear
    ///    in the source text, carry over the regex title instead. OCR
    ///    cards often have no explicit title; an invented title is
    ///    worse than a literal rough one the user can edit.
    /// 4. If AI returned only one or two steps, but regex found a
    ///    fuller step list and any AI step contains unsupported action
    ///    words, prefer regex. This catches LLM "plausible but not on
    ///    the page" output such as turning an ingredient/header line
    ///    into fake steps.
    /// 5. If the AI extracted noticeably more ingredients than regex
    ///    (≥ 3 ingredients AND > 2x regex's count), trust AI — it's
    ///    reading the structure correctly while regex is dumping
    ///    ingredient lines into the step list. Common failure mode
    ///    on OCR'd handwritten cards where typos like "I cup of flar"
    ///    or "1og chocolate chips" fall through `looksLikeIngredient`
    ///    and end up as steps. This short-circuits the step-count
    ///    tie-breaker below, which would otherwise reward regex's
    ///    bloated step list.
    /// 6. If the regex pulled out 5+ steps and the AI got fewer than
    ///    70% of that count, the AI under-split — regex wins.
    /// 7. If the regex pulled out 3+ ingredients and the AI got fewer
    ///    than half of that count, the AI mis-classified ingredient
    ///    lines as steps — regex wins. Mirror of the step under-split
    ///    guard above.
    /// 8. Otherwise the AI wins. It generally beats regex on title
    ///    cleanup, ingredient quantity/unit splitting, and lifting
    ///    "while X" reminders into special notes.
    private static func pickBetterDraft(
        ai: DraftRecipe?,
        regex: DraftRecipe?,
        sourceText: String
    ) -> DraftRecipe? {
        guard var ai = ai else { return regex }

        let sourceTokens = sourceSupportTokens(sourceText)
        guard let regex = regex else {
            let hasUnsupportedTitle = titleLooksInferred(ai.title, sourceTokens: sourceTokens)
            let hasUnsupportedStep = ai.steps.contains {
                stepLooksUnsupported($0.text, sourceTokens: sourceTokens)
            }
            if hasUnsupportedTitle || hasUnsupportedStep {
                return nil
            }
            return ai
        }

        if ai.title.trimmed.isEmpty, !regex.title.trimmed.isEmpty {
            ai.title = regex.title
        }

        let aiLongest = ai.steps.map(\.text.count).max() ?? 0
        if aiLongest > 200 { return regex }

        if titleLooksInferred(ai.title, sourceTokens: sourceTokens) {
            ai.title = regex.title
        }

        let aiSteps = ai.steps.count
        let regexSteps = regex.steps.count
        if aiSteps <= 2,
           regexSteps >= 3,
           ai.steps.contains(where: { stepLooksUnsupported($0.text, sourceTokens: sourceTokens) }) {
            return regex
        }

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

        if regexSteps >= 5, aiSteps * 10 < regexSteps * 7 {
            return regex
        }

        if regexIngredients >= 3, aiIngredients * 2 < regexIngredients {
            return regex
        }

        return ai
    }

    private static func titleLooksInferred(
        _ title: String,
        sourceTokens: Set<String>
    ) -> Bool {
        let tokens = supportTokens(title)
        guard tokens.count >= 2 else { return false }
        let missingCount = tokens.filter { !sourceTokens.contains($0) }.count
        return missingCount > 0 && missingCount * 3 >= tokens.count
    }

    private static func stepLooksUnsupported(
        _ step: String,
        sourceTokens: Set<String>
    ) -> Bool {
        let tokens = supportTokens(step)
        guard tokens.count >= 2 else { return false }
        let missingCount = tokens.filter { !sourceTokens.contains($0) }.count
        return missingCount > 0 && missingCount * 3 >= tokens.count
    }

    private static func sourceSupportTokens(_ text: String) -> Set<String> {
        Set(supportTokens(text))
    }

    private static func supportTokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map(normalizeSupportToken)
            .filter { token in
                token.count >= 3
                    && token.rangeOfCharacter(from: .letters) != nil
                    && !supportTokenStopwords.contains(token)
            }
    }

    private static func normalizeSupportToken(_ raw: String) -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.count > 4, token.hasSuffix("ies") {
            let stem = String(token.dropLast(3))
            if let last = stem.last, "aeiou".contains(last) {
                token = String(token.dropLast())
            } else {
                token = stem + "y"
            }
        } else if token.count > 4,
                  ["ches", "shes", "xes", "zes", "oes"].contains(where: { token.hasSuffix($0) }) {
            token = String(token.dropLast(2))
        } else if token.count > 3, token.hasSuffix("s"), !token.hasSuffix("ss") {
            token = String(token.dropLast())
        }
        return token
    }

    private static let supportTokenStopwords: Set<String> = [
        "and", "are", "but", "for", "from", "into", "not", "off",
        "onto", "out", "per", "the", "then", "than", "that", "this",
        "through", "until", "with", "your",
        "cup", "tbsp", "tablespoon", "tsp", "teaspoon", "ounce", "pound",
        "gram", "kilogram", "milliliter", "liter", "pint", "quart",
        "gallon", "clove", "pinch", "dash", "slice", "piece", "can",
        "stick", "sprig", "head", "bunch", "handful",
    ]

    /// Minimum bar for "AI got something useful": at least one
    /// ingredient OR one step. Title can be empty because the prompt
    /// deliberately tells the model not to invent one when the source
    /// card has no title; `pickBetterDraft` can carry over the regex
    /// title if it has one.
    private static func passesQualityGate(_ draft: DraftRecipe) -> Bool {
        !draft.ingredients.isEmpty || !draft.steps.isEmpty
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
    You parse messy recipe content into structured fields. Inputs vary: \
    social-media captions (TikTok, Instagram, Pinterest, recipe blogs), \
    OCR'd printed pages (cookbooks, magazines, handwritten cards), \
    and direct images of recipe pages (printed cookbooks, magazine \
    clippings, handwritten cards, screenshots). When the input is an \
    image, read the page directly and use visible layout — column \
    structure, section headings, callout boxes, sidebar boxes, \
    bold/italic emphasis, indentation — to disambiguate ingredients \
    from steps and to locate the title and metadata. Every rule below \
    applies whether the input arrived as text or as one or more images. \
    Follow these rules:

    NEVER FABRICATE. Every field you emit must come directly from the \
    source text. If information is not present, leave the field empty \
    or use exactly the words given — do not infer, guess, paraphrase, \
    or fill in plausible-sounding content. This applies to every field: \
    title, summary, servings, times, ingredient quantities and names, \
    step text, and special notes. If no clear title exists, leave it \
    empty — do not invent one from flavors or ingredients. Do not turn \
    an ingredient line like "2 frying chickens split" into fabricated \
    steps like "fry chickens" unless the instruction text itself says \
    to do that.

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
    12. Action-prefix step headers: Any phrase ending in ":" that \
        names a cooking stage or method is a step header — strip it \
        and keep the action text as a step. This includes explicit \
        prefixes like "Prep:", "To Bake:", "To Air Fry:", "Serve:" \
        AND named stage headers like "Prepare the filling:", \
        "Start the batter:", "Finish the batter:", "Bake the cake:", \
        "Make the sauce:", "Assemble:", "For the glaze:", etc. The \
        rule is: if it names what you're about to do and ends in ":", \
        it's a header — strip it, then split the remaining text into \
        individual steps as normal. NEVER classify these headers or \
        their following text as ingredients.
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
    16. Two-column cookbook layout — OCR interleaving: Many cookbook \
        pages place the ingredient list in the left column and the \
        instructions in the right column. OCR reads horizontal bands \
        across both columns, producing interleaved output where a \
        step fragment appears between two ingredient lines. Sort every \
        fragment by content type regardless of OCR order: food item \
        with a quantity → ingredient; cooking action → step. A \
        step fragment sandwiched between ingredient lines is still a \
        step. An ingredient fragment sandwiched between step lines is \
        still an ingredient. Also: partial ingredient lines that were \
        split by the column break (e.g. "1 (14-oz) block firm" on one \
        line, "tofu, drained" on the next) should be rejoined into one \
        ingredient entry.
    17. "To serve:" listings: The pattern "To serve: X, Y" or \
        "For serving: X" appearing anywhere in the text lists serving \
        accompaniments. Add each item as a separate ingredient with \
        empty quantity and unit. Example: "To serve: rice, veggies" \
        → ingredient name "rice" + ingredient name "veggies". Do NOT \
        turn this line into a step.
    18. Alternative cooking methods as specialNote: When two cooking \
        methods are offered as alternatives ("To Bake: … or To Air \
        Fry: …", "Oven: … / Stovetop: …"), use the first method as \
        the main step text and fold the second method into that step's \
        specialNote prefixed with the method label. Example: main \
        step "Bake for 25 minutes, flipping halfway, until crispy", \
        specialNote "Air fryer: Preheat to 375°F. Cook 10–15 minutes, \
        shaking occasionally."
    19. Ingredient quantity suffixes to strip: Remove ", plus more to \
        taste", ", plus more for serving", ", or more to taste", \
        ", to taste" (when appended after a quantity — keep it when \
        the entire ingredient is "salt to taste" with no quantity), \
        ", for serving", ", for greasing", ", for garnish", \
        ", for drizzling", ", optional" (trailing comma form). \
        These are serving/prep notes, not part of the quantity or name. \
        Examples: "½ tsp salt, plus more to taste" → qty "½", unit \
        "tsp", name "salt". "Warm pancake syrup, for serving" → qty \
        "", unit "", name "warm pancake syrup". "Butter, for greasing" \
        → qty "", unit "", name "butter". "salt to taste" (no \
        quantity) → keep as-is.
    20. Parenthetical cross-references in ingredients: Drop \
        parenthetical page or section cross-references from ingredient \
        names — "(see Pro Tips)", "(see Note)", "(page 142)", \
        "(recipe follows)", etc. Keep functional parentheticals that \
        describe the ingredient itself: "(14-oz can)", "(room \
        temperature)", "(toasted)", "(packed)".
    21. Vague or intentionally unmeasured ingredients: Some recipes \
        deliberately omit quantities ("your favorite spices", \
        "good olive oil", "salt"). Preserve the name exactly as \
        written — do not invent a quantity, do not rewrite the name \
        to be more specific. quantity: "", unit: "", name: "your \
        favorite spices" is correct. This applies to "no-recipe" \
        style books and casual handwritten cards alike.
    22. Ingredient section sub-headers: Recipes sometimes split their \
        ingredient list into labeled groups ("FRENCH TOAST:", \
        "TOPPING:", "FOR THE SAUCE:", "SAUCE:", "CRUST:", "FILLING:", \
        "MARINADE:", "DRESSING:", "GLAZE:"). These are organizational \
        labels, not step headers and not food items. Drop them silently \
        — flatten all ingredients into one list regardless of their \
        section. Do not emit a step or an ingredient entry for the \
        label itself.
    23. Incomplete or cut-off recipes: If the instructions end \
        mid-sentence or a step is clearly unfinished (text trails off, \
        final step has no conclusion), include whatever is visible as \
        the last step text — do not fabricate the missing content. \
        The quality gate still applies to what was captured: if title \
        + ingredients are present, the draft is worth previewing even \
        if the final step is incomplete.
    24. Recipe card continuation markers: Strip "(over)", "(cont.)", \
        "(continued)", "(see back)", "(flip)", "(back)" and similar \
        card-flip annotations that appear at the bottom of handwritten \
        recipe cards. They are navigation cues, not ingredients or \
        steps.
    25. Yield embedded in the title: When the title begins with a \
        number followed by a food noun ("100 Good Cookies", \
        "24 Brownies", "48 Mini Muffins"), that number is the yield — \
        extract it into servings AND keep the full phrase as the title. \
        Example: "100 Good Cookies" → title "100 Good Cookies", \
        servings "100". Do not strip the number from the title.
    26. Decorative cookbook content: Printed cookbook pages often include \
        decorative editorial elements that are not part of the recipe — \
        literary quotes with author attribution ("'A loaf of bread' the \
        Walrus said. / LEWIS CARROLL (1832-1898)"), chapter epigraphs, \
        publisher credits, author bios, and similar text. Discard any \
        block that consists of quoted text (in quotation marks or clearly \
        a quotation) followed by a person's name, dates like \
        "(1832-1898)", or a descriptor like "English writer and \
        mathematician." These are decorative and are never recipe \
        ingredients or steps.
    27. Book gutter and margin artifacts: When a cookbook is \
        photographed, text from the adjacent page sometimes bleeds \
        through the spine as isolated 1-5 character fragments ("sag", \
        "ell", "For", "eat"). These appear as orphan lines with no \
        culinary meaning and no connection to the surrounding recipe \
        text. Discard any line that is 1-5 characters, carries no \
        culinary or recipe meaning, and breaks the logical flow of the \
        surrounding content. (A word like "For" that is followed by \
        recipe text on the next line is NOT an artifact — only drop \
        it when it truly floats in isolation with nothing before or after.)
    28. "W/" shorthand in handwritten recipes: "w/" means "with". \
        Expand it everywhere — step text and ingredient names. \
        "Season w/ salt & pepper" → "Season with salt & pepper". \
        "Rub well w/ marg." → "Rub well with margarine". Apply silently.

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

    Worked example #4 (printed two-column cookbook page, OCR'd — \
    columns interleaved, action headers mixed into ingredient list, \
    alternative cooking methods, "To serve:" items, DIY sidebar):

    INPUT:
    Crispy Seasoned Tofu
    Serves 4 · 30 Minutes
    A simple dish celebrating bold flavor.

    1 (14-ounce) block firm or
    Prep: Preheat oven to 4257F. Pat tofu dry
    extra firm tofu, drained
    with a clean towel, then break into bite-
    1 tablespoon cornstarch
    sized chunks. In a large bowl, stir together
    A tablespoon seasoning blend
    cornstarch, seasoning, and solt. Add tofu
    15 tsp — salt
    and toss to evenly coat.
    To serve: rice, veggies
    ro baxe: Arrange tofu on a greased sheet pan
    baking sheet and bake for about 25 minutes,
    flipping halfway through cooking, until
    golden brown and crispy.
    or
    To Air Fry: Preheat air fryer to 3757F.
    Add tofu to basket in a single layer.
    Cook for 10-15 minutes, shaking pan
    occosionally to promote even cooking.
    Serve: Serve warm with rice or a veggie.

    DIY SEASONING BLEND
    Mix 2 tbsp black pepper, 1 tbsp flaky sea
    salt, 1 tsp onion powder, 1 tsp garlic powder.
    Blitz in a spice grinder.

    OUTPUT:
    title: "Crispy Seasoned Tofu"
    summary: "A simple dish celebrating bold flavor."
    servings: "4"
    cookTimeMinutes: "30"
    prepTimeMinutes: ""
    ingredients:
      - quantity "1", unit "", name "(14-ounce) block firm or extra firm tofu, drained"
      - quantity "1", unit "tbsp", name "cornstarch"
      - quantity "1", unit "tbsp", name "seasoning blend"
      - quantity "½", unit "tsp", name "salt"
      - quantity "", unit "", name "rice"
      - quantity "", unit "", name "veggies"
    steps:
      - text "Preheat oven to 425°F", needsTimer false, specialNote ""
      - text "Pat tofu dry with a clean towel, then break into bite-sized chunks", needsTimer false, specialNote ""
      - text "In a large bowl, stir together cornstarch, seasoning, and salt", needsTimer false, specialNote ""
      - text "Add tofu and toss to evenly coat", needsTimer false, specialNote ""
      - text "Arrange tofu on a greased sheet pan; bake for about 25 minutes, flipping halfway, until golden brown and crispy", needsTimer true, specialNote "Air fryer: Preheat to 375°F. Add tofu to basket in a single layer. Cook 10–15 minutes, shaking occasionally."
      - text "Serve warm with rice or a veggie", needsTimer false, specialNote "DIY seasoning blend: Mix 2 tbsp black pepper, 1 tbsp flaky salt, 1 tsp onion powder, 1 tsp garlic powder."

    Critical patterns demonstrated here:
    - TWO-COLUMN INTERLEAVE: "1 (14-ounce) block firm or" and \
      "extra firm tofu, drained" are the same ingredient split \
      across lines by the column layout — rejoined into one entry. \
      "cornstarch, seasoning, and solt." and "Add tofu and toss to \
      evenly coat." are step fragments that appeared between \
      ingredient lines — they go to STEPS, not ingredients.
    - OCR FIXES: "A tablespoon" → "1 tablespoon"; "15 tsp — salt" \
      → "½ tsp salt"; "4257F" → "425°F"; "3757F" → "375°F"; \
      "ro baxe:" → "To Bake:" recognized as step header.
    - "To serve: rice, veggies" → two ingredients with empty \
      quantity/unit, not a step.
    - ALTERNATIVE METHOD: "To Bake:" is the main method (becomes \
      the step text); "To Air Fry:" is the alternative (becomes \
      specialNote on that step).
    - DIY SIDEBAR: collapsed into specialNote on the final step.
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
    @Guide(description: "Explicit recipe name only; leave empty if no title is present. Strip @-handles and hashtags.")
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
        @Guide(description: "Cooking action explicitly stated in the input. No leading 'Step N:' or '1.'.")
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
