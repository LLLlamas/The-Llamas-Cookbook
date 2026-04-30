# Photo Import Summary

Historical implementation plan, condensed after shipping.

## Current Behavior

Import From Photo uses manual camera capture or PhotosPicker, runs Vision OCR on-device, cleans text, parses with `RecipeAIParser.parseBestOf`, and shows `PhotoImportPreviewView`.

If parsing is weak, the flow offers to continue in text import with the OCR text prefilled.

## Critical Files

- `ios-native/Sources/Views/Library/ImportFromPhotoView.swift`
- `ios-native/Sources/Views/Library/PhotoImportPreviewView.swift`
- `ios-native/Sources/Views/Components/CameraCaptureView.swift`
- `ios-native/Sources/Lib/RecipeOCRImporter.swift`
- `ios-native/Sources/Lib/RecipeAIParser.swift`
- `ios-native/Sources/App/EditorCoordinator.swift`

## Decisions

- On-device OCR only.
- Manual-shutter camera replaced VisionKit auto-capture.
- No automatic scan attachment as recipe gallery photos.
- Photo path uses a stricter quality gate: title + ingredients + steps.
- Partial OCR fallback goes to text import rather than silently failing.
