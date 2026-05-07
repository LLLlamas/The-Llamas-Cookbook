# CLAUDE.md

Source of truth for agents. Code wins when this disagrees.

Last refreshed: 2026-05-07.

## Status

Live SwiftUI app under `ios-native/`. Version `1.0.0` (project.yml `MARKETING_VERSION`). CI overrides `CURRENT_PROJECT_VERSION` per archive. First public TestFlight target.

## Open work

- Verify Universal Links on real devices.
- Aesthetic/type pass; adopt Liquid Glass before iOS 27 drops the `UIDesignRequiresCompatibility` opt-out.
- Server-side uniqueness for `Friendship(userA,userB)` — currently client-side dedup only.
- Account-deletion cascade: CKQuerySubscriptions still single-shot best-effort (orphaned subscriptions are cheap server-side state, CloudKit GCs them). All five record-type cascades route through `CloudPendingDeleteQueue`; `cloudShareOutbox` still tracks RecipeShare records at upload time and feeds the queue on `deleteAuthoredShares`.
- Pre-launch: delete `credentials/github-secrets.txt`, `credentials/ios/dist-cert.p12`, `credentials/ios/profile.mobileprovision` from dev box (currently gitignored, not committed, but still present on disk).
- App Store privacy labels need a once-over against CloudKit/Cloudflare sharing.

## Stack

- Swift 5.10, SwiftUI, SwiftData, iOS 26+ deploy target, iOS 26 SDK.
- `SWIFT_STRICT_CONCURRENCY: minimal` across all targets.
- XcodeGen: `ios-native/project.yml`. Do not hand-edit generated Xcode files.
- CI: `macos-26` runner, Xcode 26. Windows dev machine — do NOT run `xcodegen`/`xcodebuild`/CocoaPods here.
- Bundle IDs: `com.llamascookbook.app` (main), `.widget`, `.shareext`.
- App Group: `group.com.llamascookbook.app`.
- CloudKit container: `iCloud.com.llamascookbook.app`.
- Universal Link host: `llamascookbook.pages.dev`.
- Team: `GYFN949Q5E`. ASC app id: `6762527184`.

## Feature → Files map

**App shell / entry point**
- `ios-native/Sources/App/LlamasCookbookApp.swift` — `@main`, `ModelContainer`, `AppDelegate` (APNs + remote-push dispatch)
- `ios-native/Sources/App/RootView.swift` — tab bar, all deep-link routing, editor/cook/share sheet orchestration

**Data models**
- `ios-native/Sources/Models/Recipe.swift` — `Recipe`, `Ingredient`, `RecipeStep`, `RecipePhoto`, `RecipeStepPhoto`; chain-attribution fields on `Recipe`
- `ios-native/Sources/Models/DraftRecipe.swift` — editor draft type; photo bytes carried via `DraftPhoto`/`DraftStep`

**Theme**
- `ios-native/Sources/Theme/` — `AppColor`, `AppFont`, `AppSpacing`, `ColorHex`

**Library / import**
- `ios-native/Sources/Views/Library/LibraryView.swift`, `RecipeCardView.swift`, `EmptyLibraryView.swift`, `ImportHelpView.swift`
- `ios-native/Sources/Views/Library/ImportFromTextLinkView.swift` — merged paste-text + URL-fetch sheet (replaces former `ImportFromTextView.swift` / `ImportFromLinkView.swift`)
- `ios-native/Sources/Views/Library/ImportFromPhotoView.swift`, `RecipeImportPreviewView.swift`, `PhotoImportPreviewView.swift`
- `ios-native/Sources/Views/Components/LetterIndex.swift`, `CookbookHeader.swift`, `RecipeImageView.swift`
- `ios-native/Sources/Lib/RecipeImporter.swift`, `RecipeURLImporter.swift`, `RecipeOCRImporter.swift`, `RecipeAIParser.swift`, `RecipeSchemaParser.swift`, `RecipeExport.swift`

