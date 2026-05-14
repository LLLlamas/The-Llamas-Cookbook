# CLAUDE.md

Source of truth for agents. Code wins when this disagrees.
Last refreshed: 2026-05-14 (session 9 — photo import streaming: Sonnet SSE reveal in `PhotoImportPreviewView`, removed "What are we cookin'?" title input + Ready/Review state, 1-hour Anthropic cache TTL, branch timing via `os_signpost`).

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
- `ImportFromTextLinkView.swift` — merged paste-text + URL-fetch sheet
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
- `LlamaProStore.swift` — StoreKit 2 wrapper; Phase 2 wires purchase + ASN V2 webhook
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
- **`StreamingRecipeState`** (`@Observable @MainActor`) is the live binding the streaming preview reads from. `AnthropicRecipeParser.parseImagesStreaming` populates it via `applyEvent` as `input_json_delta` chunks arrive. `onFirstContent` fires exactly once when the first content lands — used by `ImportFromPhotoView.runImport` to pop `PhotoImportPreviewView` and dismiss the processing overlay. `status` transitions `waitingForFirstByte → streaming → completed` (or `.cancelled`/`.failed`). `finalDraft` is set on completion; the preview reads from it once `streamFinalDraftReady` flips so post-processed step-splitting / plural-normalization apply.
- **`QuotaService`** is `@MainActor @Observable`, injected via environment from `LlamasCookbookApp`. `refresh(force: false)` respects a 60-second cache; `refresh(force: true)` always fetches. `consume()` returns `ConsumeResult` — `.race` triggers the "this one's on us" banner in `PhotoImportPreviewView`.
- **Parse-result cache**: Worker caches vision responses in KV keyed by `parseCache:<promptVersion>:model=<model>:<contentHash>` — model is included so Haiku and Sonnet results are stored separately (prep for routed cascade). `PROMPT_VERSION = "v1"` — bump in `parse.js` whenever `RecipeAIParser.instructions` changes. Cache hits skip the daily parse counter but still pre-check monthly quota. **Streaming responses are assembled before caching**: the Worker tees the upstream SSE stream — one branch streams to iOS, one accumulates and decodes the final tool_use input into the non-streaming JSON shape (`messages.create` response format) which is what gets written to KV. Cache hits are always returned non-streaming (with `x-llamas-cache: hit`), regardless of whether the call that populated them streamed.
- **Photo-import flow** — `ImportFromPhotoView.runImport` prepares pages in two formats in parallel (`.aiVision` pixel-capped JPEG ≤1568px long edge AND ≤1.2MP; `.ocr` 2560px). Cascade: (1) on-device OCR + `RecipeImporter.parse` → `localPhotoParseConfident` gate (≥3 ingredients with qty/unit, ≥2 steps ≤220 chars, explicit section label in text) — free if confident; (2) **streaming Sonnet vision** via Cloudflare proxy (`RecipeAIParser.parseImagesStreaming`) — preview pops the moment the first content event lands (~1-2 s after request fires) and title/ingredients/steps tick in progressively as Anthropic emits each completed JSON sub-value; (3) OCR text reused for `parseBestOf(preferHighQuality:true)` fallback if the stream produced no usable draft. The legacy "What are we cookin'?" title input and "Ready / Review Recipe" state were removed once streaming made their perceived-speed job obsolete — the processing overlay is now just a llama + status text and dismisses as soon as the preview pops. Banner "Edit as text" is the final fallback. **Anthropic vision rejects HEIC** — `aiVision` forces JPEG via `forcesJPEGOutput`. Vision timeout 60s; same 429/529 backoff as text. OCR text is computed once and reused by the AI fallback — never recognized twice. Per-import branch + timing is logged via `os_signpost` + a single `Logger.info` summary line under subsystem `com.llamascookbook.app`, category `photoImport` (never logs recipe content).
- **Streaming reveal in `PhotoImportPreviewView`** — when bound to a `StreamingRecipeState` the preview renders from live state during the stream and from `streamingState.finalDraft` after `message_stop`. Save button is disabled until `status == .completed`. Skeleton placeholders pulse for sections not yet arrived. Aesthetic tick-in animations: title fades + scales (0.4s ease-out), ingredient rows spring in from the leading edge (response 0.4, damping 0.75, 20pt offset), step rows spring in from below (response 0.5, damping 0.8, 12pt offset). Soft haptic on title arrival only. Driven by Anthropic's actual token rate via the parser's `applyEvent` calls — no artificial throttling. Save Cancel buttons stay accessible throughout; user can cancel mid-stream and the existing OCR-text fallback re-runs.

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

