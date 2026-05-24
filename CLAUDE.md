# CLAUDE.md

Source of truth for agents. Code wins when this disagrees.
Last refreshed: 2026-05-24

---

## Stack

- Swift 5.10, SwiftUI, SwiftData, iOS 26+ / iOS 26 SDK
- `SWIFT_STRICT_CONCURRENCY: minimal`
- XcodeGen: `ios-native/project.yml` — do not hand-edit generated Xcode files
- CI: `macos-26` runner, Xcode 26. **Windows dev — do NOT run `xcodegen`/`xcodebuild`/CocoaPods**
- Bundle IDs: `com.llamascookbook.app` (main), `.widget`, `.shareext`
- App Group: `group.com.llamascookbook.app` — must match in 4 places: `SharedContainer.appGroupID`, main app entitlements, share extension entitlements, portal profiles
- CloudKit container: `iCloud.com.llamascookbook.app` — public DB, world-readable/writable
- Universal Link host: `llamascookbook.pages.dev`
- Team: `GYFN949Q5E`. ASC app id: `6762527184`

---

## Directory Map

| Area | Path |
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
| Web preview + Worker API | `cloudflare-pages/` |

---

## Feature → Files

**App shell** — `Sources/App/`
- `LlamasCookbookApp.swift` — `@main`, `ModelContainer`, `AppDelegate` (APNs, remote-push dispatch)
- `RootView.swift` — tab bar, deep-link routing, sheet/cover orchestration; owns `proTabIcon(named:)` for tab bar Pro icons
- `EditorCoordinator.swift`, `NavigationContext.swift`, `CookingSession.swift`, `CookingSessionState.swift`
- `FriendsStore.swift` — `@MainActor` cache; UserDefaults-backed stale-while-revalidate
- `UserAccount.swift` — SIWA identity, sign-out, delete cascade
- `AppearanceSettings.swift` — accent color; `applySignedOut()` / `restoreFromDefaults()` driven by `LlamasCookbookApp`

**Data models** — `Sources/Models/`
- `Recipe.swift` — `Recipe`, `Ingredient`, `RecipeStep`, `RecipePhoto`, `RecipeStepPhoto`; chain-attribution fields
- `DraftRecipe.swift` — editor draft; `Recipe.apply(_:)` defined here

**Theme** — `Sources/Theme/`
- `AppColor`, `AppFont`, `AppSpacing`, `ColorHex`, `AccentTextOutline`

**Library / import** — `Sources/Views/Library/`
- `LibraryView.swift`, `RecipeCardView.swift`, `EmptyLibraryView.swift`, `ImportHelpView.swift`
- `ImportFromTextLinkView.swift` — merged paste + URL sheet; focus-mode dimming, duplicate-title check via `nextAvailableTitle(base:)`
- `ImportFromPhotoView.swift`, `RecipeImportPreviewView.swift`, `PhotoImportPreviewView.swift`
- `LetterIndex.swift`, `CookbookHeader.swift`
- Lib: `RecipeImporter.swift`, `RecipeURLImporter.swift`, `RecipeOCRImporter.swift`, `RecipeAIParser.swift`, `AnthropicRecipeParser.swift`, `StreamingRecipeParser.swift`, `RecipeSchemaParser.swift`, `RecipeExport.swift`
- Lib: `QuotaService.swift` — `@MainActor @Observable` singleton; polls `/api/usage`, fires `/api/usage/consume`
- Lib: `LlamaProStore.swift` — StoreKit 2 wrapper

**Editor** — `Sources/Views/Editor/`
- `RecipeEditorView.swift`
- `IngredientRowEditor.swift`, `IngredientQuickAdd.swift`, `StepRowEditor.swift`, `StepQuickAdd.swift`, `SpecialNotesEditor.swift`, `TagInputView.swift`, `PhotoToggleButton.swift`
- `Chips/QuantityChips.swift`, `UnitChips.swift`
- Lib: `TagPresets.swift`, `IngredientDisplay.swift`, `Plural.swift`