**Editor**
- `ios-native/Sources/Views/Editor/RecipeEditorView.swift`
- `ios-native/Sources/Views/Editor/IngredientRowEditor.swift`, `IngredientQuickAdd.swift`, `StepRowEditor.swift`, `StepQuickAdd.swift`, `SpecialNotesEditor.swift`, `TagInputView.swift`, `PhotoToggleButton.swift`
- `ios-native/Sources/Views/Editor/Chips/QuantityChips.swift`, `UnitChips.swift`
- `ios-native/Sources/App/EditorCoordinator.swift`
- `ios-native/Sources/Lib/TagPresets.swift`, `IngredientDisplay.swift`, `Plural.swift`

**Detail / share**
- `ios-native/Sources/Views/Detail/RecipeDetailView.swift`
- `ios-native/Sources/Views/Detail/ImportersListSheet.swift`, `AttributionSheet.swift`, `ConversionsView.swift`, `SourdoughCalculatorView.swift`
- `ios-native/Sources/Lib/RecipeShare.swift` — wire format (`LCRecipeShareV1`), encode/decode, file/URL/cloud paths
- `ios-native/Sources/Lib/CloudKitService.swift` — CloudKit upload/fetch/delete, outbox, `queryAllRecords`, share-link constants
- `ios-native/Sources/Lib/ImportCountCache.swift` — UserDefaults-backed import count cache (not on `@Model`)

**Cook mode / timers**
- `ios-native/Sources/Views/Cook/CookModeView.swift`
- `ios-native/Sources/App/CookingSession.swift`, `CookingSessionState.swift`
- `ios-native/Sources/Lib/TimerNotifications.swift` — AlarmKit wrapper (`AlarmManager.shared`); always uses `AlertConfiguration.AlertSound.default` (system alarm tone) — sound is no longer user-configurable
- `ios-native/Sources/Lib/ResumeCookModeIntent.swift` — `LiveActivityIntent` wired through AlarmKit's `secondaryIntent`; tapping the alarm's "Open" button posts a NotificationCenter event that `RootView` translates into the existing `routeCookDeepLink` path
- `ios-native/Sources/Shared/TimerAlarmMetadata.swift` — shared between app + widget
- `ios-native/WidgetExtension/TimerLiveActivity.swift` — AlarmKit Live Activity widget
- `ios-native/WidgetExtension/TimerWidgetBundle.swift` — `@main` widget bundle (single member, future-extensible)

**Friends / social**
- `ios-native/Sources/App/FriendsStore.swift` — `@MainActor` cache of friends + requests
- `ios-native/Sources/App/UserAccount.swift` — SIWA identity, sign-out, delete-account cascade
- `ios-native/Sources/Lib/CloudKitFriendship.swift` — `FriendshipRecord`, friendship CRUD on public DB
- `ios-native/Sources/Lib/CloudKitUserProfile.swift` — `UserProfileSnapshot`, profile upsert/fetch/search
- `ios-native/Sources/Lib/CloudKitPublishedRecipe.swift` — `PublishedRecipeSummary`, `PublishedRecipeDetail`, library mirror ops
- `ios-native/Sources/Lib/CloudKitRecipeImport.swift` — `RecipeImportRecord`, import audit log ops
- `ios-native/Sources/Lib/CloudKitSubscriptions.swift` — CKQuerySubscription registration + `dispatchRemoteNotification`
- `ios-native/Sources/Lib/CloudPendingDeleteQueue.swift` — generic UserDefaults-backed retry queue for ALL cascade record deletes (`RecipeShare`, `Friendship`, `PublishedRecipe`, `RecipeImport`, `UserProfile`); drains on launch from `RootView.task`. Absorbs the legacy `cloudSharePendingDelete` key on first run after upgrade.
- `ios-native/Sources/Lib/UserProfileMirror.swift` — iCloud user record name cache; canonical "is iCloud bound?" check
- `ios-native/Sources/Lib/LibraryMirrorService.swift` — `@MainActor` singleton, 5s per-recipe debounce for `PublishedRecipe` upserts
- `ios-native/Sources/Views/Friends/FriendsTabView.swift` — friends tab card grid
- `ios-native/Sources/Views/Friends/FriendLibraryView.swift`, `FriendRecipeDetailView.swift`
- `ios-native/Sources/Views/Profile/ProfileView.swift`, `AddFriendSheet.swift`

