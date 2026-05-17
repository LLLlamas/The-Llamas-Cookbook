# CLAUDE.md

Source of truth for agents. Code wins when this disagrees.
Last refreshed: 2026-05-17 (session 17 — PaywallView llama crown, RecipeDetailView icon resize + navbar, terracotta tier pills).

---

## Stack

- Swift 5.10, SwiftUI, SwiftData, iOS 26+ deploy target, iOS 26 SDK.
- `SWIFT_STRICT_CONCURRENCY: minimal`.
- XcodeGen: `ios-native/project.yml`. Do not hand-edit generated Xcode files.
- CI: `macos-26` runner, Xcode 26. **Windows dev — do NOT run `xcodegen`/`xcodebuild`/CocoaPods here.**
- Bundle IDs: `com.llamascookbook.app` (main), `.widget`, `.shareext`.
- App Group: `group.com.llamascookbook.app` — must match in 4 places: `SharedContainer.appGroupID`, main app entitlements, share extension entitlements, portal profiles.
- CloudKit container: `iCloud.com.llamascookbook.app`.
- Universal Link host: `llamascookbook.pages.dev`.
- Team: `GYFN949Q5E`. ASC app id: `6762527184`.

---

## Directory map

| Feature area | Primary directory |
|---|---|
| App shell, tab bar, deep links, navigation | `ios-native/Sources/App/` |
| SwiftData models | `ios-native/Sources/Models/` |
| Theme (colors, fonts, spacing, outline) | `ios-native/Sources/Theme/` |
| Library, recipe cards, import flows | `ios-native/Sources/Views/Library/` |
| Recipe editor | `ios-native/Sources/Views/Editor/` |
| Recipe detail + sharing | `ios-native/Sources/Views/Detail/` |
| Cook mode + timers | `ios-native/Sources/Views/Cook/` |
| Friends / social views | `ios-native/Sources/Views/Friends/` |
| Profile + auth views | `ios-native/Sources/Views/Profile/` |
| Reusable UI components | `ios-native/Sources/Views/Components/` |
| CloudKit ops + shared utilities | `ios-native/Sources/Lib/` |
| Widget + Live Activity | `ios-native/WidgetExtension/` |
| Share extension | `ios-native/ShareExtension/` |
| Web preview (Cloudflare Pages) | `cloudflare-pages/` |

---

## Feature → Files map

**App shell** (`Sources/App/`)
- `LlamasCookbookApp.swift` — `@main`, `ModelContainer`, `AppDelegate` (APNs + remote-push dispatch)
- `RootView.swift` — tab bar, all deep-link routing, editor/cook/share sheet orchestration
- `EditorCoordinator.swift`, `NavigationContext.swift`, `CookingSession.swift`, `CookingSessionState.swift`
- `FriendsStore.swift` — `@MainActor` cache of friends + requests
- `UserAccount.swift` — SIWA identity, sign-out, delete-account cascade
- `OwnerProfile.swift` — pre-SIWA display-name fallback; `AppearanceSettings.swift` — accent color; `applySignedOut()` resets accent to terracotta without erasing UserDefaults preference; `restoreFromDefaults()` re-reads it on sign-in. Wired from `LlamasCookbookApp` via `.onAppear` + `.onChange(of: userAccount.status.isSignedIn)`.

**Data models** (`Sources/Models/`)
- `Recipe.swift` — `Recipe`, `Ingredient`, `RecipeStep`, `RecipePhoto`, `RecipeStepPhoto`; chain-attribution fields
- `DraftRecipe.swift` — editor draft type; `Recipe.apply(_:)` is defined here

**Theme** (`Sources/Theme/`)
- `AppColor`, `AppFont`, `AppSpacing`, `ColorHex`, `AccentTextOutline`

