# Photo Import

Manual camera capture or PhotosPicker → on-device Vision OCR → text cleaning → `RecipeAIParser.parseBestOf` → `PhotoImportPreviewView`.

If parsing is weak, the flow offers to continue in text import with the OCR text prefilled.

## Files

- `ios-native/Sources/Views/Library/ImportFromPhotoView.swift`
- `ios-native/Sources/Views/Library/PhotoImportPreviewView.swift`
- `ios-native/Sources/Views/Components/CameraCaptureView.swift`
- `ios-native/Sources/Lib/RecipeOCRImporter.swift`
- `ios-native/Sources/Lib/RecipeAIParser.swift`
- `ios-native/Sources/App/EditorCoordinator.swift`

## Decisions

- On-device OCR only.
- Manual-shutter camera (replaced VisionKit auto-capture).
- No automatic scan attachment as recipe gallery photos.
- Quality gate: title + ingredients + steps before silent import.
- Partial OCR fallback routes to text import.
