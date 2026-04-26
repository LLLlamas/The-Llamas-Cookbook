import Foundation
import FoundationModels

/// On-device LLM recipe parser, gated to iOS 26+ with Apple Intelligence
/// enabled. Used as the *first* attempt on the messy URL-import paths
/// (TikTok captions, Pinterest pin descriptions, blog OG-fallback
/// summaries) where caption-style writing outpaces what the regex
/// parser can resolve. Returns nil when the model is unavailable so
/// the caller can fall back to `RecipeImporter.parse` — the regex
/// pipeline stays the universal floor for older devices, devices
/// without Apple Intelligence, and the model-not-ready window after
/// first install.
///
/// **Why only the URL paths**: a user who pastes pre-structured text
/// already did the hard work; spending 2-5 seconds running the LLM on
/// clean input would be a regression. Schema.org JSON-LD likewise has
/// real structure already, no LLM needed. The LLM earns its keep on
/// social-media captions where free-form prose hides the structure.
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

    /// Minimum bar for "AI got something useful": title and at least
    /// one ingredient OR one step. Below that we'd be handing the
    /// editor an empty preview, which is worse UX than letting the
    /// regex parser take a swing at the same input.
    private static func passesQualityGate(_ draft: DraftRecipe) -> Bool {
        let hasTitle = !draft.title.trimmed.isEmpty
        let hasContent = !draft.ingredients.isEmpty || !draft.steps.isEmpty
        return hasTitle && hasContent
    }

    /// Instructions tuned for caption-style input. Each rule maps to a
    /// real failure mode we've seen in the wild: TikTok handle suffixes,
    /// glued steps, parenthetical "while X" hints, ranges. Kept compact —
    /// the model behaves better with directives than with prose.
    private static let instructions: String = """
    You parse messy recipe text from social media (TikTok, Instagram, \
    Pinterest, recipe blogs) into structured fields. Follow these rules:

    1. Title: the dish name. Usually the first non-empty line. Strip \
       social-media decorations like @handles, #hashtags, emoji runs, \
       and "RECIPE:" / "Recipe -" prefixes.
    2. Summary: short blurb if the caption has one. Empty otherwise.
    3. Ingredients: split each into quantity / unit / name. \
       "2 cups flour" -> quantity "2", unit "cup", name "flour". \
       "salt to taste" -> quantity "", unit "", name "salt to taste". \
       "1 1/2 tbsp butter" -> quantity "1 1/2", unit "tbsp", name "butter". \
       Use canonical singular units (cup, tbsp, tsp, oz, lb, g, kg, ml, l).
    4. Steps: one cooking action per step. Strip leading numbering like \
       "Step 1:" or "1." — the order is implicit. Split paragraphs that \
       glue several actions together.
    5. needsTimer: true when a step mentions a duration ("for 30 \
       minutes", "1-2 hours"). False otherwise.
    6. specialNote: only set this when the step has a parenthetical \
       reminder or a "while X is happening" clause. Move that phrase \
       to specialNote and keep the main action in the step text. \
       Empty otherwise.
    7. Strip trailing creator handles (@username) and hashtag runs from \
       every field; they aren't part of the recipe.
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
    func toDraft(sourceUrl: String?) -> DraftRecipe {
        var draft = DraftRecipe()
        draft.title = title.trimmed
        draft.summary = summary.trimmed
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
            return DraftStep(
                text: text,
                needsTimer: step.needsTimer,
                specialNote: note.isEmpty ? nil : note
            )
        }
        return draft
    }
}