**Detail / share** — `Sources/Views/Detail/`
- `RecipeDetailView.swift`
- `ImportersListSheet.swift`, `AttributionSheet.swift`, `ConversionsView.swift`, `SourdoughCalculatorView.swift`
- Lib: `RecipeShare.swift` (wire format), `CloudKitService.swift` (upload/fetch/delete), `ImportCountCache.swift`

**Cook mode** — `Sources/Views/Cook/`
- `CookModeView.swift`
- Lib: `TimerNotifications.swift` — AlarmKit (`AlarmManager.shared`); `ResumeCookModeIntent.swift`
- `Shared/TimerAlarmMetadata.swift`; Widget: `TimerLiveActivity.swift`, `TimerWidgetBundle.swift`

**Friends / social** — `Sources/Views/Friends/`, `Sources/Lib/`
- `FriendsTabView.swift`, `FriendLibraryView.swift` (`showsBackButton: Bool = true`), `FriendRecipeDetailView.swift`
- Lib: `CloudKitFriendship.swift`, `CloudKitUserProfile.swift`, `CloudKitPublishedRecipe.swift`, `CloudKitRecipeImport.swift`, `CloudKitSubscriptions.swift`, `CloudPendingDeleteQueue.swift`, `UserProfileMirror.swift`, `LibraryMirrorService.swift`
- `SeedFriend.swift` + `SeedRecipes.json` — "Your Llama" synthetic friend; always `friends[0]`

**Quota + IAP** — `Sources/Lib/`, `Sources/Views/Profile/`
- `QuotaService.swift`, `LlamaProStore.swift`, `PaywallView.swift`

**Auth** — `Sources/Lib/`
- `SignInWithAppleService.swift`, `KeychainStore.swift`

**Share extension** — `ShareExtension/`
- `ShareViewController.swift` — URL → `llamascookbook://share-url/`, file → App Group inbox
- `Sources/Shared/SharedContainer.swift`, `Base64URL.swift`

**Cloudflare Workers** — `cloudflare-pages/`
- `functions/r/[id].js` — OG preview; `functions/img/[id].js` — image proxy (10 MB cap, magic-byte sniff)
- `functions/api/parse.js` — Anthropic proxy + quota enforcement + KV parse-result cache
- `functions/api/usage.js` (GET quota snapshot), `functions/api/usage/consume.js` (POST save-confirm)
- `lib/cloudkit.js` — CloudKit Web Services client (ECDSA P-256); `lib/quota.js` — shared quota helpers
- `.well-known/apple-app-site-association` — AASA

**Reusable components** — `Sources/Views/Components/`
- `PhotoCarouselView`, `PhotoReorderView`, `CameraCaptureView`, `ShareSheet`, `LlamaLogo`, `LlamaWatermark`, `LlamaProgressIndicator`
- `LlamaFloatModifier.swift` — `.llamaFloat()` bob animation; 250ms delayed start (do not remove)
- `AccentColorPicker.swift`, `SavedToast.swift`, `RecipeImageView.swift`
- Lib: `ImageProcessing.swift`, `Conversions.swift`, `Quantity.swift`, `SourdoughCalculator.swift`, `Haptics.swift`, `SwipeBack.swift`, `AppMetadata.swift`

**Shared helpers — always reuse, never re-inline**

