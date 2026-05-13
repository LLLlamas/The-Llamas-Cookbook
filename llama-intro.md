# Llama Intro

Coach-mark tour overlay shown for New Recipe / Import From Text/Link.

Files: `ios-native/Sources/Views/Components/LlamaIntro/`, `Tours/*.swift`, hosted by `Views/Editor/` and `Views/Library/`.

The text/link tour (`TextLinkImportTour.swift`) covers both URL fetch and plain-text paste in a single 6-step run, since the merged sheet exposes both inputs side-by-side.

## New-recipe tour (interactive)

The new-recipe walkthrough is **hands-on** — the dim + halo are non-hit-testing, so the user types directly into the real editor fields as the tour progresses. Finishing the tour and tapping Save in the toolbar persists a real `Recipe` (no separate "demo" path).

Step structure (8 steps):

1. **Recipe Name + Short Description** — target `.titleField`.
2. **Servings + Prep Time** — target `.servingsField` + `.prepTimeField`.
3. **Add Photos** — target `.photosButton`.
4. **Tag It** — target `.categoriesHeader`. Mentions the Sourdough unlock.
5. **Ingredients** — target `.ingredientQuickAdd`. **Auto-advances** to step 6 the moment the user adds their first ingredient (false → true transition on `ingredientAdded`). The overlay scans `steps` for the `.ingredientQuickAdd` target to find this index — no hardcoded magic number.
6. **First ingredient spotlight** — target `.firstIngredientRow` (the VStack wrapping all ingredient rows; always present once an ingredient exists). "Nice Work!" bubble. User taps Next to continue.
7. **Steps + Special Notes** — target `.stepQuickAdd` + `.specialNotesEditor`.
8. **Save** — target `.saveButton`. Last step. "Got it!" pill closes the tour. **Exit pill is hidden** on this step — "Got it!" already serves as the dismissal, so a second bail-out button would be redundant.

Guardrails:

- Respect Reduce Motion.
- No Skip button — the user types as they go; finishing the tour is the dismissal. An Exit pill sits below the Back/Next arrow row for steps 1–7; it is hidden on the final step (step 8) because "Got it!" already dismisses. Typed work stays in the editor regardless.
- The dim/halo pass touches through to the field underneath (`.allowsHitTesting(false)`), so the keyboard surfaces and edits land on the real draft.
- Bubble + controls remain hit-testing so the navigation cluster works.
- Do not auto-show during share-extension or prefilled-URL intents (`openedFromScratch == false`).
- Help text stays short and warm.
- Hosted via `.overlayPreferenceValue(LlamaTourTargetKey.self)` at the outermost level of the editor — anchor preferences from toolbar items don't propagate into a child overlay's own preference scope.
- Step indicator renders as dots for tours with ≤ 9 steps, numeric counter beyond that.
