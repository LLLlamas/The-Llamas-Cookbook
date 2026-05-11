# Photo Import

Manual camera capture or PhotosPicker → on-device Vision OCR → text cleaning → `RecipeAIParser.parseBestOf` → `PhotoImportPreviewView`.

If parsing is weak, the flow offers to continue in text import with the OCR text prefilled.

## Parser priority inside `parseBestOf`

1. **Claude Haiku API** (`AnthropicRecipeParser`) — preferred when an API key is configured. Available on all iOS versions and device tiers. Better step splitting and ingredient extraction than the on-device model. Uses structured output (tool use) and prompt caching.
2. **Apple Intelligence** (`RecipeAIParser.parse`) — iOS 26+, A17/M-chip hardware only. Fallback when Claude is unconfigured or returns nil.
3. **Regex pipeline** (`RecipeImporter.parse`) — universal baseline. Always runs so `pickBetterDraft` can compare any AI result against it.

## Files

- `ios-native/Sources/Views/Library/ImportFromPhotoView.swift`
- `ios-native/Sources/Views/Library/PhotoImportPreviewView.swift`
- `ios-native/Sources/Views/Components/CameraCaptureView.swift`
- `ios-native/Sources/Lib/RecipeOCRImporter.swift`
- `ios-native/Sources/Lib/RecipeAIParser.swift`
- `ios-native/Sources/Lib/AnthropicRecipeParser.swift` ← new (2026-05-11)
- `ios-native/Sources/App/EditorCoordinator.swift`

## Decisions

- On-device OCR only (Vision framework). Photo is never sent to any API; only the extracted text reaches Claude.
- Manual-shutter camera (replaced VisionKit auto-capture).
- No automatic scan attachment as recipe gallery photos.
- Quality gate: title + ingredients + steps before silent import.
- Partial OCR fallback routes to text import.
- API key injection: `ANTHROPIC_API_KEY` build setting → `AppInfo.plist AnthropicAPIKey` → Keychain on first launch via `AnthropicRecipeParser.provisionKeyIfNeeded()`. Key is baked into the binary (Phase 2, TestFlight only). Phase 3 migrates to Cloudflare Worker proxy so the key never ships in the binary.

## Phase 3 open work (before App Store)

- Add Cloudflare Worker at `llamascookbook.pages.dev/api/parse` that holds the key in env vars, rate-limits by CloudKit user ID, and optionally caches results in Workers KV.
- Remove `AnthropicAPIKey` from `AppInfo.plist` and `ANTHROPIC_API_KEY` from `project.yml`.
- `AnthropicRecipeParser.callAPI` points at the Worker URL instead of `api.anthropic.com` directly.
- Add privacy disclosure to import UI: "Recipe text is processed by Anthropic's AI."
- Update App Store privacy labels to reflect third-party AI processing.