| Helper | File | Purpose |
|---|---|---|
| `View.cardScrollTransition()` | `Components/View+CardScrollTransition.swift` | Scroll-focus zoom on card lists |
| `View.cardGlare(cornerRadius:)` | `Components/View+CardGlare.swift` | Card glare: soft sweep-in on entry + scroll-reactive shine + static top/bottom edge depth rim, clipped to card shape |
| `View.scrollSectionHaptic(section:ticker:)` + `ScrollSectionTicker` | `Components/ScrollSectionHaptic.swift` | Per-section scroll tick — fires on (a) letter-section boundaries while free-scrolling cookbook list rows, (b) each chip crossing on category/tag chip strips (`LibraryView.filterStrip`, `CategoryFilterStrip`, `RecipeDetailView` / `FriendRecipeDetailView` tags), and (c) each major-section boundary while scrolling `RecipeDetailView` / `FriendRecipeDetailView` content (anchored by a 1pt `sectionAnchor("ingredients"/"steps"/…)` so tall sections still hit the 0.95 threshold). One `ScrollSectionTicker` per scroll surface, never shared — `RecipeDetailView` / `FriendRecipeDetailView` use ONE shared ticker for tags + section anchors (same vertical surface); the horizontal chip strips have their own. Call `ticker.reset()` when the section/tag/chip set changes wholesale (LibraryView on `allTags` change, CategoryFilterStrip on `categories` change, RecipeDetailView on `recipe.id` change, FriendRecipeDetailView on each `loadDetail()`). `ticker.magnifyLetter` is the observable `LetterIndex` magnify-pulse channel (set only on a real crossing, never on first report or `reset()`) |
| `Haptics.*` | `Lib/Haptics.swift` | ALL haptic feedback. Every call site MUST go through a named `Haptics.*` function (`selection()`, `success()`, `warning()`, `impact(_:)`, `recipeSaved()`, `cookModeStarted()`, `timerAlmostDone()`) — never construct `UINotificationFeedbackGenerator` / `UIImpactFeedbackGenerator` / `UISelectionFeedbackGenerator` inline at a call site. Generators live only inside `Haptics.swift`; add a new named wrapper there if one is missing. Never fire from a `@ViewBuilder` body — only callbacks / `.onChange` / `.task` / `.onAppear` / button actions |
| `View.surfaceCard(cornerRadius:)` | `Components/View+SurfaceCard.swift` | Settings/info card chrome |
| `View.liftedCard()` | `Components/View+Lifted.swift` | Static drop shadow, non-interactive cards |
| `.buttonStyle(.lifted)` | `Components/View+Lifted.swift` | Press-down shadow + 0.96 scale |
| `.buttonStyle(.scaleOnly)` | `Components/View+Lifted.swift` | Scale-only, no shadow (elevated surfaces) |
| `LlamaLogoOrCrown(size:accent:crownAsset:)` | `Components/LlamaLogoOrCrown.swift` | Llama / Pro crown swap |
| `Formatters.date` | `Lib/Formatters.swift` | All date display — `.medium` style only |
| `Optional<String>.trimmedIfNonEmpty` | `Lib/String+Extensions.swift` | Trim + nil-if-empty |
| `UserProfileSnapshot.resolvedAccent` | `Lib/CloudKitUserProfile.swift` | Friend accent with terracotta fallback |
| `LetterIndex.firstItem(in:atOrAfter:letters:bucket:)` | `Components/LetterIndex.swift` | Letter-scrub traversal |

---

## Critical Invariants

### SwiftData
- `cloudKitDatabase: .none` — cascade deletes + non-optional props break CloudKit auto-opt-in (silently degrades to in-memory)
- `RecipeStep.image` and `Recipe.imageUri` are deprecated migration baggage — do not repurpose
- `Recipe.apply(_:)` must NOT touch `sharedBy`/`sharedAt`/`sourceShareID` or any `originalCreator*`/`originalSharer*`/`originalRecipeID`/`importedAt` — attribution is stamped at materialize time and must survive saves

### CloudKit
- `UserProfile` recordName = `profile_<iCloudUserRecordName>` — prefix applied/stripped in `CloudKitUserProfile.swift`; callers pass raw record names
- `PublishedRecipe.recordName == Recipe.id.uuidString`
- Predicates must be **split per field, not OR** — public-DB OR on non-queryable fields throws `invalidArguments`
- `queryAllRecords` must follow cursors — never truncate to first page
- HEIC → JPEG before CloudKit upload via `ImageProcessing.transcodeHEICToJPEGForSharing`; local SwiftData stays HEIC
- `RecipeShareLimits.maxInboundBytes` (25 MB) in `Sources/Shared/` — shared by app and share extension

