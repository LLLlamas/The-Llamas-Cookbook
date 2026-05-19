# CLAUDE.md

Source of truth for agents. Code wins when this disagrees.
Last refreshed: 2026-05-17

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

- **Privacy manifest**: `NSPrivacyCollectedDataTypes` empty — needs entry for Anthropic AI processing + user-facing disclosure in import UI
- **App Store privacy labels**: audit CloudKit sharing + Anthropic AI processing
- Verify Universal Links on real devices
- Adopt Liquid Glass before iOS 27 removes `UIDesignRequiresCompatibility` opt-out
- Server-side `Friendship(userA,userB)` uniqueness — currently client-side dedup only
- Account-deletion cascade: `CloudPendingDeleteQueue` covers 5 record types; CKQuerySubscriptions is single-shot best-effort
- Pre-launch: delete `credentials/github-secrets.txt`, `credentials/ios/dist-cert.p12`, `credentials/ios/profile.mobileprovision`
