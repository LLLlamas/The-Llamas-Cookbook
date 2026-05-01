# Photos

- Recipe gallery photos and per-step photos are SwiftData relationship models.
- `RecipeStep.image` is deprecated migration baggage. Never write to it.
- Editor writes photos through `DraftPhoto` / `DraftStep`; commit via `Recipe.apply(_:)`.
- Detail gallery can mutate saved recipe photos directly.
- Cloud share/published recipes strip photo bytes from JSON and send photos as CKAssets, capped per-photo (10 MB) and total (40 MB).

## Files

- `ios-native/Sources/Models/Recipe.swift`
- `ios-native/Sources/Lib/ImageProcessing.swift`
- `ios-native/Sources/Views/Components/RecipeImageView.swift`
- `ios-native/Sources/Views/Components/PhotoCarouselView.swift`
- `ios-native/Sources/Views/Components/PhotoReorderView.swift`
- `ios-native/Sources/Lib/RecipeShare.swift`
- `ios-native/Sources/Lib/CloudKitService.swift`

## Guardrails

- Decode/resize off the main path where possible.
- Keep CloudKit receive caps in place.
- Any save flow must carry image bytes through the draft.