### SwiftUI / iOS 26
- **Re-inject `@Observable` environments into every `sheet`/`fullScreenCover`** — values drop across presentation boundaries on iOS 26
- Custom back buttons: `.navigationBarBackButtonHidden(true)` + `.enableSwipeBack()` (`SwipeBack.swift`). `RecipeEditorView` intentionally omits `.enableSwipeBack()` (Cancel/Save, data-loss risk)
- `AccentColorPicker` commits on `.onDisappear` — driving it earlier desyncs `UIColorPickerViewController`
- `.drawingGroup()` goes INSIDE `.clipShape()` / before outer shadows. Never apply to views using `.blur()` or `.regularMaterial`
- `.buttonStyle(.lifted)` must NOT be applied inside `.drawingGroup()` — shadows clip to texture bounds
- `cardGlare(cornerRadius:)` — apply AFTER the card's `.drawingGroup()` (it's a thin overlay); pass the SAME radius the card clips to so all layers stay inside the corners. Renders three layers: a soft one-shot sweep-in, a scroll-reactive shine, and a static always-on top/bottom edge-depth rim. Sweep + shine positioning runs entirely via `visualEffect` (layout-pass, no `body` invalidation) + a one-shot `onAppear` sweep; the edge-depth rim has NO state/animation/`visualEffect` — never per-frame `@State`
- Scroll-list haptics: fire via `scrollSectionHaptic(section:ticker:)` per row, NOT inline. One `ScrollSectionTicker` per list (`@State`); call `ticker.reset()` on filter/sort change so a re-populated list doesn't tick on settle. The horizontal category-chip strips (`LibraryView.filterStrip`, `CategoryFilterStrip`) use the same modifier with their OWN per-strip ticker — never share with the recipe-list ticker, or moving focus between strip and list mis-ticks; reset on chip-set change
- Scroll-driven `LetterIndex` magnify: feed `scrollTicker.magnifyLetter` into `LetterIndex(scrollFocusLetter:)` — `magnifyLetter` is set only on a real boundary crossing (never on first report or `reset()`), so the pulse stays synced one-to-one with the haptic. Each free-scroll section crossing pulses the compact magnify badge (quick fade-in / brief hold / fade-out), synced to the scroll-haptic tick. `scrollFocusLetter` is a SEPARATE channel from `externalHighlightLetter` — the transient scroll pulse and persistent post-save flash render in their own overlay layers with their own state; do not overload one for the other. Precedence: an active scrubber drag (`activeIndex`) and the post-save flash (`externalHighlightLetter`/its fading echo) BOTH outrank the scroll pulse — `pulseIndex` is `nil` whenever either owns the badge. Pulse is event-driven (one `withAnimation` per crossing), never per-frame `@State`

### Auth / Social
- `UserProfileMirror.cachedRecordID()` is the canonical "is iCloud bound?" check — all social writes short-circuit when nil
- `FriendsStore.refresh()` sets `isRefreshing` synchronously before any `await` (re-entrancy guard)
- `LibraryMirrorService` — `@MainActor` singleton, 5s debounce per `Recipe.id`; sign-out/delete must call `resetBulkPublishMarker()`
- `ImportCountCache` lives in UserDefaults, not `@Model` — prevents spurious `LibraryMirrorService` re-publishes
- `SeedFriend.isSeed(_:)` short-circuits ALL CloudKit fan-outs (fetch, import, remove, etc.) — never remove this guard

### UserDefaults Caches (stale-while-revalidate)
- `LlamaProStore.plan` → key `"llamaPro.cachedPlan"` — always use `setPlan(_:)`, never direct assignment
- `FriendsStore` friends → key `"friendsStore.cachedFriends"` — only real CloudKit friends cached; seed friend always prepended programmatically. `clearOnSignOut()` removes the key