**Auth / identity**
- `ios-native/Sources/Lib/SignInWithAppleService.swift`
- `ios-native/Sources/Lib/KeychainStore.swift` — Apple `sub` + display name, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- `ios-native/Sources/App/OwnerProfile.swift` — pre-SIWA fallback for sender display name (UserDefaults); envelope-build code prefers `UserAccount.status.identity?.displayName` and falls back here for signed-out sessions
- `ios-native/Sources/App/AppearanceSettings.swift` — accent color (UserDefaults + UIKit tint sync)

**Share extension**
- `ios-native/ShareExtension/ShareViewController.swift` — transparent passthrough; URL → `llamascookbook://share-url/`, file → App Group inbox
- `ios-native/Sources/Shared/SharedContainer.swift`, `Base64URL.swift`

**Web preview (Cloudflare Pages)**
- `cloudflare-pages/functions/r/[id].js` — OG-tagged HTML preview page
- `cloudflare-pages/functions/img/[id].js` — image proxy (content-length cap + magic-byte sniff)
- `cloudflare-pages/lib/cloudkit.js` — CloudKit Web Services client (ECDSA P-256 auth)
- `cloudflare-pages/.well-known/apple-app-site-association` — AASA for Universal Links

**Components / misc**
- `ios-native/Sources/Views/Components/` — `PhotoCarouselView`, `PhotoReorderView`, `CameraCaptureView`, `ShareSheet`, `LlamaLogo`, `LlamaWatermark`, `LlamaProgressIndicator`, `LlamaIntro/` (onboarding tours)
- `ios-native/Sources/Views/Components/AccentColorPicker.swift` — system `ColorPicker` sheet; commits accent on `.onDisappear` only
- `ios-native/Sources/Views/Components/SavedToast.swift` — friend-import success badge + `ImportFlyGhost` fly animation, driven by `NavigationContext.FriendImportToast`
- `ios-native/Sources/Lib/ImageProcessing.swift`, `Conversions.swift`, `Quantity.swift`, `SourdoughCalculator.swift`, `Haptics.swift`, `KeyboardDismiss.swift`, `Shake.swift`
- `ios-native/Sources/Lib/AppMetadata.swift` — shared `currentAppVersion` (CFBundleShortVersionString) + `describeServerError` helpers; route any new `appVersion`-stamping or CKError-message-extraction site through these
- `ios-native/Sources/App/NavigationContext.swift` — cross-view navigation signals + friend-import toast payload

## Hard invariants

