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
            headline: "Let's Build a Recipe",
            body: "I'll walk you through the fields. Only one is required — the rest are up to you.",
            waveOnEnter: true
        ),
        LlamaIntroStep(
            id: 2,
            target: .titleField,
            headline: "Recipe Name",
            body: "This is the only required field. Type whatever you'll recognize it by — I'll title-case it for you.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 3,
            target: .summaryField,
            headline: "Short Description",
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
            headline: "Prep Time",
            body: "Minutes of work before cooking starts. Surfaces alongside cook time when you open the recipe.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 6,
            target: .photosButton,
            headline: "Add Photos",
            body: "Tap to open the gallery. Pick up to a dozen, reorder them, add captions.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 7,
            target: .categoriesHeader,
            headline: "Tag It",
            body: "Tags drive your library filters. Add 'Sourdough' as a category to unlock the starter calculator!",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 8,
            target: .ingredientQuickAdd,
            headline: "Add Ingredients",
            body: "Here, let us know the ingredient, and if you have it - Quantity & Unit !",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 9,
            target: .stepQuickAdd,
            headline: "Add Steps",
            body: "One step at a time. Tap the clock if the step needs a timer in Cook Mode. Long-press a step later to drag and reorder.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 10,
            target: .specialNotesEditor,
            headline: "Notes",
            body: "Here you can add special notes to certain steps or in general.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 11,
            target: .saveButton,
            headline: "Hit Save When Ready",
            body: "You can come back and edit anytime. Photos, tags, steps — nothing's locked in.",
            waveOnEnter: false
        )
    ]
}