### Accent / Appearance
- Unsigned user accent is always terracotta — `applySignedOut()` uses `isForcingDefault` flag, never `resetToDefault()` (erases stored prefs)
- Plan pills and upgrade chips use `AppColor.accent` (terracotta `#C97C5D`), never `appearance.accentColor`
- `AppearanceSettings.previewAccentColor` is the uncommitted live pick — set continuously from `AccentColorPicker`'s `pickerColor` so the cookbook title retints instantly (no wait for the `.onDisappear` commit). It has NO didSet side-effects and `AccentColorPicker.body` must never read it (would re-snapshot `UIColorPickerViewController`). `cookbookTitleAccentColor` returns it when non-nil; `commitSelection` clears it. Only set while signed in
- Accent-cascade sequence (`startAccentTransition`) is strictly ordered, total run ~0.7s: All chip at t=0 (`.allChip` stage, `allChipAccentColor`) → header (llama glow + profile button) at t=0.08 → categories (Favorites + tag chips) at t=0.14 → `recipeList` stage at t=0.20 + BOTH per-row tokens bumped synchronously (`recipeCardCascadeToken`, `letterIndexCascadeToken`) → plus button at t=0.55 → bottom tab bar at t=0.66 → state clears at t=0.85. **The cookbook title is EXCLUDED from the header stage's color application**: `cookbookTitleAccentColor` returns `accentColor` directly (bypassing `transitionColor`), never the cascade-held old color — the title is already showing the new color from `previewAccentColor` before Done is tapped, and must not briefly revert to the old hue when the cascade fires. The header stage's glow (`isAccentGlowActive(.header)`) still applies to the llama and profile button; only the title color is excluded. Per-row stagger: each `RecipeCardView` and each `LetterRow` snapshot `cascadePreviousAccentColor` as a local `heldAccentOverride`, then clear it (and pulse glow) at `recipeListFlipDelay (0.20) + index * stagger` — cards at `recipeCardGlowStagger` (0.035s), letter rows at `letterIndexGlowStagger` (0.012s). Result: titles AND letter strip retint top → bottom in lockstep rather than flipping in unison. `LibraryView` MUST pass `index:` to `RecipeCardView` (via `filtered.enumerated()`) AND pass `previousAccent:` + `cascadeToken:` into `LetterIndex` or both staggers collapse. `isAccentGlowActive(.recipeList)` stays a single shared boolean that drives the global `LetterIndex` glow halo and the recipe-list color floor; per-row holds are layered on top. The All chip's `.allChip` stage is SEPARATE from `.categories` so the All pill can lead the cascade visibly before the rest of the chips. Friends/Profile `LetterIndex` call sites get `cascadeToken: 0` (default) and never bump it — those lists don't participate in the cascade

### Photo Import
- `ImportFromPhotoView` always sets `.interactiveDismissDisabled(true)` unconditionally — not just during OCR
- Anthropic vision rejects HEIC — `aiVision` format forces JPEG via `forcesJPEGOutput`
- `VisionParseOutcome.error` non-nil = Worker rejected (quota/auth/rate-limit) → do NOT fall through to OCR; refresh `QuotaService` instead
- `performSave` does NOT call `dismiss()` — `onSaved`/`onSavedForEdit` closures dismiss `ImportFromPhotoView`, collapsing the full sheet hierarchy in one animation
- Parse-result KV cache key: `parseCache:<promptVersion>:model=<model>:<contentHash>`. `PROMPT_VERSION = "v3"` in `parse.js` — bump whenever `RecipeAIParser.instructions` changes
- Photo-import quota: Free 5 saves/month, Pro 30/month, 5 parse attempts/day. iOS sends `x-llamas-user`, `x-llamas-tz`, `x-llamas-import-kind: photo`. Text/link imports are not gated. Consume is fire-and-forget (save to SwiftData first, then POST)

### AI Parser Chain
- Text/link: `RecipeAIParser.parseBestOf` → `AnthropicRecipeParser.parse` (CF Worker `/api/parse`) → Apple Intelligence → regex
- Photo: `RecipeAIParser.parseImagesStreaming` → streaming SSE Sonnet 4.6 → OCR text-AI fallback
- `AnthropicRecipeParser.isConfigured = true` unconditionally — API key lives in Cloudflare env only, never in binary or Keychain