**Library / import** (`Sources/Views/Library/`)
- `LibraryView.swift`, `RecipeCardView.swift`, `EmptyLibraryView.swift`, `ImportHelpView.swift`
- `ImportFromTextLinkView.swift` — merged paste-text + URL-fetch sheet. Two mirrored focus-mode states: `urlFieldEdited` (set when `urlFocused && urlText non-empty`; cleared on empty) and `textFieldEdited` (set when `pasteFocused && pastedText non-empty`; cleared on empty); neither is set by programmatic prefill (share-extension handoff, OCR seed). When `urlFieldEdited`: paste section dims to 0.45 opacity, clipboard paste button dims to 0.4, Preview button gets accent glow (shadow radius 12) and fires a one-shot rotation jiggle via `keyframeAnimator(trigger: previewJiggleCount)`. When `textFieldEdited`: link section dims to 0.45 opacity (no Preview glow/jiggle — text path doesn't need it). Duplicate-title check via `nextAvailableTitle(base:)` runs on every Preview tap for both URL and text paths — fetches from `modelContext` with `#Predicate`, walks `Title (1)`, `Title (2)` ... until a free slot is found; shows an alert before pushing to the editor so the user can confirm or cancel.
- `ImportFromPhotoView.swift`, `RecipeImportPreviewView.swift`, `PhotoImportPreviewView.swift`
- Components: `LetterIndex.swift`, `CookbookHeader.swift`
- Lib: `RecipeImporter.swift`, `RecipeURLImporter.swift`, `RecipeOCRImporter.swift`, `RecipeAIParser.swift`, `AnthropicRecipeParser.swift`, `StreamingRecipeParser.swift`, `RecipeSchemaParser.swift`, `RecipeExport.swift`
- Lib: `QuotaService.swift` — `@MainActor @Observable` singleton; polls `/api/usage`, fires `/api/usage/consume` after saves; exposes `snapshot: QuotaSnapshot?`
- Lib: `LlamaProStore.swift` — StoreKit 2 wrapper (Phase 1 stub: `isPro = false`)

**Editor** (`Sources/Views/Editor/`)
- `RecipeEditorView.swift`
- `IngredientRowEditor.swift`, `IngredientQuickAdd.swift`, `StepRowEditor.swift`, `StepQuickAdd.swift`, `SpecialNotesEditor.swift`, `TagInputView.swift`, `PhotoToggleButton.swift`
- `Chips/QuantityChips.swift`, `UnitChips.swift`
- Lib: `TagPresets.swift`, `IngredientDisplay.swift`, `Plural.swift`

**Detail / share** (`Sources/Views/Detail/`)
- `RecipeDetailView.swift`
- `ImportersListSheet.swift`, `AttributionSheet.swift`, `ConversionsView.swift`, `SourdoughCalculatorView.swift`
- Lib: `RecipeShare.swift` (wire format), `CloudKitService.swift` (upload/fetch/delete), `ImportCountCache.swift`

**Cook mode / timers** (`Sources/Views/Cook/`)
- `CookModeView.swift`
- Lib: `TimerNotifications.swift` — AlarmKit wrapper (`AlarmManager.shared`); `ResumeCookModeIntent.swift`
- `Shared/TimerAlarmMetadata.swift`; Widget: `TimerLiveActivity.swift`, `TimerWidgetBundle.swift`

**Friends / social** (`Sources/Views/Friends/`, `Sources/Lib/`)
- `FriendsTabView.swift` — unsigned users see `FriendLibraryView(friend: SeedFriend.profile, showsBackButton: false)` directly instead of the grid; signed-in path unchanged.
- `FriendLibraryView.swift` — `var showsBackButton: Bool = true`; when `false`, hides the custom back button. When `!showsBackButton && !userAccount.status.isSignedIn`, shows a `signInBanner` card above the category strip.
- `FriendRecipeDetailView.swift`
- Lib: `CloudKitFriendship.swift`, `CloudKitUserProfile.swift`, `CloudKitPublishedRecipe.swift`, `CloudKitRecipeImport.swift`, `CloudKitSubscriptions.swift`, `CloudPendingDeleteQueue.swift`, `UserProfileMirror.swift`, `LibraryMirrorService.swift`, `SeedFriend.swift` ("Your Llama" synthetic seed friend + bundled-JSON recipe catalog)
- Resources: `SeedRecipes.json` — 10 starter recipes the seed friend "owns"; decoded once into `LCRecipeShareV1` envelopes

**Quota + IAP** (`Sources/Lib/`, `Sources/Views/Profile/`)
- `QuotaService.swift` — photo-import quota state (see quota enforcement invariants)
- `LlamaProStore.swift` — StoreKit 2 wrapper; Phase 2 wires purchase + ASN V2 webhook. `transactionUpdateTask` is `nonisolated(unsafe)` so `deinit` (which is nonisolated) can cancel it without an actor hop — `Task.cancel()` is thread-safe. Subscription liveness uses `transaction.expirationDate.map { $0 > Date.now } ?? true`; `Transaction.isExpired` does not exist on `StoreKit.Transaction`.
- `PaywallView.swift` — IAP paywall sheet; Phase 1 shows "Coming soon" stub

**Auth / identity** (`Sources/Lib/`)
- `SignInWithAppleService.swift`, `KeychainStore.swift` — Apple `sub` + display name

**Share extension** (`ShareExtension/`)
- `ShareViewController.swift` — URL → `llamascookbook://share-url/`, file → App Group inbox
- `Sources/Shared/SharedContainer.swift`, `Base64URL.swift`

**Web preview + Worker API** (`cloudflare-pages/`)
- `functions/r/[id].js` — OG-tagged HTML preview; `functions/img/[id].js` — image proxy
- `functions/api/parse.js` — Anthropic proxy; Phase 1: quota enforcement + KV parse-result cache for photo calls; Phase 2: model in cache key, upstream timing, structured usage logging (tokens, cost, cache hit rate) via `console.log` — no recipe text or raw user IDs in logs
- `functions/api/usage.js` — read-only quota snapshot endpoint (GET)
- `functions/api/usage/consume.js` — save-confirm endpoint (POST); increments monthly save counter
- `lib/cloudkit.js` — CloudKit Web Services client (ECDSA P-256)
- `.well-known/apple-app-site-association` — AASA for Universal Links

**Components / misc** (`Sources/Views/Components/`)
- `PhotoCarouselView`, `PhotoReorderView`, `CameraCaptureView`, `ShareSheet`, `LlamaLogo`, `LlamaWatermark`, `LlamaProgressIndicator`, `LlamaIntro/` (includes `LlamaFloatModifier.swift` — `.llamaFloat()` reusable 4pt bob, 1.4s easeInOut, Reduce-Motion-aware; **250ms delayed start** so the bob doesn't compete with sheet/navigation transition frames; applied to `AccentColorPicker` llama preview and Friends empty-state llama)
- `AccentColorPicker.swift` — shows `signInLockedCard` ("Sign in to customize") in place of the picker when unsigned; `commitSelection()` is a no-op when unsigned. Both call sites inject `.environment(userAccount)`. `SavedToast.swift`, `RecipeImageView.swift` (async decode — see Performance invariants)
- Lib: `ImageProcessing.swift`, `Conversions.swift`, `Quantity.swift`, `SourdoughCalculator.swift`, `Haptics.swift`, `SwipeBack.swift`, `AppMetadata.swift`

**Shared helpers & extensions** — reuse these; do **not** re-inline the patterns they replace.
- `View.cardScrollTransition()` (`Components/View+CardScrollTransition.swift`) — continuous scroll-focus zoom for card lists: center card peaks at **1.04** scale (subtle 3D pop), off-center cards taper to ~0.96 with opacity dim. Formula: `scaleEffect(1.04 - 0.08 * abs(phase.value))`. Used by `LibraryView`, `FriendLibraryView`, `RecipeDetailView` step list.
- `View.surfaceCard(cornerRadius:)` (`Components/View+SurfaceCard.swift`) — the standard settings/info-card chrome: `AppSpacing.md` padding + full-width leading frame + `AppColor.surface` fill + 1pt `AppColor.divider` stroke + rounded clip. Apply to a content view; do not re-write the chrome chain by hand.
- `LlamaLogoOrCrown(size:accent:crownAsset:)` (`Components/LlamaLogoOrCrown.swift`) — the brand llama, swapped for its crowned Pro variant when `LlamaProStore.isPro`. Reads `LlamaProStore` from `@Environment` (call sites must inject it). `crownAsset` defaults to `Llama-Pro-Icon-Crown`; the Profile header and cook mode pass the default; `RecipeDetailView` principal also uses the default. For surfaces that have a context-specific crown asset (Friends, Profile tab button), use an inline `Image(proStore.isPro ? "Context-Crown" : "Base")` instead. Use `LlamaLogoOrCrown` instead of hand-writing the `proStore.isPro ?` Pro-Crown / `LlamaLogo` branch.
- `Formatters.date` (`Lib/Formatters.swift`) — the single shared `DateFormatter`. **All date display uses `.medium` style** ("May 4, 2026") via this formatter. Never allocate a `DateFormatter()` in rendering code; never define a per-view `static let shortDate`.
- `Optional<String>.trimmedIfNonEmpty` (`Lib/String+Extensions.swift`) — trimmed value when non-empty, `nil` otherwise. Replaces per-file private `trimmedNote(_:)` helpers.
- `UserProfileSnapshot.resolvedAccent` (`Lib/CloudKitUserProfile.swift`) — **canonical** friend-accent resolver: `accentHex` → `Color`, falling back to `AppColor.accent`. Every friend-tinted surface reads through this; never inline hex→Color-with-fallback again.
- `LetterIndex.firstItem(in:atOrAfter:letters:bucket:)` (`Components/LetterIndex.swift`) — generic "first item at or after letter" scrub traversal. Pass the caller's own bucketing closure. Used by `LibraryView` and `ProfileView` scrub strips.
- `ProfileView.SettingsSyncRow` — private; the shared chrome for the two CloudKit diagnostic rows (`cloudSyncRow`, `republishLibraryRow`) in the settings sheet.
- `ProfileView.EmptyStateCard(title:subtitle:)` — private; the centered two-line empty-state placeholder for the Requests and Friends sections.
- `View.liftedCard()` (`Components/View+Lifted.swift`) — static drop-shadow (radius 6, y 3, 0.13 opacity) for non-interactive card surfaces. Applied outside `.clipShape()` so the shadow isn't clipped. Current sites: recipe cards, friend cards, cook mode step/ingredient cards, photo strip tiles, tag pills, ingredient rows, step rows, settings/info surface cards, sign-in locked card, import help card.
- `LiftedButtonStyle` / `.buttonStyle(.lifted)` (`Components/View+Lifted.swift`) — interactive press-down: shadow flattens + scaleEffect 0.96 on press, 0.12s easeOut. Current sites: FAB, category/filter pills, Start Cooking bar, Conversions + Sourdough chips, per-step timer chip, phase toggle pills, floating timer bar, Mark as cooked bar, source link button, step photo pill, friend request approve/deny, Take a Photo, Choose from Library (via `.liftedCard()`), Llama Pro pill. Do NOT apply inside `.drawingGroup()` — shadows are clipped to texture bounds.
- `ScaleOnlyButtonStyle` / `.buttonStyle(.scaleOnly)` (`Components/View+Lifted.swift`) — scale-only press feedback (0.96, 0.12s easeOut), no shadow. Reserve for cases where `.lifted`'s shadow creates visual noise (e.g. icon-only toolbar buttons, buttons on already-elevated surfaces).

---

## Hard invariants

- **SwiftData: `cloudKitDatabase: .none`** — `.cascade` delete rules + non-optional props break auto-opt-in; silently degrades to in-memory.
- **`Recipe.apply(_:)` must NOT touch** `sharedBy`/`sharedAt`/`sourceShareID` or `originalCreator*`/`originalSharer*`/`originalRecipeID`/`importedAt`. Attribution fields are stamped at materialize time and must survive editor saves.
- **`RecipeStep.image` and `Recipe.imageUri` are deprecated** migration baggage — do not repurpose; kept for lightweight migration.
- **`UserProfile` recordName uses `profile_` prefix** — applied/stripped in `CloudKitUserProfile.swift`; callers pass raw iCloud user record names.
- **`PublishedRecipe.recordName == Recipe.id.uuidString`** — upsert fetches by recordName without a query.
- **`queryAllRecords` follows cursors** — never reintroduce first-page-only social queries.
- **Predicates split per field, not OR** — CloudKit public-DB OR on non-queryable fields throws `invalidArguments`.
- **Re-inject `@Observable` environments** into every sheet/fullScreenCover — values drop across presentation boundaries on iOS 26.
- **`FriendsStore.refresh()` sets `isRefreshing` synchronously** before any `await` — prevents re-entrancy.
- **`UserProfileMirror.cachedRecordID()`** is the canonical "is iCloud bound?" check — every social write short-circuits when nil.
- **`LibraryMirrorService`** — `@MainActor` singleton, 5s per-`Recipe.id` debounce. Sign-out/delete must call `resetBulkPublishMarker()`.
- **`ImportCountCache`** in UserDefaults, not `@Model` — prevents chip refreshes from triggering spurious `LibraryMirrorService` re-publishes.
- **"Your Llama" seed friend** (`SeedFriend.swift`) — synthetic local-only friend at `friends[0]` on every install. `userRecordName == "your-llama-seed"`, accent `#C97C5D` (terracotta). `SeedFriend.isSeed(_:)` short-circuits every CloudKit fan-out (`fetchPublishedRecipeSummaries`, `fetchPublishedRecipe`, `writeRecipeImport`, `removeFriend`, the contextMenu's Remove entry). Survives `refresh()` / `clearOnSignOut()` because it's prepended unconditionally. Counts toward `friends.count` — `ProfileView`'s bulk-publish trigger is `oldCount <= 1 && newCount > 1` (first *real* friend, not first friend ever).
- **`UserProfileSnapshot` has two inits** — `init(record:userRecordName:)` for the CloudKit path, and a direct-field `init` used by `SeedFriend.profile` to construct a snapshot without a `CKRecord`. Do not remove the direct-field init — `SeedFriend` depends on it and cannot build a fake `CKRecord`.
- **AlarmKit** owns cook-timer lock-screen alerts + Live Activity. Sound is always `AlertConfiguration.AlertSound.default`.
- **HEIC → JPEG before CloudKit upload** (`ImageProcessing.transcodeHEICToJPEGForSharing`). Local SwiftData stays HEIC.
- **`RecipeShareLimits.maxInboundBytes`** in `Sources/Shared/` — 25 MB cap; referenced by both main app and share extension.
- **`AccentColorPicker` commits on `.onDisappear`** — driving it earlier desyncs `UIColorPickerViewController`.
- **Unsigned user accent is always terracotta** — `AppearanceSettings.applySignedOut()` uses `isForcingDefault` to skip `persist()` + mirror push, preserving the stored preference. Never call `resetToDefault()` on sign-out (that erases UserDefaults). `LlamasCookbookApp` drives this via `.onAppear` + `.onChange(of: userAccount.status.isSignedIn)`.
- **`ImportFromPhotoView` quota countdowns use `TimelineView(.everyMinute)`** — both the pill text and the blocked-card "Resets in X" row update live. `timeRemaining(until:from:)` is a static helper on the view.
- **Custom back buttons** (`RecipeDetailView`, `FriendLibraryView`, `FriendRecipeDetailView`) use `.navigationBarBackButtonHidden(true)` + `.enableSwipeBack()`. `RecipeEditorView` intentionally omits `.enableSwipeBack()` — Cancel/Save pattern, data-loss risk.
- **CI Xcode toolchain**: `macos-26` ships beta `.app`s; CI renames them `_disabled_…` and re-pins both `DEVELOPER_DIR` and `PATH`. Setting only `DEVELOPER_DIR` leaves sub-tools on the beta; TestFlight rejects beta-built archives.
- **AI import parser chain**: text/link path goes `RecipeAIParser.parseBestOf` → `AnthropicRecipeParser.parse` (Cloudflare Worker proxy at `llamascookbook.pages.dev/api/parse`) → Apple Intelligence fallback → regex baseline. **Photo path** goes `RecipeAIParser.parseImagesStreaming` → `AnthropicRecipeParser.parseImagesStreaming` (streaming SSE from Sonnet 4.6 with progressive preview reveal). OCR + text-AI fallback uses `parseBestOf(preferHighQuality: true)` if Sonnet stream produces no usable draft. `AnthropicRecipeParser.isConfigured = true` unconditionally — no key in binary or Keychain. API key lives in Cloudflare env only. Both paths use `temperature: 0`, `max_tokens: 4096`, and the `extended-cache-ttl-2025-04-11` beta header for 1-hour prompt cache. Shared system prompt: `RecipeAIParser.instructions`.
- **Photo-import quota** — enforced server-side in the Cloudflare Worker (`/api/parse`, `/api/usage`, `/api/usage/consume`). Free cap: 5 saves/month. Pro cap: 30 saves/month. Daily parse rate limit: 5 attempts/user/day. KV namespace `LLAMAS_QUOTA` must be bound in the Cloudflare Pages dashboard. The iOS client sends `x-llamas-user` (SIWA sub from Keychain), `x-llamas-tz` (IANA timezone), and `x-llamas-import-kind: photo` on every vision call and consume call. Text/link/paste imports do NOT send these headers and are NOT gated. **Consume is fire-and-forget** — save to SwiftData first, then POST `/api/usage/consume`; a 402 race response shows a soft "this one's on us" banner but does NOT undelete the recipe.
- **`VisionParseOutcome`** is the return type of `AnthropicRecipeParser.parseImages{,Streaming}` and the `RecipeAIParser` wrappers. It carries `draft: DraftRecipe?`, `cacheHit: Bool`, and `error: VisionParseError?`. Non-nil `.error` means the Worker rejected the call (auth/quota/daily-limit) and the caller must NOT fall through to the OCR path — it should refresh `QuotaService` and let the exhausted-state UI take over. In the streaming path, the outcome's `draft` is the canonical post-processed draft assembled from the full stream; live UI rendering during the stream comes from the separate `StreamingRecipeState` passed in by the caller.
- **`StreamingRecipeState`** (`@Observable @MainActor`) is the live binding the streaming preview reads from. `AnthropicRecipeParser.parseImagesStreaming` populates it via `applyEvent` as `input_json_delta` chunks arrive. `onFirstContent` fires exactly once when the **title** arrives (non-empty) — available for timing instrumentation (`firstContentAt`); the overlay dismiss in `PhotoImportPreviewView` is driven by observing `streamingState.title.isEmpty` directly, not by this closure. Fallback: if the model emits no title, `onFirstContent` fires on the first ingredient instead. Immediately after firing, `onFirstContent` is set to `nil` to break the retain cycle. `status` transitions `waitingForFirstByte → streaming → completed` (or `.cancelled`/`.failed`). `cacheHit` is set by `completeStream` — `PhotoImportPreviewView.showCacheHint` reads it from the state (the `PreviewPayload` is created before cache status is known so its `cacheHit` is always `false`). `finalDraft` is set on completion; the preview reads from it once `streamFinalDraftReady` flips so post-processed step-splitting / plural-normalization apply.
- **`QuotaService`** is `@MainActor @Observable`, injected via environment from `LlamasCookbookApp`. `refresh(force: false)` respects a 60-second cache; `refresh(force: true)` always fetches. `consume()` returns `ConsumeResult` — `.race` triggers the "this one's on us" banner in `PhotoImportPreviewView`.
- **Parse-result cache**: Worker caches vision responses in KV keyed by `parseCache:<promptVersion>:model=<model>:<contentHash>` — model is included so Haiku and Sonnet results are stored separately (prep for routed cascade). `PROMPT_VERSION = "v3"` — bump in `parse.js` whenever `RecipeAIParser.instructions` changes. Cache hits skip the daily parse counter but still pre-check monthly quota. **Streaming responses are assembled before caching**: the Worker tees the upstream SSE stream — one branch streams to iOS, one accumulates and decodes the final tool_use input into the non-streaming JSON shape (`messages.create` response format) which is what gets written to KV. Cache hits are always returned non-streaming (with `x-llamas-cache: hit`), regardless of whether the call that populated them streamed.
- **Photo-import flow** — `ImportFromPhotoView.runImport` prepares pages in two formats in parallel (`.aiVision` pixel-capped JPEG ≤1568px long edge AND ≤1.2MP; `.ocr` 2560px). Cascade: (1) on-device OCR + `RecipeImporter.parse` → `localPhotoParseConfident` gate (≥3 ingredients with qty/unit, ≥2 steps ≤220 chars, explicit section label in text) — free if confident; (2) **streaming Sonnet vision** via Cloudflare proxy (`RecipeAIParser.parseImagesStreaming`) — `PhotoImportPreviewView` opens immediately as a `fullScreenCover` the moment the Sonnet path begins (blank draft + streaming state). A "Asking the llama…" overlay (`llamaProcessingCard`) covers the blank preview during Anthropic TTFB (5–10 s); it fades out (0.18s easeInOut) the instant `streamingState.title` becomes non-empty, then the title's insertion transition plays immediately. Content ticks in with spring animations as events land; (3) OCR text reused for `parseBestOf(preferHighQuality:true)` fallback if the stream produced no usable draft. For cache hits, `preview` is already set; `state.completeStream` sets `cacheHit` on the state and the overlay dismisses when the title lands. The legacy "What are we cookin'?" title input and "Ready / Review Recipe" state were removed. `ImportFromPhotoView`'s own overlay (still `ocrInProgress`-gated) shows "Preparing page…" and "Reading the recipe…" only during the OCR preflight phase; "Asking the llama…" has moved into `PhotoImportPreviewView`. Banner "Edit as text" is the final fallback. **Anthropic vision rejects HEIC** — `aiVision` forces JPEG via `forcesJPEGOutput`. Vision timeout 60s; same 429/529 backoff as text. OCR text is computed once and reused by the AI fallback — never recognized twice. Per-import branch + timing is logged via `os_signpost` + a single `Logger.info` summary line under subsystem `com.llamascookbook.app`, category `photoImport` (never logs recipe content).
- **Title cleanup** strips filename patterns (path + image extension) in `RecipeImporter.cleanTitle` — returns `""` so callers fall back to the next candidate title rather than displaying a file path.
- **OCR corner-metadata demotion**: `RecipeOCRImporter.cleanup` detects when the first OCR line looks like pure card-corner metadata (temperature, time, yield) and moves it to the end of the text so the recipe title is not displaced. Helper: `looksLikeCardCornerMetadata(_:)`. `customWords` in `RecipeOCRImporter` includes common pasta and Italian dish names (Spaghetti, Lasagna, Fettuccine, etc.) to improve cursive-handwriting recognition for these high-frequency recipe types.
- **Hallucination guards — three layers**: (1) Prompt: `NEVER FABRICATE` rule extended with four explicit anti-fabrication patterns (no expected pantry staples, no partial-list completion, no vague→specific name strengthening, no image-guessing). (2) OCR+text fallback: `pickBetterDraft` filters ingredients via `ingredientLooksHallucinated` (>40% of ≥4-char name tokens absent from source) and steps via `stepLooksHallucinated` (≥70% of support tokens absent; guard keeps ≥2 steps); if all ingredients filter out, AI draft is discarded in favor of regex. (3) Vision path: `RecipeAIParser.filterVisionHallucinations(from:ocrText:)` applied to `finalDraft` in `ImportFromPhotoView.runImport` before `state.completeStream`; uses strict 100% threshold (`visionIngredientFabricated`: ALL ≥4-char name tokens absent from OCR text, min 2 tokens) — lenient by design to avoid false positives when OCR misses a portion of the card. The streaming preview may briefly show an item that disappears at finalisation — the saved recipe is what must be correct.
- **Two-column layout rule** (system prompt rule 30): instructs the model to read both columns of a two-column ingredient layout before moving to steps.
- **OCR fallback stagger**: 120ms per item (was 55ms). Streaming SSE stagger: 80ms per item (was 55ms). Both changes make the progressive tick-in legible as a deliberate reveal rather than an instant pop.
- **Vision user prompt**: explicitly tells the model that handwritten corner annotations (temperature, yield) are metadata not the title, and to read two-column ingredient tables fully.
- **Streaming reveal in `PhotoImportPreviewView`** — when bound to a `StreamingRecipeState` the preview renders from live state during the stream and from `streamingState.finalDraft` after `message_stop`. Save button is disabled until `status == .completed`. **No skeleton placeholders** — the sheet opens immediately when the Sonnet path begins (blank content); `llamaProcessingCard` ("Asking the llama…" + llama spinner) overlays the blank view during TTFB and fades out (0.18s easeInOut) the instant `streamingState.title` becomes non-empty. Overlay is driven by `showProcessingOverlay`: `streamingState != nil && title.isEmpty && status ∉ {.cancelled, .failed, .completed}`. Aesthetic tick-in animations begin as soon as the overlay clears: title fades + scales (0.4s ease-out), ingredient rows spring in from the leading edge (response 0.4, damping 0.75, 20pt offset), step rows spring in from below (response 0.5, damping 0.8, 12pt offset). Soft haptic on title arrival only. Driven by Anthropic's actual token rate; `.ingredient` and `.step` events are staggered 80 ms apart in `consumeSSEStream` to prevent SwiftUI from batching all ForEach rows into one render frame when Anthropic emits them in a burst. Save/Cancel buttons stay accessible throughout; user can cancel mid-stream and the existing OCR-text fallback re-runs. **Save dismissal**: `performSave` does NOT call `dismiss()` — the `onSaved`/`onSavedForEdit` closures call `dismiss()` on `ImportFromPhotoView`, which tears down the entire sheet hierarchy (including the fullScreenCover) in a single animation, avoiding a flash of the import screen.

---

## Performance invariants

- **`RecipeImageView` decodes asynchronously.** `init` does a synchronous O(1) `NSCache` lookup — if cached (e.g. card thumbnail already decoded), `@State` is warm and the first body eval renders immediately with no flicker. Cache misses decode via `Task.detached(priority: .userInitiated)` off the main thread; result is written back on `@MainActor`. **Never revert to synchronous `UIImage(data:)` in `body`** — HEIC decode takes 50–150 ms and stalls push-animation frames. Callers must pass an explicit `placeholder` closure (not rely on the `EmptyView` convenience init) wherever a visible loading state matters — `RecipeCardView.thumbnail` and `RecipeDetailView.photoThumb` both use `accentSoft.opacity(0.5)` fill.
- **`.drawingGroup()` placement rules** — applied INSIDE `.clipShape()` / before the outer shadow stack so the shadow composites against a single Metal texture rather than re-compositing each inner layer per frame. Current sites: `RecipeCardView` (scroll jank fix), `AccentColorPicker.preview` (color-pick re-render fix), `RecipeDetailView` ingredients `VStack` (push-animation first-render fix). Do **not** apply to views that use `.blur()`, `.regularMaterial`, or other backdrop-sampling effects — those break inside a drawing group.
- **`.llamaFloat()` has a 250 ms delayed start** (`LlamaFloatModifier`). The `repeatForever` animation must not start at the same moment as a sheet presentation or tab transition — it competes for main-run-loop bandwidth and causes dropped frames on the incoming animation. Keep the delay if you ever add new `.llamaFloat()` call sites.

---

## CloudKit schema

All record types on the **public DB**. World-readable, world-writable (no Security Role yet).

| Record type | Key fields | Notes |
|---|---|---|
| `RecipeShare` | `envelope` (Asset), `senderDisplayName`, `recipeTitle`, `createdAt` (queryable+sortable), `photo0`–`photo19` (Asset, optional) | 12-char random recordName; Cloudflare routes legacy 6-char IDs |
| `UserProfile` | `displayName`, `accentHex`, `createdAt`, `lastCookedAt`, `lastCookedRecipeID`, `lastCookedTitle`, `cookingStartedAt` | recordName = `profile_<iCloudUserRecordName>` |
| `Friendship` | `userA`, `userB` (queryable, lexicographic pair), `requesterID`, `status` (queryable), `acceptedAt` | One record per pair; deny is destructive |
| `PublishedRecipe` | `ownerID`, `localRecipeID`, `recipeTitle`, `updatedAt`, `originalCreatorID`, `originalRecipeID`, `summary`, `tags` (String List), `photo0`–`photo19` | recordName = `Recipe.id.uuidString`; `summary`+`tags` not queryable |
| `RecipeImport` | `originalCreatorID`, `originalRecipeID`, `importerID`, `importerDisplayName`, `sourceUserID`, `importedAt` | Append-only audit log |

Photo cap: 10 MB per photo (`maxCloudPhotoBytes`), 40 MB total. `photo0`–`photo19` must be added manually in CloudKit Console.

Push subscriptions: `friendship-events-A-<me>`, `friendship-events-B-<me>`, `recipe-import-events-<me>`. Silent pushes only. Fan-out: `AppDelegate` → `CloudKitSubscriptions.dispatchRemoteNotification` → `Notification.Name.cloudKitSubscriptionFired`.

---

## Signing / portal

**GitHub Secrets:** `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_P12_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`, `IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64`, `APPSTORE_API_KEY_P8_BASE64`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`.

**Cloudflare Pages env:** `CLOUDKIT_CONTAINER_ID`, `CLOUDKIT_KEY_ID`, `CLOUDKIT_PRIVATE_KEY` (encrypted), `CLOUDKIT_ENVIRONMENT`, `ANTHROPIC_API_KEY` (encrypted — used by `/api/parse` Worker proxy).

**Entitlements** (`Resources/LlamasCookbook.entitlements`): App Group, SIWA, iCloud CloudKit, Associated Domains (`applinks:llamascookbook.pages.dev`), `aps-environment`. Regenerate profile after any capability change.

**`UIDesignRequiresCompatibility = true`** — Liquid Glass opt-out. Remove before iOS 27 forces it off.

**AASA** (`cloudflare-pages/.well-known/apple-app-site-association`): `GYFN949Q5E.com.llamascookbook.app` against `/r/*`.

**Image proxy** (`img/[id].js`): 10 MB cap, magic-byte sniff (JPEG/PNG/WebP/HEIC). `photoURL` is a CKAsset signed downloadURL — only ever originates from CloudKit lookup (not user-supplied), but a hostname allowlist (`*.icloud.com` / `*.apple-cloudkit.com`) would be belt-and-suspenders against a spoofed record.

**Keychain** (`KeychainStore.swift`): `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable.

---

## Llama Pro crown surfaces

Three subscription tiers drive three icon tiers: **free** → base llama; **Pro Monthly** → crown; **Pro Yearly** → crown + sunglasses.

`LlamaProStore.Plan` enum: `.none` (free), `.monthly`, `.yearly`. `isPro` is `plan != .none`. `plan.displayLabel` → `""` / `"Llama Pro Monthly"` / `"Llama Pro Yearly"` — rendered as the plan pill label in `ProfileView.header`.

Product IDs:
- `com.llamascookbook.app.pro.monthly` → `LlamaProStore.monthlyProductID`
- `com.llamascookbook.app.pro.yearly` → `LlamaProStore.yearlyProductID`

Crown assets (monthly tier):
- `Llama-Pro-Icon-Crown` — generic (home tab, recipe detail principal, cook mode, recipe-card placeholder, empty-library state, paywall)
- `Llama-Pro-Icon-Friends-Crown` — friends context (friends tab bar icon, friends CookbookHeader top-left, watermark, "Your Llama" seed-friend card)
- `Llama-Pro-Icon-Profile-Crown` — profile context (profile tab bar icon, library top-right profile button, profile page header)

Crown + sunglasses assets (yearly tier — same surface mapping, `*-Sunglasses` suffix):
- `Llama-Pro-Icon-Crown-Sunglasses`
- `Llama-Pro-Icon-Friends-Crown-Sunglasses`
- `Llama-Pro-Icon-Profile-Crown-Sunglasses`

Implementation pattern:
- `LlamaLogoOrCrown(size:accent:crownAsset:yearlyCrownAsset:)` — use for `LlamaLogo` replacements; handles `plan` internally. `crownAsset` defaults to `Llama-Pro-Icon-Crown`; `yearlyCrownAsset` defaults to `Llama-Pro-Icon-Crown-Sunglasses`. Profile header passes explicit context-specific values for both params.
- `Image(proStore.plan == .yearly ? "X-Crown-Sunglasses" : proStore.isPro ? "X-Crown" : "X")` — 3-way conditional for named-image call sites (profile button, friends header icon, watermark, seed friend card).
- **Tab bar crown icons must use `proTabIcon(named:)` (private to `RootView`)** — crown assets are header/logo sized (~96–140pt); UIKit does not reliably downscale them to the ~26pt tab bar slot. `proTabIcon` pre-renders via `UIGraphicsImageRenderer(size: CGSize(width: 26, height: 26))` at high interpolation before passing to the tabItem. Free-tier icons (`Home_Llama_Icon`, `Friends_Llama_Icon`, `Profile_Llama_Icon`) are already tab-bar sized and do not need this treatment. **Never revert tab bar Pro icons to a bare `Image(name)` call.**

`PaywallView` shows a yearly/monthly plan picker (yearly pre-selected as "Best value"). Subscribe button calls `proStore.purchase(product)` with the selected plan's product. `proStore.yearlyProduct` / `proStore.monthlyProduct` are separate `Product?` properties loaded in `loadProduct()`. The llama at the top of `PaywallView` uses `LlamaLogoOrCrown(size: 96, accent: AppColor.accent)` — it reflects the user's current tier (base/crown/crown+sunglasses) and always uses the fixed terracotta accent, not the user's custom accent color. The plan picker is tier-aware: free users see Yearly + Monthly; monthly users see Yearly only (they're already paying monthly, upgrade path is yearly only); yearly users never open the paywall (no chip surfaces it). **Never show a plan card for the plan the user already holds.** `PaywallView` dismisses on `.onChange(of: proStore.plan)` — **not** `isPro` — so that a monthly→yearly upgrade (where `isPro` was already `true` and never changes) still triggers dismiss + quota refresh.

**`RecipeDetailView` principal toolbar icon**: `LlamaLogoOrCrown(size: 52, accent: appearance.accentColor)` with `.padding(.top, 32).padding(.bottom, 36)` — total bar height ~120pt. Do not increase the size back to 72pt (it read as oversized at that scale). The extra bottom padding clears the crown shadow's y-offset.

**Plan pill + upgrade chips (ProfileView, ImportFromPhotoView)**: tier pills and upgrade chips always use `AppColor.accent` (terracotta `#C97C5D`), **not** `appearance.accentColor`. These are identity surfaces that should stay anchored to the brand color regardless of the user's chosen accent. Upgrade chip logic: `.none` → Monthly + Yearly chips; `.monthly` → Switch to Yearly chip only; `.yearly` → `EmptyView()` (no chips). Never show a "Switch to Yearly" chip to an already-yearly user.

`RootView` owns `@Environment(LlamaProStore.self) private var proStore` and must re-inject `.environment(proStore)` into every `fullScreenCover` / `sheet` that contains llama surfaces (currently: `CookModeView` fullScreenCover). `CookModeView`, `FriendCardView`, and `ProfileView` also declare `@Environment(LlamaProStore.self) private var proStore` directly. All other call sites inherit it from the app-level injection.

`activate-pro.js` accepts both product IDs via `PRODUCT_IDS` Set; TTL is derived from `expiresDate` in the JWS so yearly subscriptions get the correct longer TTL automatically.

## UX guardrails

- Quick-add rows + Return-to-add; gesture fallbacks always visible.
- Cook Mode: large type, warm cream background, check-off flow, ready overlay.
- Quantity: strings, mixed fractions, `&` output, measurable chip set only.
- Carousels: no inline reorder arrows — use dedicated reorder mode (`PhotoReorderView`).
- **Favorited recipe card thumbnail**: `HeartShape()` clip + stroke for ALL favorited recipes. `showsHeartThumbnail` is simply `recipe.favorite`; no separate heart glyph next to the title.
- **`RecipeDetailView` photo strip** (`photosButton`): fixed 84pt height row — 0 photos → Add tile only; 1 photo → photo + Add tile; 2 photos → 2 photos + Add tile; 3+ photos → first 2 photos + "+N more" overflow chip (taps open carousel at index 2). No horizontal `ScrollView` — always exactly 2 slots visible plus the overflow/add button. Do not revert to unlimited scroll.
- Llama tour: interactive, dim/halo `.allowsHitTesting(false)`. No Skip button; Exit pill below nav row (hidden on last step — "Got it!" suffices). Eight steps; step 5 auto-advances when the first ingredient is added. See `llama-intro.md`.
- Duplicate title import: `nextAvailableTitle(base:)` on `ImportFromTextLinkView` checks SwiftData before pushing to the editor for both URL and text paths; shows an alert with the suggested `Title (N)` name. Friend cookbook imports also go through this check. Never silently auto-rename — always confirm with the user first.
- Social copy: "shared", "appears in Friends", "unlisted". Never "private to friends".
- Friend surfaces: tint in friend's accent. Presence dot: filled+pulsing when `cookingStartedAt` < 6h, hollow when idle.
- **Friends empty state threshold**: `isBelowSocialThreshold` = `friends.count < 3` — below 3: accent-tinted `Friends_Llama_Icon_Large` watermark + "Looking for a friend?" CTA below the grid (title + subtitle + Add Friend button, same sheet as toolbar `+`). At 3+: same `Friends_Llama_Icon_Large` watermark but tint `.clear` (no accent shadow), CTA hidden. The seed friend counts, so fresh installs start at 1/3 and the CTA is always visible until 2 real friends are added.
- `LibraryView` profile button: `.disabled(editor.active != nil)` — not a silent no-op.
- **Tab bar**: `.accentTextOutline()` NOT applied — system `TabView`/UIKit strips modifiers from `.tabItem`.
- **Letterpress outline**: `.accentTextOutline()` (`Theme/AccentTextOutline.swift`) — four 0.4pt shadows at 0.22 opacity. Apply to prominent accent-tinted text/icons. Skip on: `AppColor.onAccent` glyphs, system alert buttons, carousel destructive glyphs, `.tabItem`, filter chip labels/icons (too small — creates a halo at 13pt), ingredient row quantity/unit/bullet.
- **Accent glow cascade**: when the user changes accent color, two independent ripples fire in parallel — one through the library UI, one top-to-bottom through `RecipeDetailView`. Each ripple is driven by its own stage var (`accentTransitionStage` / `detailTransitionStage`) so rawValue ordering in one can't cross-contaminate the other.
  - **Library**: header (T+0ms) → categories (220ms) → recipeList/cards (440ms) → + button (660ms) → bottom nav (880ms) → cleanup (1150ms).
  - **Detail** (9 zones, `DetailTransitionStage` in `AppearanceSettings`): nav icons (T+0ms) → title (120ms) → provenance/saved-by chip (240ms) → ingredients underline (380ms) → conversions+sourdough chips (490ms) → ingredient rows (590ms) → steps underline (690ms) → step numbers+timer icons (790ms) → Start Cooking bar (860ms) → cleanup (1150ms).
  - `accentGlow(when:color:)` (`AccentTextOutline.swift`) — double shadow at radius 7+14, opacity 0.16+0.07, easeInOut 0.14s. Glow on ingredient rows/step rows must be applied to the **section container** (outside `.drawingGroup()`), not individual row views — shadows inside a drawingGroup are clipped to the texture bounds. The `section(_:headingColor:headingGlow:containerGlow:containerGlowColor:accessory:content:)` helper carries all four stage params; defaults produce no glow for sections without a cascade zone (Notes, General, Reference).

---

## Testing

### JavaScript (Cloudflare Workers)

Runner: **Vitest v3**, Node ≥ 20. Run from `cloudflare-pages/`:

```
npm test          # one-shot (CI)
npm run test:watch
```

Config: `cloudflare-pages/vitest.config.js` — `environment: 'node'` (Web Crypto `crypto.subtle` is available globally in Node 20+).

Test file: `cloudflare-pages/test/quota.test.js` — 26 tests across 5 suites:
- `quota constants` — `FREE_CAP`, `PRO_CAP`
- `getLocalYYYYMM` — UTC, LA (PDT = UTC-7), UTC+8, IST (UTC+5:30), Nepal (UTC+5:45) edge cases
- `nextMonthResetUTC` — year rollover, DST offset, half-hour offset (18:30 UTC for IST, 18:15 for Nepal)
- `quota cap arithmetic` — remaining/exhausted formulas
- `deriveAppAccountToken` — UUID format, version bit (4), variant nibble (8–11), determinism, cross-sub uniqueness

**Shared module:** `cloudflare-pages/lib/quota.js` is the single source for `FREE_CAP`, `PRO_CAP`, `getLocalYYYYMM`, `nextMonthResetUTC`, `deriveAppAccountToken`. All four worker files import from it — never re-inline these. All date helpers accept an optional `now` parameter (default `new Date()`) so tests can inject fixed timestamps.

### Swift (iOS)

Runner: **XCTest**, wired via `LlamasCookbookNativeTests` target in `ios-native/project.yml`. After running `xcodegen`, the suite appears under the main scheme in Xcode (⌘U).

Test files live in `ios-native/Tests/LlamasCookbookTests/`:

| File | Covers |
|---|---|
| `LlamaProStoreTests.swift` | `Plan.isPro`, `Plan.displayLabel`, `appAccountToken` (nil/empty guard, UUID v4/variant bits, determinism, pinned SHA-256 derivation) |
| `QuotaSnapshotTests.swift` | `isPro`, `isMonthlyExhausted` (zero/positive/negative remaining), `resetDateFormatted` |
| `QuantityTests.swift` | `parse`, `format`, `scale`, `displayFormat`, `combine`; `ClockFormat.mmss`; `StringCase.cookbookTitle/friendsTitle/titleCase` |
| `SourdoughCalculatorTests.swift` | 10-row table, ascending ratios, water==flour invariant, sum==total, `gramsValue`, `formatGrams`, `label`, `compactTimeRange` |
| `FormattersTests.swift` | `shortMonthDay` ("MMM d") and `date` (.medium) formatters |
| `StringExtensionsTests.swift` | `Optional<String>.trimmedIfNonEmpty` — nil, whitespace, newline, trim, internal space preservation |
| `SeedFriendTests.swift` | `sentinelRecordName`, `isSeed` true/false, profile fields; **does not call `loadPayload()`** — safe in unit test bundle |
| `RecipeImporterTests.swift` | `cleanTitle` (passthrough, "Title:" strip, "Recipe👇" strip, trailing emoji, image path → ""); `mergeOrphanDurationSteps` (glue, preserve, first-step kept, trailing comma cleanup) |

**Target settings** (in `project.yml`):
- `PRODUCT_BUNDLE_IDENTIFIER: com.llamascookbook.app.tests`
- `GENERATE_INFOPLIST_FILE: YES`
- `SWIFT_STRICT_CONCURRENCY: minimal`
- `CODE_SIGN_STYLE: Automatic`

**What's not tested (by design):** network calls (`QuotaService.refresh`, `LlamaProStore.purchase`), CloudKit operations, SwiftData persistence, StoreKit purchase flow, UI/SwiftUI views. These are integration-layer concerns; unit tests stay on pure logic.

---

## Open work (pre-App Store)

- **Privacy manifest `NSPrivacyCollectedDataTypes`:** Currently empty. App sends recipe text to Anthropic via Cloudflare proxy (third-party AI). Needs an entry and a user-facing disclosure in the import UI before App Store submission.
- **App Store privacy labels:** Audit against CloudKit sharing + Anthropic AI processing.
- Verify Universal Links on real devices.
- Adopt Liquid Glass before iOS 27 drops the `UIDesignRequiresCompatibility` opt-out.
- Server-side uniqueness for `Friendship(userA,userB)` — currently client-side dedup only.
- Account-deletion cascade: CKQuerySubscriptions single-shot best-effort; five record-type cascades route through `CloudPendingDeleteQueue`.
- Pre-launch: delete `credentials/github-secrets.txt`, `credentials/ios/dist-cert.p12`, `credentials/ios/profile.mobileprovision` from dev box (gitignored, not committed).
