import Foundation

/// 7-step interactive tour shown the first time a user opens the
/// editor for a brand-new recipe (`recipe == nil` and the seed draft
/// is empty — imports / photo "Edit then Save" hand-offs skip the
/// tour since the user has already engaged with a different parser
/// flow).
///
/// The dim/halo pass touches through to the underlying editor fields
/// so the user types into the real draft as they walk through.
/// Finishing the tour drops them at the toolbar Save with a real
/// recipe ready to persist.
///
/// Re-entry is the question-mark icon in the editor toolbar, which
/// presents this tour every time, regardless of the seen flag.
enum NewRecipeTour {
    static let steps: [LlamaIntroStep] = [
        LlamaIntroStep(
            id: 1,
            target: .titleField,
            headline: "Name It",
            body: "Write down what you're cookin' and add a short description if you like !",
            waveOnEnter: true
        ),
        LlamaIntroStep(
            id: 2,
            target: .servingsField,
            headline: "Servings & Prep",
            body: "How many it feeds and how long it takes !",
            waveOnEnter: false,
            extraTargets: [.prepTimeField]
        ),
        LlamaIntroStep(
            id: 3,
            target: .photosButton,
            headline: "Add Photos",
            body: "Tap to pick a few — you can reorder and caption 'em later.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 4,
            target: .categoriesHeader,
            headline: "Tag It",
            body: "Tags filter your library. Add 'Sourdough' to unlock the starter calculator!",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 5,
            target: .ingredientQuickAdd,
            headline: "Ingredients",
            body: "Drop one in — quantity and unit if you've got 'em.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 6,
            target: .firstIngredientRow,
            headline: "Nice Work!",
            body: "There's your first ingredient. Add as many as you need, then tap next for steps.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 7,
            target: .stepQuickAdd,
            headline: "Steps & Notes",
            body: "One step at a time, tap the clock if it needs a timer. Special notes sit right below !",
            waveOnEnter: false,
            extraTargets: [.specialNotesEditor]
        ),
        LlamaIntroStep(
            id: 8,
            target: .saveButton,
            headline: "Save It!",
            body: "All done? Hit Save up here to drop it in your cookbook !",
            waveOnEnter: false
        )
    ]
}