## UX guardrails

- Quick-add rows + Return-to-add; gesture fallbacks always visible.
- Cook Mode: large type, warm cream background, check-off flow, ready overlay.
- Quantity: strings, mixed fractions, `&` output, measurable chip set only.
- Carousels: no inline reorder arrows — use dedicated reorder mode (`PhotoReorderView`).
- **Favorited recipe card thumbnail**: `HeartShape()` clip + stroke for ALL favorited recipes. `showsHeartThumbnail` is simply `recipe.favorite`; no separate heart glyph next to the title.
- **`RecipeDetailView` photo strip** (`photosButton`): fixed 84pt height row — 0 photos → Add tile only; 1 photo → photo + Add tile; 2 photos → 2 photos + Add tile; 3+ photos → first 2 photos + "+N more" overflow chip (taps open carousel at index 2). No horizontal `ScrollView` — always exactly 2 slots visible plus the overflow/add button. Do not revert to unlimited scroll.
- Llama tour: interactive, dim/halo `.allowsHitTesting(false)`. No Skip button; Exit pill below nav row (hidden on last step — "Got it!" suffices). Eight steps; step 5 auto-advances when the first ingredient is added. See `llama-intro.md`.
- Duplicate title import: prompt + prefill `Title (N)`, including friend cookbook imports.
- Social copy: "shared", "appears in Friends", "unlisted". Never "private to friends".
- Friend surfaces: tint in friend's accent. Presence dot: filled+pulsing when `cookingStartedAt` < 6h, hollow when idle.
- **Friends empty state threshold**: `isBelowSocialThreshold` = `friends.count < 3` — below 3: accent-tinted `Friends_Llama_Icon_Large` watermark + "Looking for a friend?" CTA below the grid (title + subtitle + Add Friend button, same sheet as toolbar `+`). At 3+: same `Friends_Llama_Icon_Large` watermark but tint `.clear` (no accent shadow), CTA hidden. The seed friend counts, so fresh installs start at 1/3 and the CTA is always visible until 2 real friends are added.
- `LibraryView` profile button: `.disabled(editor.active != nil)` — not a silent no-op.
- **Tab bar**: `.accentTextOutline()` NOT applied — system `TabView`/UIKit strips modifiers from `.tabItem`.
- **Letterpress outline**: `.accentTextOutline()` (`Theme/AccentTextOutline.swift`) — four 0.4pt shadows at 0.22 opacity. Apply to prominent accent-tinted text/icons. Skip on: `AppColor.onAccent` glyphs, system alert buttons, carousel destructive glyphs, `.tabItem`.

---

## Open work (pre-App Store)

- **Privacy manifest `NSPrivacyCollectedDataTypes`:** Currently empty. App sends recipe text to Anthropic via Cloudflare proxy (third-party AI). Needs an entry and a user-facing disclosure in the import UI before App Store submission.
- **App Store privacy labels:** Audit against CloudKit sharing + Anthropic AI processing.
- Verify Universal Links on real devices.
- Adopt Liquid Glass before iOS 27 drops the `UIDesignRequiresCompatibility` opt-out.
- Server-side uniqueness for `Friendship(userA,userB)` — currently client-side dedup only.
- Account-deletion cascade: CKQuerySubscriptions single-shot best-effort; five record-type cascades route through `CloudPendingDeleteQueue`.
- Pre-launch: delete `credentials/github-secrets.txt`, `credentials/ios/dist-cert.p12`, `credentials/ios/profile.mobileprovision` from dev box (gitignored, not committed).
