# CLAUDE.md

Source of truth for agents. Code wins when this disagrees.

Last refreshed: 2026-05-11.

## Status

Live SwiftUI app under `ios-native/`. Version `1.0.0`. CI overrides `CURRENT_PROJECT_VERSION` per archive. First public TestFlight target.

## Open work

- Verify Universal Links on real devices.
- Adopt Liquid Glass before iOS 27 drops the `UIDesignRequiresCompatibility` opt-out.
- Server-side uniqueness for `Friendship(userA,userB)` — currently client-side dedup only.
- Account-deletion cascade: CKQuerySubscriptions single-shot best-effort; all five record-type cascades route through `CloudPendingDeleteQueue`.
- Pre-launch: delete `credentials/github-secrets.txt`, `credentials/ios/dist-cert.p12`, `credentials/ios/profile.mobileprovision` from dev box (gitignored, not committed, but present on disk).
- App Store privacy labels need a once-over against CloudKit/Cloudflare sharing.

## Stack

- Swift 5.10, SwiftUI, SwiftData, iOS 26+ deploy target, iOS 26 SDK.
- `SWIFT_STRICT_CONCURRENCY: minimal`.
- XcodeGen: `ios-native/project.yml`. Do not hand-edit generated Xcode files.
- CI: `macos-26` runner, Xcode 26. **Windows dev — do NOT run `xcodegen`/`xcodebuild`/CocoaPods here.**
- Bundle IDs: `com.llamascookbook.app` (main), `.widget`, `.shareext`.
- App Group: `group.com.llamascookbook.app`.
- CloudKit container: `iCloud.com.llamascookbook.app`.
- Universal Link host: `llamascookbook.pages.dev`.
- Team: `GYFN949Q5E`. ASC app id: `6762527184`.

## Directory map

Start here before searching. Each row is the primary directory for that feature area.

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
| CloudKit ops (all `CloudKit*.swift`) | `ios-native/Sources/Lib/` |
| Shared utilities + modifiers | `ios-native/Sources/Lib/` |
| Widget + Live Activity | `ios-native/WidgetExtension/` |
| Share extension | `ios-native/ShareExtension/` |
| Web preview (Cloudflare Pages) | `cloudflare-pages/` |

## Feature → Files map

**App shell** (`Sources/App/`)
- `LlamasCookbookApp.swift` — `@main`, `ModelContainer`, `AppDelegate` (APNs + remote-push dispatch)
- `RootView.swift` — tab bar, all deep-link routing, editor/cook/share sheet orchestration
- `EditorCoordinator.swift`, `NavigationContext.swift`, `CookingSession.swift`, `CookingSessionState.swift`
- `FriendsStore.swift` — `@MainActor` cache of friends + requests
- `UserAccount.swift` — SIWA identity, sign-out, delete-account cascade
- `OwnerProfile.swift` — pre-SIWA display-name fallback; `AppearanceSettings.swift` — accent color

**Data models** (`Sources/Models/`)
- `Recipe.swift` — `Recipe`, `Ingredient`, `RecipeStep`, `RecipePhoto`, `RecipeStepPhoto`; chain-attribution fields
- `DraftRecipe.swift` — editor draft type; photos via `DraftPhoto`/`DraftStep`

**Theme** (`Sources/Theme/`)
- `AppColor`, `AppFont`, `AppSpacing`, `ColorHex`, `AccentTextOutline`

**Library / import** (`Sources/Views/Library/`)
- `LibraryView.swift`, `RecipeCardView.swift`, `EmptyLibraryView.swift`, `ImportHelpView.swift`
- `ImportFromTextLinkView.swift` — merged paste-text + URL-fetch sheet
- `ImportFromPhotoView.swift`, `RecipeImportPreviewView.swift`, `PhotoImportPreviewView.swift`
- Components: `LetterIndex.swift`, `CookbookHeader.swift`, `RecipeImageView.swift`
- Lib: `RecipeImporter.swift`, `RecipeURLImporter.swift`, `RecipeOCRImporter.swift`, `RecipeAIParser.swift`, `RecipeSchemaParser.swift`, `RecipeExport.swift`

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
- `FriendsTabView.swift`, `FriendLibraryView.swift`, `FriendRecipeDetailView.swift`
- Lib: `CloudKitFriendship.swift`, `CloudKitUserProfile.swift`, `CloudKitPublishedRecipe.swift`, `CloudKitRecipeImport.swift`, `CloudKitSubscriptions.swift`, `CloudPendingDeleteQueue.swift`, `UserProfileMirror.swift`, `LibraryMirrorService.swift`

**Auth / identity** (`Sources/Lib/`)
- `SignInWithAppleService.swift`, `KeychainStore.swift` — Apple `sub` + display name

