# CLAUDE.md

Source of truth. Code > this doc (update when stale). Last refreshed 2026-04-30 (slice 6).

## Doc map

- **CLAUDE.md** — this file. Auto-loaded.
- **PROJECT.md** — stack rationale, signing, dev workflow.
- **llamas-cookbook-plan.md** — original spec; vision/UX authoritative.
- **ROADMAP.md** — deferred work + portal checklist.
- **implement-social.md** — friends-feature build spec (next big PR).
- **llama-intro.md**, **picture-import-implementation.md**, **Implementing-User-Sign-In.md**, **Recipe-Sharing.md**, **Share-Extension-Plan.md**, **Multi-Recipe-Cook-Mode.md**, **Photo-Capability.md**, **SDK-Update-Plan.md** — feature specs (mostly historical now that the work shipped).
- **STATE.md** — archived 2026-04-27.

Plan docs decay; grep code before quoting.

## Status

Shipped: core CRUD; multi-cook (1–4) with keep-awake; photos; Sign-in-with-Apple (PR 1); Universal-Link sharing via Cloudflare Pages; four-way FAB import (Write / Text / Link / Photo) with manual-shutter `CameraCaptureView` on the photo path; LlamaIntro coach-mark tours for new-recipe / text-import / link-import; user-customizable accent via `AccentColorPicker`; per-step prep time; **Friends feature end-to-end** (slices 1–6 of `implement-social.md`): identity mirror, name search + request flow, library mirror, friend-side browsing, friend recipe import with chain attribution, import audit + counter chip + attribution sheet + CKSubscription pushes.

Active queue: per-cook `TimerLiveActivityRegistry`; Universal-Link end-to-end verification → revert diagnostic alert; aesthetic / typography pass; Liquid Glass adoption. **Diagnostic alert in `RecipeDetailView.cloudShareError` is still temporary** — revert to silent fall-through once Universal Link confirmed working on real devices.

Slice 6 portal step pending: enable **Push Notifications** capability on the App ID + regenerate the main-app provisioning profile + update `IOS_PROVISIONING_PROFILE_BASE64` in GitHub Secrets, else CKQuerySubscription pushes silently fail to deliver. Schema deploy pending: `RecipeImport` Dev → Prod (queryable indexes on `originalRecipeID`, `importerID`, `originalCreatorID`).

## Capability map

