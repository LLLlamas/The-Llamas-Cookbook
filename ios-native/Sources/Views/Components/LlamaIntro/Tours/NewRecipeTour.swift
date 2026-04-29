import Foundation

/// 11-step tour shown the first time a user opens the editor for a
/// brand-new recipe (`recipe == nil` and the seed draft is empty —
/// imports / photo "Edit then Save" hand-offs skip the tour since
/// the user has already engaged with a different parser flow).
///
/// Re-entry is the question-mark icon in the editor toolbar, which
/// presents this tour every time, regardless of the seen flag.
enum NewRecipeTour {
    static let steps: [LlamaIntroStep] = [
        LlamaIntroStep(
            id: 1,
            target: .editorHero,
            headline: "Let's build a recipe",
            body: "I'll walk you through the fields. Only one is required — the rest are up to you.",
            waveOnEnter: true
        ),
        LlamaIntroStep(
            id: 2,
            target: .titleField,
            headline: "Recipe name",
            body: "This is the only required field. Type whatever you'll recognize it by — I'll title-case it for you.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 3,
            target: .summaryField,
            headline: "Short description",
            body: "A line or two that shows up under the title in your library. Skip if you don't have one.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 4,
            target: .servingsField,
            headline: "Servings",
            body: "Set this and Cook Mode lets you scale the whole recipe up or down on the fly.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 5,
            target: .prepTimeField,
            headline: "Prep time",
            body: "Minutes of work before cooking starts. Surfaces alongside cook time when you open the recipe.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 6,
            target: .photosButton,
            headline: "Add photos",
            body: "Tap to open the gallery. Pick up to a dozen, reorder them, add captions. Each step can also have its own photos (up to 3).",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 7,
            target: .categoriesHeader,
            headline: "Tag it",
            body: "Tags drive your library filters. Add 'Sourdough' to unlock the calculator chip in Detail.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 8,
            target: .ingredientQuickAdd,
            headline: "Add ingredients",
            body: "Quantity, unit, name. Tap chips for common values, hit + to add. Only the name is required — leave qty/unit blank if there isn't one.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 9,
            target: .stepQuickAdd,
            headline: "Add steps",
            body: "One step at a time. Tap the clock if the step needs a timer in Cook Mode. Long-press a step later to drag and reorder.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 10,
            target: .specialNotesEditor,
            headline: "Notes",
            body: "Recipe-level intro, sign-off, or general note — plus per-step notes if a step needs context.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 11,
            target: .saveButton,
            headline: "Hit Save when ready",
            body: "You can come back and edit anytime. Photos, tags, steps — nothing's locked in.",
            waveOnEnter: false
        )
    ]
}