- **SwiftData: `cloudKitDatabase: .none`** — do not switch to `.automatic`. The schema uses `.cascade` delete rules and non-optional properties; auto-opt-in silently degrades to in-memory storage.
- **`Recipe.apply(_:)` must NOT touch** `sharedBy`/`sharedAt`/`sourceShareID` or `originalCreator*`/`originalSharer*`/`originalRecipeID`/`importedAt`. Edits preserve the chain.
- **`RecipeStep.image` and `Recipe.imageUri` are deprecated** migration baggage — kept so lightweight migration doesn't drop the attributes on existing installs. New step photos use `RecipeStepPhoto`; new gallery photos use `RecipePhoto`. Don't repurpose either name.
- **`UserProfile` recordName uses `profile_` prefix** — prevents collision with CloudKit's system `Users` record type. Prefix applied/stripped in `CloudKitUserProfile.swift`; callers pass raw iCloud user record names.
- **`PublishedRecipe.recordName == Recipe.id.uuidString`** — upsert fetches by recordName without a query.
- **`queryAllRecords` follows cursors** — never reintroduce first-page-only social queries.
- **Predicates split per field, not OR** — CloudKit public-DB OR requires every field to be queryable; a missing index throws `invalidArguments` and silently skips the cascade. See `deleteAllRecipeImports` (two legs) and `registerFriendshipSubscription` (two legs).
- **Re-inject `@Observable` environments** into every sheet/fullScreenCover — `@Observable` values can drop across presentation boundaries on iOS 26.
- **`FriendsStore.refresh()` sets `isRefreshing` synchronously** before any `await` to prevent re-entrancy across `.task` + `.onChange` racers.
- **`UserProfileMirror.cachedRecordID()`** is the canonical "is iCloud bound?" check — every social write short-circuits when nil.
- **`LibraryMirrorService`** is a `@MainActor` singleton with a 5s per-`Recipe.id` debounce. Sign-out/delete-account paths must call `resetBulkPublishMarker()`.
- **`ImportCountCache`** lives in UserDefaults, not on `Recipe` — chip refreshes must not trigger SwiftData change notifications that cause spurious `LibraryMirrorService` re-publishes.
- **AlarmKit** owns the cook-timer lock-screen alert and Live Activity countdown. `TimerNotifications.schedule/cancel` wraps `AlarmManager.shared`. Widget renders `AlarmAttributes<TimerAlarmMetadata>` directly.
- **App Group identifier** `group.com.llamascookbook.app` must match: `SharedContainer.appGroupID`, main app entitlements, share extension entitlements, and portal profiles — four places, one string.
- **HEIC photos transcode to JPEG before upload to `RecipeShare`** (`ImageProcessing.transcodeHEICToJPEGForSharing`, called from `CloudKitService.uploadShare`). Local SwiftData stays HEIC; only the share-bound copy is JPEG so non-Apple link unfurlers (WhatsApp, Slack, Discord, Chrome) can preview the photo.
- **`RecipeShareLimits.maxInboundBytes`** in `Sources/Shared/` is the single source of truth for the 25 MB inbound cap. Both `RecipeShare.maxInboundBytes` (main app) and `ShareViewController.maxInboundBytes` (share extension) reference it — do not reintroduce duplicated literals.
- **Cloud-share failures show "try again later"** — `RecipeDetailView.shareViaPreferredTransport` aborts with an alert when iCloud is unavailable or upload fails. No long-URL fallback. The "Share recipe" menu only ever produces an HTTPS Universal Link permalink.
- **`AccentColorPicker` commits on `.onDisappear`, never mid-pick** — driving `pickerColor` straight into `AppearanceSettings.accentColor` re-renders the parent, rebuilds the `ColorPicker` subtree, and desyncs `UIColorPickerViewController` so only the first pick registers. `@Environment(AppearanceSettings.self)` must also be re-injected at every call site or the live preview stops updating once the system picker covers the sheet.
- **CI Xcode toolchain pinning needs PATH override + beta rename, not just `DEVELOPER_DIR`** — `macos-26` ships `Xcode_*beta*.app` next to the stable point releases, and the runner's shell profile pre-pends the default Xcode's `usr/bin` to PATH. Setting `xcode-select`/`DEVELOPER_DIR` alone leaves xcodebuild's sub-tools (actool, clang, ld, xcrun's iphoneos SDK lookup) resolving to the beta — `xcodebuild -version` still reports stable, but the archived binary is built by beta tooling. Internal TestFlight accepts it; external TestFlight rejects it with "This build is using a beta version of Xcode." The `Select Xcode 26` step in `ios-native-ci.yml` physically renames every `Xcode_*beta*.app` to `_disabled_…` and re-pins both `DEVELOPER_DIR` and `PATH`. If a future macOS runner image labels a release-candidate seed without "beta" in the filename (e.g. `Xcode_26.5.0.app` with build number `17F5022i`), this step will need to skip that version range too.

## CloudKit schema

All record types on the **public DB**. Privacy: world-readable, world-writable (no Security Role yet — add one before expanding TestFlight).

| Record type | Key fields | Notes |
|---|---|---|
| `RecipeShare` | `envelope` (Asset), `senderDisplayName`, `recipeTitle`, `createdAt` (queryable+sortable), `photo0`–`photo19` (Asset, optional); system `___createdBy` queryable for deleteAccount cascade | 12-char random recordName; Cloudflare still routes legacy 6-char IDs |
| `UserProfile` | `displayName`, `accentHex`, `createdAt`, `lastCookedAt`, `lastCookedRecipeID`, `lastCookedTitle`, `cookingStartedAt` | recordName = `profile_<iCloudUserRecordName>` |
| `Friendship` | `userA`, `userB` (queryable, lexicographic pair), `requesterID`, `status` (queryable), `acceptedAt` | One record per pair; deny is destructive |
| `PublishedRecipe` | `ownerID`, `localRecipeID`, `recipeTitle`, `updatedAt`, `originalCreatorID`, `originalRecipeID`, `summary`, `tags` (String List), `photo0`–`photo19` | recordName = `Recipe.id.uuidString`; `summary`+`tags` denormalized for friend-library card rendering, neither queryable |
| `RecipeImport` | `originalCreatorID`, `originalRecipeID`, `importerID`, `importerDisplayName`, `sourceUserID`, `importedAt` | Append-only audit log |