**Share extension** (`ShareExtension/`)
- `ShareViewController.swift` — URL → `llamascookbook://share-url/`, file → App Group inbox
- `Sources/Shared/SharedContainer.swift`, `Base64URL.swift`

**Web preview** (`cloudflare-pages/`)
- `functions/r/[id].js` — OG-tagged HTML preview; `functions/img/[id].js` — image proxy
- `lib/cloudkit.js` — CloudKit Web Services client (ECDSA P-256)
- `.well-known/apple-app-site-association` — AASA for Universal Links

**Components / misc** (`Sources/Views/Components/`)
- `PhotoCarouselView`, `PhotoReorderView`, `CameraCaptureView`, `ShareSheet`, `LlamaLogo`, `LlamaWatermark`, `LlamaProgressIndicator`, `LlamaIntro/`
- `AccentColorPicker.swift`, `SavedToast.swift`
- Lib: `ImageProcessing.swift`, `Conversions.swift`, `Quantity.swift`, `SourdoughCalculator.swift`, `Haptics.swift`, `SwipeBack.swift`, `AppMetadata.swift`

## Hard invariants

- **SwiftData: `cloudKitDatabase: .none`** — `.cascade` delete rules + non-optional props break auto-opt-in (silently degrades to in-memory).
- **`Recipe.apply(_:)` must NOT touch** `sharedBy`/`sharedAt`/`sourceShareID` or `originalCreator*`/`originalSharer*`/`originalRecipeID`/`importedAt`. Edits preserve the attribution chain.
- **`RecipeStep.image` and `Recipe.imageUri` are deprecated** migration baggage — do not repurpose; kept so lightweight migration doesn't drop attributes on existing installs.
- **`UserProfile` recordName uses `profile_` prefix** — applied/stripped in `CloudKitUserProfile.swift`; callers pass raw iCloud user record names.
- **`PublishedRecipe.recordName == Recipe.id.uuidString`** — upsert fetches by recordName without a query.
- **`queryAllRecords` follows cursors** — never reintroduce first-page-only social queries.
- **Predicates split per field, not OR** — CloudKit public-DB OR on non-queryable fields throws `invalidArguments` and silently skips cascades.
- **Re-inject `@Observable` environments** into every sheet/fullScreenCover — values drop across presentation boundaries on iOS 26.
- **`FriendsStore.refresh()` sets `isRefreshing` synchronously** before any `await` — prevents re-entrancy across `.task` + `.onChange` racers.
- **`UserProfileMirror.cachedRecordID()`** is the canonical "is iCloud bound?" check — every social write short-circuits when nil.
- **`LibraryMirrorService`** — `@MainActor` singleton, 5s per-`Recipe.id` debounce. Sign-out/delete must call `resetBulkPublishMarker()`.
- **`ImportCountCache`** in UserDefaults, not `@Model` — prevents chip refreshes from triggering spurious `LibraryMirrorService` re-publishes.
- **AlarmKit** owns cook-timer lock-screen alerts + Live Activity. `TimerNotifications.schedule/cancel` wraps `AlarmManager.shared`. Sound is always `AlertConfiguration.AlertSound.default` (not user-configurable).
- **App Group** `group.com.llamascookbook.app` — must match in 4 places: `SharedContainer.appGroupID`, main app entitlements, share extension entitlements, portal profiles.
- **HEIC → JPEG before CloudKit upload** (`ImageProcessing.transcodeHEICToJPEGForSharing`). Local SwiftData stays HEIC.
- **`RecipeShareLimits.maxInboundBytes`** in `Sources/Shared/` — single source for the 25 MB cap; both main app and share extension reference it.
- **Cloud-share failures show "try again later"** — no long-URL fallback. "Share recipe" always produces an HTTPS Universal Link.
- **`AccentColorPicker` commits on `.onDisappear`**, never mid-pick — driving it earlier desyncs `UIColorPickerViewController` (only the first pick registers).
- **Custom back buttons** (`RecipeDetailView`, `FriendLibraryView`, `FriendRecipeDetailView`) use `.navigationBarBackButtonHidden(true)` + `.enableSwipeBack()` (`Lib/SwipeBack.swift`) for letterpress styling + working swipe-back. `RecipeEditorView` omits `.enableSwipeBack()` intentionally — Cancel/Save pattern, data-loss risk.
- **CI Xcode toolchain**: `macos-26` ships beta `.app`s with dangling marketing-version symlinks. `Select Xcode 26` step (1) renames `Xcode_*beta*.app` → `_disabled_…`, (2) filters for real `Contents/Developer`, (3) re-pins both `DEVELOPER_DIR` and `PATH`. Setting only `DEVELOPER_DIR` leaves sub-tools (actool, clang, ld) on the beta; external TestFlight rejects beta-built archives.

## CloudKit schema

All record types on the **public DB**. Privacy: world-readable, world-writable (no Security Role yet).