### Performance
- `RecipeImageView` decodes asynchronously — NSCache hit = warm `@State`; miss = `Task.detached` off main thread. Never use synchronous `UIImage(data:)` in `body` (HEIC takes 50–150ms, stalls push-animation frames)
- `.llamaFloat()` has 250ms delayed start (`LlamaFloatModifier`) — do not remove when adding new call sites

### AlarmKit
- Cook-timer lock-screen alerts + Live Activity owned by AlarmKit. Sound always `AlertConfiguration.AlertSound.default`

### Haptics (`Lib/Haptics.swift`)
- All haptics route through the `Haptics` enum — never construct `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` / `CHHapticEngine` at a call site
- Named moments: `recipeSaved()` (CoreHaptics save thud — used by editor save + photo-import save), `cookModeStarted()` / `timerAlmostDone()` (ascending light→medium→heavy ramps), plus `impact`/`selection`/`success`/`warning`
- `recipeSaved()` is the canonical save feedback — text/link imports persist via `RecipeEditorView.save()`, so they already get the thud; do NOT fire it again in `ImportFromTextLinkView`
- CoreHaptics engine is a lazily-warmed `@MainActor` singleton (`HapticEngineHost`); rebuilds silently on iOS reset, falls back to `UIImpact(.heavy)` when haptics are unavailable