Photo cap: 10 MB per photo (`maxCloudPhotoBytes`), 40 MB total (`maxCloudTotalPhotoBytes`). `photo0`–`photo19` fields must be added manually in CloudKit Console (auto-discovery misses optional `CKAsset` slots).

Push subscriptions: `friendship-events-A-<me>`, `friendship-events-B-<me>`, `recipe-import-events-<me>`. Silent pushes only (`shouldSendContentAvailable = true`). Fan-out: `AppDelegate` → `CloudKitSubscriptions.dispatchRemoteNotification` → `Notification.Name.cloudKitSubscriptionFired` on `NotificationCenter.default` with `userInfo["kind"]`.

## Signing / portal

**GitHub Secrets (CI):** `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_P12_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`, `IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64`, `APPSTORE_API_KEY_P8_BASE64`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`.

**Cloudflare Pages env:** `CLOUDKIT_CONTAINER_ID`, `CLOUDKIT_KEY_ID`, `CLOUDKIT_PRIVATE_KEY` (encrypted), `CLOUDKIT_ENVIRONMENT`.

**Main app entitlements** (`Resources/LlamasCookbook.entitlements`): App Group, Sign in with Apple, iCloud CloudKit (`iCloud.com.llamascookbook.app`), Associated Domains (`applinks:llamascookbook.pages.dev`), `aps-environment`. All entitlements are baked into the provisioning profile at issue time — regenerate the profile after any capability change.

**`UIDesignRequiresCompatibility = true`** — intentional Liquid Glass opt-out. Remove before iOS 27 forces it off.

**AASA** (`cloudflare-pages/.well-known/apple-app-site-association`): declares `GYFN949Q5E.com.llamascookbook.app` against `/r/*`.

**Image proxy** (`functions/img/[id].js`): `MAX_PROXY_IMAGE_BYTES = 10_000_000`, content-length precheck, magic-byte sniff (JPEG/PNG/WebP/HEIC).

**Keychain** (`KeychainStore.swift`): `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable — deliberate; Apple `sub` is per-device-team.

## UX guardrails

- Quick-add rows + Return-to-add; gesture fallbacks always visible.
- Cook Mode: large type, warm cream background, check-off flow, ready overlay.
- Quantity: strings, mixed fractions, `&` output, measurable chip set only.
- Detail ingredient: accent quantity + em dash.
- Per-step timers: clock glyph + `needsTimer` flag.
- Carousels: no inline reorder arrows — use dedicated reorder mode (`PhotoReorderView`).
- New-recipe llama tour is interactive — dim/halo are `.allowsHitTesting(false)` so the user types into the real editor fields as the walkthrough runs; finishing the tour and tapping Save in the toolbar persists a real `Recipe`. No Skip button, but an Exit pill sits below the Back/Next arrow row to bail out at any step (typed work stays in the editor). Six consolidated steps (Name+Description, Servings+PrepTime, Photos, Tag It, Ingredients, Steps+Notes). See `llama-intro.md`.
- Duplicate title import: prompt + prefill `Title (N)`, including friend cookbook imports.
- Social copy: "shared", "appears in Friends", "unlisted". Never "private to friends" or "only friends can see."
- Friend surfaces (`FriendLibraryView`, `FriendRecipeDetailView`, `FriendsTabView`): tint in friend's accent. Presence dot: filled+pulsing when `cookingStartedAt` < 6h ago, hollow when idle. `lastCookedTitle` shows as "Cooking: <title>" eyebrow during a cook.
- `LibraryView` profile button: `.disabled(editor.active != nil)` — not a silent no-op while editor is up.