| Record type | Key fields | Notes |
|---|---|---|
| `RecipeShare` | `envelope` (Asset), `senderDisplayName`, `recipeTitle`, `createdAt` (queryable+sortable), `photo0`–`photo19` (Asset, optional) | 12-char random recordName; Cloudflare routes legacy 6-char IDs |
| `UserProfile` | `displayName`, `accentHex`, `createdAt`, `lastCookedAt`, `lastCookedRecipeID`, `lastCookedTitle`, `cookingStartedAt` | recordName = `profile_<iCloudUserRecordName>` |
| `Friendship` | `userA`, `userB` (queryable, lexicographic pair), `requesterID`, `status` (queryable), `acceptedAt` | One record per pair; deny is destructive |
| `PublishedRecipe` | `ownerID`, `localRecipeID`, `recipeTitle`, `updatedAt`, `originalCreatorID`, `originalRecipeID`, `summary`, `tags` (String List), `photo0`–`photo19` | recordName = `Recipe.id.uuidString`; `summary`+`tags` not queryable |
| `RecipeImport` | `originalCreatorID`, `originalRecipeID`, `importerID`, `importerDisplayName`, `sourceUserID`, `importedAt` | Append-only audit log |

Photo cap: 10 MB per photo (`maxCloudPhotoBytes`), 40 MB total. `photo0`–`photo19` must be added manually in CloudKit Console.

Push subscriptions: `friendship-events-A-<me>`, `friendship-events-B-<me>`, `recipe-import-events-<me>`. Silent pushes only. Fan-out: `AppDelegate` → `CloudKitSubscriptions.dispatchRemoteNotification` → `Notification.Name.cloudKitSubscriptionFired` with `userInfo["kind"]`.

## Signing / portal

**GitHub Secrets:** `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_P12_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`, `IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64`, `APPSTORE_API_KEY_P8_BASE64`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`.

**Cloudflare Pages env:** `CLOUDKIT_CONTAINER_ID`, `CLOUDKIT_KEY_ID`, `CLOUDKIT_PRIVATE_KEY` (encrypted), `CLOUDKIT_ENVIRONMENT`.

**Entitlements** (`Resources/LlamasCookbook.entitlements`): App Group, SIWA, iCloud CloudKit, Associated Domains (`applinks:llamascookbook.pages.dev`), `aps-environment`. Regenerate profile after any capability change.

**`UIDesignRequiresCompatibility = true`** — Liquid Glass opt-out. Remove before iOS 27 forces it off.

**AASA** (`cloudflare-pages/.well-known/apple-app-site-association`): `GYFN949Q5E.com.llamascookbook.app` against `/r/*`.

**Image proxy** (`img/[id].js`): 10 MB cap, magic-byte sniff (JPEG/PNG/WebP/HEIC).

**Keychain** (`KeychainStore.swift`): `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable — Apple `sub` is per-device-team.

## UX guardrails

- Quick-add rows + Return-to-add; gesture fallbacks always visible.
- Cook Mode: large type, warm cream background, check-off flow, ready overlay.
- Quantity: strings, mixed fractions, `&` output, measurable chip set only.
- Detail ingredient: accent quantity + em dash. Per-step timers: clock glyph + `needsTimer` flag.
- Carousels: no inline reorder arrows — use dedicated reorder mode (`PhotoReorderView`).
- **Favorited recipe card thumbnail** (`RecipeCardView`): `HeartShape()` clip + stroke for ALL favorited recipes — both photo thumbnails and the llama placeholder. `showsHeartThumbnail` is simply `recipe.favorite`; no separate heart glyph next to the title is shown when the thumbnail already signals it.
- Llama tour: interactive, dim/halo are `.allowsHitTesting(false)`. No Skip button; Exit pill below nav row. Six steps (Name+Desc, Servings+Prep, Photos, Tags, Ingredients, Steps+Notes). See `llama-intro.md`.
- Duplicate title import: prompt + prefill `Title (N)`, including friend cookbook imports.
- Social copy: "shared", "appears in Friends", "unlisted". Never "private to friends".
- Friend surfaces: tint in friend's accent. Presence dot: filled+pulsing when `cookingStartedAt` < 6h, hollow when idle. `lastCookedTitle` as "Cooking: <title>" eyebrow during a cook.
- `LibraryView` profile button: `.disabled(editor.active != nil)` — not a silent no-op.
- **Tab bar** (`RootView`): `.accentTextOutline()` not applied — system `TabView`/UIKit strips modifiers from `.tabItem`.
- **Letterpress outline**: `.accentTextOutline()` (`Theme/AccentTextOutline.swift`) — four 0.4pt shadows at 0.22 opacity. Apply to all prominent accent-tinted text/icons. **Skip on**: white-on-accent (`AppColor.onAccent`) glyphs, system alert buttons, carousel destructive glyphs, native `.tabItem`.