### Cook pills / bottom overlay clearance (`RecipeDetailView`)
- `CookingPillsOverlay` (applied per-tab in `RootView`) uses `.overlay(alignment: .bottom)`, NOT `safeAreaInset` — the scroll view inside `RecipeDetailView` doesn't automatically know about the pill.
- `RecipeDetailView` handles this with two layered mechanisms:
  1. `safeAreaInset(edge: .bottom)` — renders `startCookingBar` when no active cooks; renders `Color.clear.frame(height: 70)` when cook mode is minimized (resume pill visible). This is the **primary** clearance: it shrinks the scroll view's scrollable region so content can never rest behind an overlay.
  2. `.padding(.bottom, AppSpacing.xl + bottomOverlayClearance)` — adds runway so the Delete button clears the inset boundary. `bottomOverlayClearance` = 80 for the Start Cooking bar, 40 for the resume pill (safeAreaInset already handles the pill's footprint), 0 when Cook Mode is foregrounded.
- The 70pt spacer = pill height (~54pt) + `CookingPillsOverlay` bottom gap (`AppSpacing.md` = 12pt) + 4pt air.
- `CookPill` (non-compact path) enforces uniform height via `.lineLimit(1)` on the title `Text` — never `.lineLimit(2)` or higher. Long titles truncate with `.truncationMode(.tail)`. The compact path also uses `.lineLimit(2)` / `.minimumScaleFactor(0.7)` intentionally (compact pills are narrower and need wrapping), but only the standard single-pill uses strict `.lineLimit(1)`.

### CI
- `macos-26` renames beta Xcode `.app`s `_disabled_…` and re-pins both `DEVELOPER_DIR` and `PATH` — setting only `DEVELOPER_DIR` leaves sub-tools on the beta; TestFlight rejects beta-built archives

---

## CloudKit Schema

Public DB. World-readable/writable.

| Record type | Key fields | Notes |
|---|---|---|
| `RecipeShare` | `envelope` (Asset), `senderDisplayName`, `recipeTitle`, `createdAt`, `photo0`–`photo19` | 12-char recordName; CF routes legacy 6-char IDs |
| `UserProfile` | `displayName`, `accentHex`, `createdAt`, `lastCookedAt`, `lastCookedRecipeID`, `lastCookedTitle`, `cookingStartedAt` | recordName = `profile_<iCloudUserRecordName>` |
| `Friendship` | `userA`, `userB` (queryable, lexicographic pair), `requesterID`, `status`, `acceptedAt` | One record per pair; deny is destructive |
| `PublishedRecipe` | `ownerID`, `localRecipeID`, `recipeTitle`, `updatedAt`, `originalCreatorID`, `originalRecipeID`, `summary`, `tags` (String List), `photo0`–`photo19` | recordName = `Recipe.id.uuidString`; `summary`+`tags` not queryable |
| `RecipeImport` | `originalCreatorID`, `originalRecipeID`, `importerID`, `importerDisplayName`, `sourceUserID`, `importedAt` | Append-only audit log |

Photo cap: 10 MB per asset, 40 MB total. `photo0`–`photo19` must be added manually in CloudKit Console.
Push subscriptions: `friendship-events-A/B-<me>`, `recipe-import-events-<me>`. Silent pushes only. Fan-out: `AppDelegate` → `CloudKitSubscriptions.dispatchRemoteNotification` → `Notification.Name.cloudKitSubscriptionFired`.

---

## Signing & Security

**GitHub Secrets:** `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_P12_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`, `IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64`, `APPSTORE_API_KEY_P8_BASE64`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`

**Cloudflare Pages env:** `CLOUDKIT_CONTAINER_ID`, `CLOUDKIT_KEY_ID`, `CLOUDKIT_PRIVATE_KEY` (encrypted), `CLOUDKIT_ENVIRONMENT`, `ANTHROPIC_API_KEY` (encrypted)

**Entitlements** (`Resources/LlamasCookbook.entitlements`): App Group, SIWA, iCloud CloudKit, Associated Domains (`applinks:llamascookbook.pages.dev`), `aps-environment`. Regenerate provisioning profile after any capability change.

**Keychain** (`KeychainStore.swift`): `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable.

**`UIDesignRequiresCompatibility = true`** — Liquid Glass opt-out. Remove before iOS 27 forces it off.

**AASA** (`cloudflare-pages/.well-known/apple-app-site-association`): `GYFN949Q5E.com.llamascookbook.app` against `/r/*`.

---

## Llama Pro

Three tiers: `.none` (free) / `.monthly` (crown) / `.yearly` (crown + sunglasses). `isPro = plan != .none`.

Product IDs: `com.llamascookbook.app.pro.monthly`, `com.llamascookbook.app.pro.yearly`

**Crown assets by context:**

| Context | Monthly | Yearly |
|---|---|---|
| Generic | `Llama-Pro-Icon-Crown` | `Llama-Pro-Icon-Crown-Sunglasses` |
| Friends | `Llama-Pro-Icon-Friends-Crown` | `Llama-Pro-Icon-Friends-Crown-Sunglasses` |
| Profile | `Llama-Pro-Icon-Profile-Crown` | `Llama-Pro-Icon-Profile-Crown-Sunglasses` |

**Implementation rules:**
- Use `LlamaLogoOrCrown(size:accent:crownAsset:)` for `LlamaLogo` replacements (handles `plan` internally)
- Named-image call sites: `Image(proStore.plan == .yearly ? "X-Sunglasses" : proStore.isPro ? "X-Crown" : "X")`
- Tab bar Pro icons must use `proTabIcon(named:)` in `RootView` — crown assets are ~96–140pt; UIKit can't reliably downscale to ~26pt tab slot
- `PaywallView` dismisses on `.onChange(of: proStore.plan)`, not `isPro` — required for monthly→yearly upgrade path
- `PaywallView.task` calls `checkCurrentEntitlements()` before loading products
- Never show a plan card for the plan the user already holds; yearly users never open the paywall

---

## UX Rules

- **Back buttons**: `.navigationBarBackButtonHidden(true)` + `.enableSwipeBack()`. Editor intentionally omits `.enableSwipeBack()` (data-loss risk)
- **Photo strip** (`RecipeDetailView`): fixed 84pt row — 0 → Add only; 1 → photo + Add; 2 → 2 photos + Add; 3+ → 2 photos + "+N more" chip. No `ScrollView`
- **Favorited thumbnails**: `HeartShape()` clip for all `recipe.favorite == true` — no separate heart glyph next to title
- **Tab bar**: do not apply `.accentTextOutline()` — UIKit strips it from `.tabItem`
- **`.accentTextOutline()`** (`Theme/AccentTextOutline.swift`): 4× 0.4pt shadows at 0.22 opacity. Skip on filter chip labels (halo at 13pt), ingredient quantity/unit/bullet, `AppColor.onAccent` glyphs
- **Duplicate title import**: always show alert via `nextAvailableTitle(base:)` with `Title (N)` — never silently rename
- **Friends empty state threshold**: `isBelowSocialThreshold = friends.count < 3` (seed counts). CTA visible until 2 real friends added
- **Presence dot**: filled+pulsing when `cookingStartedAt` < 6h; hollow when idle
- **Social copy**: "shared", "appears in Friends", "unlisted" — never "private to friends"
- **`LibraryView` profile button**: `.disabled(editor.active != nil)` — explicit, not a silent no-op

---

## Testing

**JavaScript (Cloudflare)** — run from `cloudflare-pages/`: `npm test` (Vitest v3, Node ≥ 20)
- Tests: `test/quota.test.js` — 26 tests across quota constants, timezone helpers, cap arithmetic, `deriveAppAccountToken`
- Shared module: `lib/quota.js` — single source for `FREE_CAP`, `PRO_CAP`, `getLocalYYYYMM`, `nextMonthResetUTC`, `deriveAppAccountToken`; never re-inline these

**Swift (iOS)** — `LlamasCookbookNativeTests` target in `project.yml`; run via ⌘U in Xcode

Test files in `ios-native/Tests/LlamasCookbookTests/`:

| File | Covers |
|---|---|
| `LlamaProStoreTests.swift` | `Plan.isPro`, `displayLabel`, `appAccountToken` UUID bits |
| `QuotaSnapshotTests.swift` | `isPro`, `isMonthlyExhausted`, `resetDateFormatted` |
| `QuantityTests.swift` | parse/format/scale/combine, `ClockFormat.mmss`, `StringCase` |
| `SourdoughCalculatorTests.swift` | 10-row table, ratio invariants, sum==total |
| `FormattersTests.swift` | `shortMonthDay`, `date` (.medium) |
| `StringExtensionsTests.swift` | `Optional<String>.trimmedIfNonEmpty` |
| `SeedFriendTests.swift` | sentinel, `isSeed`, profile fields (no `loadPayload()`) |
| `RecipeImporterTests.swift` | `cleanTitle`, `mergeOrphanDurationSteps` |

Not tested by design: network calls, CloudKit ops, StoreKit purchase flow, SwiftUI views — integration concerns only.

---

## Open Work (Pre-App Store)

- **BLOCKER — credentials hygiene**: delete `credentials/github-secrets.txt` + `credentials/ios/*.p12` + `credentials/ios/*.mobileprovision` and **rotate the ASC API key** in App Store Connect (it sat on a dev machine in cleartext base64; treat as exposed)
- Verify Universal Links on real devices
- Adopt Liquid Glass before iOS 27 removes `UIDesignRequiresCompatibility` opt-out
- Server-side `Friendship(userA,userB)` uniqueness — currently client-side dedup only
- Account-deletion cascade: `CloudPendingDeleteQueue` covers 5 record types; CKQuerySubscriptions is single-shot best-effort

Recently resolved (2026-05-24 audit):
- Privacy manifest populated (`UserID`, `PhotosOrVideos`, `OtherUserContent` with linked/tracking/purposes)
- Anthropic key migration to CF Worker complete — no key in Swift binary or Keychain
- `CookModeView` `.fullScreenCover` (TimerReadyOverlay) and `.sheet` (RunningTimerSheet) now re-inject `AppearanceSettings` (iOS 26 environment-drop fix)
- `ImportersListSheet` now uses canonical `UserProfileSnapshot.resolvedAccent` with `AppColor.accent` fallback (was falling back to user's accent)
- `ImportFromPhotoView` PhotosPicker decode moved to `Task.detached(.userInitiated)` — HEIC decode no longer blocks main actor during multi-photo selection
- `PhotoCarouselView.commit` routes through `Optional(draft).trimmedIfNonEmpty`
- `SeedFriend.loadPayload()` no longer calls `fatalError` — logs via `os.Logger` and returns an empty payload if `SeedRecipes.json` is missing/malformed, so the app stays usable
