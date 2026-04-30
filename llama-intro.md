# Llama Intro Summary

Historical plan, implemented as coach-mark tours.

## Current Behavior

SwiftUI overlay highlights fields and shows helper copy for:

- New Recipe
- Import From Text
- Import From Link

## Critical Files

- `ios-native/Sources/Views/Components/LlamaIntro/`
- `Tours/NewRecipeTour.swift`
- `Tours/TextImportTour.swift`
- `Tours/LinkImportTour.swift`
- Host views in `Views/Editor/` and `Views/Library/`

## Guardrails

- Respect Reduce Motion.
- Keep overlay lightweight and dismissible.
- Do not auto-show during share-extension/prefilled URL intent.
- Help text should stay short; no feature manual inside the UI.
