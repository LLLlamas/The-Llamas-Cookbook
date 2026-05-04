# Llama Intro

Coach-mark tour overlay shown for New Recipe / Import From Text / Import From Link.

Files: `ios-native/Sources/Views/Components/LlamaIntro/`, `Tours/*.swift`, hosted by `Views/Editor/` and `Views/Library/`.

## New-recipe tour (interactive)

The new-recipe walkthrough is **hands-on** — the dim + halo are non-hit-testing, so the user types directly into the real editor fields as the tour progresses. Finishing the tour and tapping Save in the toolbar persists a real `Recipe` (no separate "demo" path).

Step structure (6 consolidated steps):

1. **Recipe Name + Short Description** — target `.titleField`. Body: "Write down what you're cookin' and add a short description if you like !"
2. **Servings + Prep Time** — target `.servingsField`. Short, warm prompt covering both.
3. **Add Photos** — target `.photosButton`.
4. **Tag It** — target `.categoriesHeader`. Mentions the Sourdough unlock.
5. **Ingredients** — target `.ingredientQuickAdd`.
6. **Steps + Special Notes** — target `.stepQuickAdd`. Last step; "Got it!" pill closes the tour. The user then taps Save in the toolbar like any normal new recipe.

Guardrails:

- Respect Reduce Motion.
- No Skip button — the user types as they go; finishing the tour is the dismissal.
- The dim/halo pass touches through to the field underneath (`.allowsHitTesting(false)`), so the keyboard surfaces and edits land on the real draft.
- Bubble + controls remain hit-testing so the navigation cluster works.
- Do not auto-show during share-extension or prefilled-URL intents (`openedFromScratch == false`).
- Help text stays short and warm.
- Hosted via `.overlayPreferenceValue(LlamaTourTargetKey.self)` at the outermost level of the editor — anchor preferences from toolbar items don't propagate into a child overlay's own preference scope.