| Capability | Where | Notes |
|---|---|---|
| Profile | `Views/Profile/ProfileView.swift` | Signed-in/out states + SIWA + Sign Out + Delete Account. Identity in `App/UserAccount.swift` (`UserIdentity` Codable, status enum); display name in `App/OwnerProfile.swift` (UserDefaults); Keychain via `Lib/KeychainStore.swift`. SIWA flow in `Lib/SignInWithAppleService.swift`. |
| Accent picker | `Views/Components/AccentColorPicker.swift` | Reached from Profile + Library. Hex-persisted via `App/AppearanceSettings.swift`. |
| Onboarding tours | `Views/Components/LlamaIntro/` | Coach-mark overlay (`LlamaIntroOverlay`) + character/bubble + `tourTarget(_)` modifier (`LlamaTourTarget` enum). Three tours: `NewRecipeTour`, `TextImportTour`, `LinkImportTour`. AppStorage flags: `hasSeenNewRecipeTour`, `hasSeenTextImportTour`, `hasSeenLinkImportTour`, `hasSeenImportHelp`. Host attaches `.overlayPreferenceValue(LlamaTourTargetKey.self)` at the outermost level (preference anchors don't propagate from toolbar items into a child overlay). |
| Library | `Views/Library/LibraryView.swift` | All / Favorites / tag chips. Long-press Delete. A–Z scrub. |
| FAB | `LibraryView` | 4 entries: Write / Import Text / Import Link / Import Photo. |
| Recipe Detail | `Views/Detail/RecipeDetailView.swift` | Sections, gallery, share menu, sourdough chip. **Slice 6:** "Imported by N" chip on own recipes (taps → `Views/Detail/ImportersListSheet.swift`); "Originally shared by [name]" eyebrow on imported recipes is tappable (taps → `Views/Detail/AttributionSheet.swift`). Stale-while-revalidate refresh on `.task(id: recipe.id)`; live re-fetch on `CloudKitSubscriptions.didFireNotification` of kind `.recipeImport`. |
| Export | `Lib/RecipeExport.swift` | Plain-text bridge. |
| Sharing privacy | `CloudKitService` + Cloudflare Pages | Social/friend cookbook and recipe-share records are **public/unlisted**, not friend-private. The app surfaces friend cookbooks through accepted-friend UI, but copy must not promise that only friends can possibly read shared records. New share links use 12-char non-ambiguous IDs; legacy 6-char links still route. |
| Recipe sharing | `Lib/CloudKitService.swift` + `Lib/RecipeShare.swift` + `Views/Components/ShareSheet.swift` | Cloud Universal Link first, local URL fallback. Public DB `RecipeShare`; photos as separate `CKAsset` `photo0`–`photo19`. New links use 12-char non-ambiguous IDs at `https://llamascookbook.pages.dev/r/<id>`; legacy 6-char links still route. Fallback `llamascookbook://recipe/v2/<base64url>` (lzma, no photos). Outbox `cloudShareOutbox.v1` for Delete-Account cascade. |
| Recipe import | `Views/Library/RecipeImportPreviewView.swift` + `RootView.onOpenURL` + `onContinueUserActivity` | Handles `.llamarecipe`, `recipe/v<N>/`, legacy `share/<id>`, HTTPS Universal Links. Save → `RecipeShare.materialize` (rewrites UUIDs). |
| Share Extension | `ShareExtension/ShareViewController.swift` + `Sources/Shared/SharedContainer.swift` | Passthrough only. URLs → `share-url/<base64url>`. Files → App Group → `share-incoming/<uuid>`. |
| Conversions | `Views/Detail/ConversionsView.swift` | Cards + live calculator. |
| Sourdough | `Views/Detail/SourdoughCalculatorView.swift` + `Lib/SourdoughCalculator.swift` | For `sourdough` / `bread` / `baking` tags. |
| Editor | `Views/Editor/RecipeEditorView.swift` | Quick-add, drag-reorder, tags, special notes, photos. |
| Import (text) | `Views/Library/ImportFromTextView.swift` + `Lib/RecipeImporter.swift` | Verification panel asks first-ingredient/first-step. Accepts `seedText` from photo fallback. |
| Import (URL) | `Views/Library/ImportFromLinkView.swift` + `Lib/RecipeURLImporter.swift` + `Lib/RecipeSchemaParser.swift` | JSON-LD → OG fallback, TikTok oEmbed, Pinterest HTML. IG/FB blocked. |
| Import (photo) | `Views/Library/ImportFromPhotoView.swift` + `PhotoImportPreviewView.swift` + `Lib/RecipeOCRImporter.swift` + `Views/Components/CameraCaptureView.swift` | Manual-shutter camera (`UIImagePickerController` wrapper) or `PhotosPicker` → Vision OCR + cleanup → `parseBestOf`. On-device only. Stricter quality gate; partial fallback hands off seed to text editor. **Replaced `VNDocumentCameraViewController`** — auto-capture fired too eagerly on handwritten cards. |
| AI parser | `Lib/RecipeAIParser.swift` | iOS 26+ `FoundationModels`. `parseBestOf` runs LLM + regex parallel. Silent fallback to regex when unavailable. |
| Cook Mode | `Views/Cook/CookModeView.swift` | Two-phase, scaler, check-off, floating timer, ready overlay. |
| Multi-cook pills | `CookModeView` family | 1–4. |
| Cook tuck-down | `RootView` cover detents | `[.large, .height(80)]`. |
| Timer + Live Activity | `Lib/TimerLiveActivityController.swift` + `WidgetExtension/TimerLiveActivity.swift` | Per-cook ID `cooking-timer-<cookID>`. |
| Cook persistence | `App/CookingSessionStore.swift` | UserDefaults `cooking-session-states.v2`; v1→v2 migration. |
| Editor coordinator | `App/EditorCoordinator.swift` | Sheet open/dirty gating + discard alert. |
| Friends feature | `App/FriendsStore.swift` + `Lib/CloudKitFriendship.swift` + `Lib/CloudKitUserProfile.swift` + `Lib/CloudKitPublishedRecipe.swift` + `Lib/UserProfileMirror.swift` + `Lib/LibraryMirrorService.swift` + `Views/Profile/AddFriendSheet.swift` + `Views/Friends/` | Slices 1–5 of `implement-social.md`. UserProfile mirror, name search, request/accept/deny, PublishedRecipe library mirror, FriendLibraryView + FriendRecipeDetailView with friend-accent tinting, `RecipeShare.materializeFromPublished` for chain-attributed deep-copy import. |
| Friends — slice 6 | `Lib/CloudKitRecipeImport.swift` + `Lib/CloudKitSubscriptions.swift` + `Views/Detail/ImportersListSheet.swift` + `Views/Detail/AttributionSheet.swift` | Append-only `RecipeImport` audit row written on each friend-import event (fire-and-forget from `FriendRecipeDetailView.performImport`). "Imported by N" chip on own RecipeDetail (cap render hidden at 0; capped display "99+"). Tap-attribution sheet on imported recipes (chain root + import date + optional "Passed through [Sharer]" hop). Two CKQuerySubscriptions on the public DB (`friendship-events-<me>`, `recipe-import-events-<me>`); silent pushes wake the app and post `CloudKitSubscriptions.didFireNotification` to NotificationCenter — `FriendsStore.observeRemotePushes()` and `RecipeDetailView.onReceive` consume their respective kind. |

## Tech stack

Swift 5.10, SwiftUI, iOS 18+. SwiftData `@Model` + UserDefaults + Keychain. `NavigationStack` + `.sheet` + `.fullScreenCover` (Cook Mode + Editor hoisted to `RootView`). `AuthenticationServices` (SIWA), `CloudKit` (public DB share envelopes), `UNUserNotificationCenter`, `ActivityKit`, `FoundationModels` (iOS 26+), `Vision` (on-device OCR), `UIImagePickerController` (manual camera), `AVAudioPlayer` for `timer-alarm.caf`. XcodeGen `ios-native/project.yml`. CI `macos-26` → `xcodebuild archive` → TestFlight via `xcrun altool`. **Build SDK iOS 26.x** (ITMS-90725). iPhone-only, portrait.

**Don't use:** UIKit beyond `appearance()` proxies + `ShareSheet` + `CameraCaptureView`; no Combine; no SPM/CocoaPods; no Core Data.

## Data model

`Sources/Models/Recipe.swift`:

```swift
@Model final class Recipe {
    var id, title, summary, sourceUrl, imageUri, servings, cookTimeMinutes,
        prepTimeMinutes, notes, favorite, tags, lastCookedAt, cookCount,
        createdAt, updatedAt
    var prefaceNote, epilogueNote, generalNote: String?
    @Relationship(.cascade) var ingredients: [Ingredient]
    @Relationship(.cascade) var steps: [RecipeStep]
    @Relationship(.cascade) var photos: [RecipePhoto]
}
@Model final class Ingredient { id, quantity: String?, unit, name, order, recipe }
@Model final class RecipeStep {
    id, order, text, needsTimer, specialNote: String?
    @Attribute(.externalStorage) var image: Data? = nil   // DEPRECATED
    @Relationship(.cascade) var photos: [RecipeStepPhoto] // ≤3 per step
}
@Model final class RecipePhoto     { id, image: Data?, caption: String?, order, recipe }
@Model final class RecipeStepPhoto { id, image: Data?, caption: String?, order, step }
```

`RecipeStep.image` deprecated — kept for migration; never write. `DraftRecipe`/`DraftIngredient`/`DraftStep`/`DraftPhoto` (`Models/DraftRecipe.swift`) are plain structs.

## Repo + dev loop

iOS in `ios-native/`. Repo root = docs + `outdated/rn-expo/` (archived; **do not modify**) + `cloudflare-pages/` (Universal-Link site, auto-builds on push to main).

**CI-only.** Windows dev box. Every build runs via `.github/workflows/ios-native-ci.yml`, `workflow_dispatch`, ~15–25 min. No Previews. Don't run `xcodegen`/`xcodebuild`/`pod` here. One CI cycle per syntactic mistake.

**XcodeGen, not pbxproj** — never hand-edit `.xcodeproj`.

**Three targets:** `LlamasCookbookNative` (`com.llamascookbook.app`), `LlamasCookbookTimerWidget` (`.widget`), `LlamasCookbookShareExtension` (`.shareext`).

`CFBundleVersion = date -u +%s`. `MARKETING_VERSION = 1.0.0`. App target uses explicit `Resources/AppInfo.plist` (`GENERATE_INFOPLIST_FILE: NO`).

## Source layout (`ios-native/Sources/`)

- **`App/`** — `@main` + `AppDelegate`. Coordinators on `RootView`: `CookingSession`, `CookingSessionStore`, `EditorCoordinator`, `NavigationContext`, `AppearanceSettings`, `OwnerProfile`, `UserAccount`.
- **`Models/`** — five `@Model` classes; `DraftRecipe.swift`.
- **`Lib/`** — pure logic, no SwiftUI:
  - Format: `Quantity`, `Plural`, `IngredientDisplay`, `ClockFormat`, `StringCase`.
  - Import: `RecipeImporter`, `RecipeURLImporter`, `RecipeSchemaParser`, `RecipeAIParser` (`parseBestOf`), `RecipeOCRImporter`.
  - Recipe ops: `RecipeExport`, `SourdoughCalculator`, `TagPresets`.
  - Timer: `AlarmPlayer`, `TimerNotifications`, `TimerLiveActivityController`.
  - Photos: `ImageProcessing` (`CGImageSource`/`Destination` resize, `Task.detached`).
  - Auth: `KeychainStore`, `SignInWithAppleService`.
  - Cloud: `CloudKitService` (wraps `CKContainer("iCloud.com.llamascookbook.app").publicCloudDatabase`; new record IDs = 12-char `[A-Z2-9]` minus I/O/0/1; legacy 6-char share links still route).
  - UI: `Haptics`, `KeyboardDismiss.focusedNumeric`, `Shake`.
- **`Shared/`** — Foundation only, cross-target. `TimerAttributes`, `SharedContainer` (App Group `group.com.llamascookbook.app`), `Base64URL`.
- **`Theme/`** — `AppColor`, `AppFont` (system serif), `AppSpacing` (4/8/12/16/24/32/48), `AppRadius` (8/12/16/24), `ColorHex`.
- **`Views/`** — `Components/` (`LlamaLogo`, `LlamaProgressIndicator`, `RecipeImageView` NSCache-backed, `PhotoCarouselView`, `PhotoReorderView`, `ShareSheet`, `CameraCaptureView`, `AccentColorPicker`, `LlamaIntro/` coach-mark overlay + tours); `Library/`, `Detail/`, `Editor/`, `Cook/`, `Profile/`.

**Reach-for helpers (don't reinvent):**
- Sort: `Recipe.sortedIngredients` / `.sortedSteps` / `.sortedPhotos`, `RecipeStep.sortedStepPhotos`. Never `.sorted { $0.order < $1.order }` inline.
- Display: `Ingredient.display(scaledBy:)` → `Display { quantity, unit, takesOf, name, measure, fullLine }`.
- Quantity: `.parse / .format / .scale / .displayFormat / .splitForChips / .combine`.
- Plural: `Plural.unit(_, for:)` / `.needsConnector(_)`.
- Photos: `RecipeImageView`, `PhotoCarouselView`, `PhotoReorderView`, `ImageProcessing`.
- UI: `FlowRow`, `shake(count:)`, `focusedNumeric(_, when:)`. House transition: `.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity.combined(with: .scale(scale: 0.9)))` + `.spring(response: 0.42, dampingFraction: 0.82)`.

## Architectural patterns

**Editor edits a draft.** Direct edits auto-persist. Editor snapshots → `DraftRecipe`, calls `Recipe.apply(_:)` on Save. `apply(_:)` does `removeAll()` + rebuild on ingredients/steps/photos every save, cascade-deleting external-storage sidecars. **Bytes must travel through draft** (`DraftPhoto.image`, `DraftStep.images`) or every save silently loses every image.

**Coordinators above NavigationStack.** `CookingSession`, `EditorCoordinator`, `NavigationContext`, `AppearanceSettings` = `@State` in `RootView`. **Re-inject environments into covers** — `@Observable` values can drop across cover boundaries.

**Multi-cook session.** `activeCooks: [ActiveCook]` 0–4. `start` (replaces), `addParallel` (additive, dedups by `recipe.id`). `ActiveCook.id` ≠ `recipe.id`. `CookModeView` recreated per cook switch via `.id(cookID)`.

**Per-cook persistence.** Every change → `persistSnapshot()` → `CookingSessionStore.save(...)`. Force-kill recoverable: expired timers surface ready overlay (no auto-restart of alarm).

**Per-cook timer notification IDs.** `TimerNotifications.identifier(for: cookID:)` → `cooking-timer-<uuid>`. `cancelAll` also wipes legacy `"cooking-timer"`. `userInfo` carries `recipeID` + `cookID`.

**Social privacy contract.** Friends/social cookbook sharing is public/unlisted by product decision (2026-04-30), not strictly friend-private. Accepted-friend UI controls discovery inside the app, while CloudKit public DB records and Cloudflare previews support non-friend recipe receipt via Messages/links. Do not add user-facing copy that promises "only friends can see this" unless the storage architecture changes.

**Multi-cook timer hole (outstanding).** `TimerLiveActivityController` is per-`CookModeView`. Backgrounded cook's Live Activity unmanaged. Fix: `TimerLiveActivityRegistry` keyed by `cookID`.

**Quantity = String, not number.** `Ingredient.quantity: String?` (`"2 & 1/2"`) for mixed-fraction round-trip. `&` canonical on output; space also accepted.

**Per-step timer flag.** `RecipeStep.needsTimer: Bool` is source of truth. `CookModeView.timerSeconds(for:)` extracts from step text first → `recipe.cookTimeMinutes` → 5-min default.

**Special notes — four slots.** `Recipe.prefaceNote` / `epilogueNote` / `generalNote` + `RecipeStep.specialNote`.

**Detail vs Editor gallery.** Detail mutates `recipe.photos` directly (immediate persist). Editor mutates `draft.photos`, commits via `apply(_:)` on Save.

**Single keyboard `Done` for numeric fields.** One `@FocusState` in `RecipeEditorView` threaded via binding; `focusedNumeric(_, when:)` attaches on numeric keyboards. Single root `ToolbarItemGroup(placement: .keyboard)`.

**`placement: .keyboard` unreliable inside `TabView(.page)` in a sheet** — use `safeAreaInset(edge: .bottom)`. See `PhotoCarouselView.captionKeyboardAccessory`.

**SF Symbols + SwiftUI primitives only.** Four deliberate UIKit reaches: global tint via `UIView.appearance().tintColor` (synced by `AppearanceSettings.applyToUIKit()`), `UIPageControl.appearance()`, `ShareSheet` wraps `UIActivityViewController` (must trigger after async upload), `CameraCaptureView` wraps `UIImagePickerController` for manual-shutter photo capture.

**Universal Links are HTTPS, not custom-scheme.** Sender mints `https://llamascookbook.pages.dev/r/<recordName>`. iMessage refuses rich previews for `customscheme://`. Cloudflare Pages serves OG tags. Receiver handles BOTH `.onOpenURL` AND `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` — duplicate calls no-op via `pendingShareImport`. Sender preview header: `RecipeShareActivityItem` returns `LPLinkMetadata` from `activityViewControllerLinkMetadata`; `itemForActivityType` always returns raw URL (else Messages compose empty).

**OCR is just another text source.** `RecipeOCRImporter.recognize` produces `String` after cleanup pipeline (smart-quote normalize, bullet glyph normalize, page-number strip, OCR confusion repair, de-hyphenate, repeated-header strip). Same `parseBestOf` consumes it. `PhotoImportPreviewView` mirrors `RecipeImportPreviewView` chrome (Save/Cancel, duplicate-title alert via `RecipeShare.libraryContainsRecipe`/`resolveImportTitle`). Photo flow has stricter quality gate (title + ingredients + steps); below it, partial-OCR fallback offers "Continue in text editor" via `editor.startImportFromText(seedText:)`.

**Four-way FAB import.** Each maps to a distinct `EditorCoordinator.ActiveSheet` case (`.importFromText(seedText:)`, `.importFromLink(prefilledURL:)`, `.importFromPhoto`); identity ignores associated values so seed/prefill swaps don't trip dirty-state alert.

## UX principles (binding)

1. One-thumb operable. Primary actions in bottom half or toolbar.
2. Input friction = death. Quick-add, visible add buttons, Return-submits-and-refocuses.
3. Cook Mode is its own world. Warmer bg, larger type, slower pacing.
4. Gestures have visible fallbacks. Long-press Delete also in context-menu.
5. Generous whitespace.
6. Silent save. Only warn on Cancel when there's real loss.
7. Forgiving. Deletions confirmed. Timer cancel destructive-styled.

**Don't regress:**
- Quantity chips: two rows (wholes bigger, fractions smaller). Only measurable fractions — no 3/8 · 5/8 · 7/8. Tap active to deselect.
- Ampersand fractions: `2 & 1/2 cups` on display.
- Detail ingredient row: `•  2 & 1/2 cups  —  flour`. Quantity in accent semibold monospaced, em-dash.
- Per-step timer = clock glyph on quick-add and row editor.
- Floating timer banner pinned between phase header and scroll. Tap → 1–60 min wheel.
- Ready overlay: full-screen terracotta + bell + label, MinutePicker + Extend + Stop. Vibration + haptic every 1.2s until Stop/Extend.

## Signing & CI gotchas

- **Bundle ids:** `com.llamascookbook.app`, `.widget`, `.shareext`. **Team:** `GYFN949Q5E`. **ASC app id:** `6762527184`.
- **`Resources/PrivacyInfo.xcprivacy`** required. Declares `NSPrivacyAccessedAPICategoryUserDefaults` (CA92.1) + `NSPrivacyAccessedAPICategoryFileTimestamp` (C617.1). `NSPrivacyTracking = false`.
- **`NSCameraUsageDescription`** in `Resources/AppInfo.plist`. Required for `UIImagePickerController` camera mode (and historically `VNDocumentCameraViewController`). String doubles as user-facing prompt copy. Vision OCR is NOT on Required Reason API list.
- **GitHub Secrets:** `IOS_DIST_CERT_P12_BASE64`/`_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`, `IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64`, `APPSTORE_API_KEY_P8_BASE64`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`.

Intentional in `ios-native-ci.yml`:

- **`macos-26` runner pinned.** `macos-latest` = macOS 15 / Xcode 16 → ITMS-90725.
- **Xcode 26 picker prefers stable over beta.** Globs `Xcode_26*.app`, filters `beta`. Don't hardcode app name.
- **`DEVELOPER_DIR` written to `$GITHUB_ENV`** alongside `xcode-select -s` (runner profile silently overrides).
- **`xcodebuild -downloadPlatform iOS`** after `-runFirstLaunch`; 3-attempt retry (Apple endpoint flaky).
- **App icon PNGs sanitized** with ImageMagick `-alpha remove -alpha off -colorspace sRGB`. Xcode 26 rejects RGBA.
- **Timer alarm `.caf` generated at CI** (ffmpeg + afconvert). `optional: true`; falls back to `UNNotificationSound.default`.
- **`UIDesignRequiresCompatibility = true`** in `AppInfo.plist` — Liquid Glass opt-out. Apple has signaled removal in iOS 27.
- **Share Extension App Group** (`group.com.llamascookbook.app`) on BOTH profiles. Three literals must agree: `SharedContainer.appGroupID`, entitlements files, Portal.
- **`LSSupportsOpeningDocumentsInPlace = false`** required because we declare `CFBundleDocumentTypes` (else ITMS-90737).
- **SIWA entitlement:** `com.apple.developer.applesignin = ["Default"]`.
- **iCloud / CloudKit:** `com.apple.developer.icloud-container-identifiers = ["iCloud.com.llamascookbook.app"]` + `icloud-services = ["CloudKit"]`. `RecipeShare` fields: `envelope` (Asset), `senderDisplayName`, `recipeTitle`, `createdAt` (queryable+sortable), `photo0`–`photo19` (Asset, optional). Indexes: `createdAt` queryable+sortable; `createdUserRecordName` queryable for cascade. **Schema must be deployed Dev→Prod before TestFlight.** **`photo0`–`photo19` must be added MANUALLY in dev — auto-discovery only catches indexes carried by sample records, else uploads throw "cannot create or modify field photoN".** Friends feature adds four record types — `UserProfile`, `Friendship`, `PublishedRecipe`, `RecipeImport` (`PublishedRecipe` also needs the manual `photo0`–`photo19` field-add). `RecipeImport` indexes: `originalRecipeID` queryable (counter query); `importerID` + `originalCreatorID` queryable (account-deletion cascade).
- **Push Notifications (slice 6):** `aps-environment = development` in `Resources/LlamasCookbook.entitlements` (Apple substitutes `production` at distribution sign time) + `UIBackgroundModes = ["remote-notification"]` in `Resources/AppInfo.plist`. **Push Notifications capability** must be enabled on the App ID in Apple Developer Portal AND the main-app provisioning profile regenerated, else CKQuerySubscription pushes register server-side but never deliver to the device. No `.p8` APNs key needed — CloudKit-mediated pushes pass through the iCloud trust without a separate auth key. Two subscription IDs registered per user: `friendship-events-<userRecordName>` (creation + update on `Friendship` where me is participant) and `recipe-import-events-<userRecordName>` (creation only on `RecipeImport` where I'm the chain root). Silent pushes (`shouldSendContentAvailable = true`, no alertBody) fan-out via `NotificationCenter.didFireNotification` to in-app observers.
- **Associated Domains:** `com.apple.developer.associated-domains = ["applinks:llamascookbook.pages.dev"]`. Without all four (capability + profile + secret + entitlement), iOS strips entitlement → links open in Safari. Domain must match `CloudKitService.shareLinkHost` and `applinks:` host in `cloudflare-pages/.well-known/apple-app-site-association`.
- **Cloudflare Pages:** `cloudflare-pages/` auto-builds on push to main. Required env (Production AND Preview): `CLOUDKIT_CONTAINER_ID`, `CLOUDKIT_KEY_ID`, `CLOUDKIT_PRIVATE_KEY` (Secret, ECDSA P-256 PEM from Server-to-Server), `CLOUDKIT_ENVIRONMENT=production`. Worker reads `recipeTitle` + `photo0`, renders OG-tagged HTML at `/r/<id>`, proxies photo at `/img/<id>`. `_headers` forces `Content-Type: application/json` on AASA.
- **SwiftData `cloudKitDatabase: .none` opt-out** in `LlamasCookbookApp.makeModelContainer()`. Default `.automatic` detects iCloud entitlement → tries CloudKit-backed sync → fails on our schema (`.cascade` + non-optional). **Failure mode silent** — recipes save then vanish on relaunch. **Don't switch to `.modelContainer(for:)` modifier** — doesn't expose `cloudKitDatabase`.

Watch: `Print toolchain` step's `iphoneos --show-sdk-version` is the canary — if it drops below 26.x, ITMS-90725 returns.

## Known limitations / deferred

- Multi-cook timer registry (see "Multi-cook timer hole").
- Settings screen — stub (only accent wired, via `AccentColorPicker`).
- iPad — iPhone only.
- Live Activity App Intents (in-island +1/−1/cancel) deferred.
- Custom type — Fraunces / Inter not bundled; system serif placeholder.
- iCloud sync for SwiftData — intentional `.none` opt-out.
- `RecipeStep.image: Data?` — deprecated, kept for migration.
- Liquid Glass — must adopt before iOS 27.
- Cloud-share diagnostic alert temporary — revert once Universal Link verified.
- Cloudflare preview falls back to "A Recipe" + llama icon if CloudKit lookup fails. Working as intended.

## What's next

1. Verify Universal Link end-to-end on real devices, revert diagnostic alert in `RecipeDetailView.cloudShareError`.
2. Friends feature portal/schema: enable Push Notifications capability + regenerate `IOS_PROVISIONING_PROFILE_BASE64`; deploy `RecipeImport` Dev → Prod with `originalRecipeID` / `importerID` / `originalCreatorID` queryable.
3. Per-cook `TimerLiveActivityRegistry`.
4. Aesthetic / typography pass.
5. Liquid Glass adoption.

Queued: dark mode, Settings, iPad, App Intents on Live Activity, visible-alert push copy (slice 6 ships silent only).

## Working with this doc

- Update when product behavior changes.
- Code wins disagreements; update the doc.
- Plan docs decay; grep code before quoting.
