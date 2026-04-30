# Photo Capability Summary

Historical plan, condensed after implementation.

## Current Behavior

- Recipe gallery photos and per-step photos are SwiftData relationship models.
- `RecipeStep.image` is deprecated and kept only for migration.
- Editor writes photos through `DraftPhoto` and commits via `Recipe.apply(_:)`.
- Detail gallery can mutate saved recipe photos directly.
- Cloud share/published recipes strip photo bytes from JSON and send photos as CKAssets.

## Critical Files

- `ios-native/Sources/Models/Recipe.swift`
- `ios-native/Sources/Lib/ImageProcessing.swift`
- `ios-native/Sources/Views/Components/RecipeImageView.swift`
- `ios-native/Sources/Views/Components/PhotoCarouselView.swift`
- `ios-native/Sources/Views/Components/PhotoReorderView.swift`
- `ios-native/Sources/Lib/RecipeShare.swift`
- `ios-native/Sources/Lib/CloudKitService.swift`

## Guardrails

- Keep photo decode/resize off the main path where possible.
- Keep CloudKit receive caps in place.
- Never write new data to `RecipeStep.image`.
- Any save flow must carry image bytes through the draft.
