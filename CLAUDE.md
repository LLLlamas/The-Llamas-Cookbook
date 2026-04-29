# CLAUDE.md

Source of truth. This file > PROJECT.md / plan docs. Code > this file (update when out of sync). Last refreshed 2026-04-29.

## Doc map

1. **CLAUDE.md** — this file. Auto-loaded.
2. **PROJECT.md** — tech-stack rationale, signing, dev workflow. "Current status" sections stale.
3. **llamas-cookbook-plan.md** — original spec; vision/JTBD/UX still authoritative.
4. **ROADMAP.md** — deferred work + portal-setup checklist.
5. **STATE.md** — archived 2026-04-27.

Plan docs decay; verify against code before quoting.

- **Multi-Recipe-Cook-Mode** — landed (`activeCooks`, pills, v1→v2). Outstanding: per-cook `TimerLiveActivityRegistry`.
- **Photo-Capability** — done. `RecipeStep.image: Data?` deprecated; never write.
- **Recipe-Sharing** — PR 1–3 done. URL-deep-link is the only outbound form. `.llamarecipe` for AirDrop-incoming + paranoid fallback only. PR 4 (Share Extension) done.
- **Implementing-User-Sign-In** — pivoted 2026-04-28: friend-code/inbox/push dropped → cloud-permalink. PR 1 (SIWA + Profile + Keychain) done; PR 2 = three slices (iCloud + `CloudKitService`; upload + permalink + receive; Delete-Account cascade), all done locally. **SIWA not required for sharing — only iCloud (system-level).** 2026-04-29: permalinks switched from `llamascookbook://share/<id>` → HTTPS Universal Links `https://llamascookbook.pages.dev/r/<id>` for rich Messages previews; added `cloudflare-pages/` site + Associated Domains entitlement.
- **Share-Extension-Plan** — done. `LlamasCookbookShareExtension` target. Passthrough: URLs → `llamascookbook://share-url/<base64url>`; files → App Group + `share-incoming/<uuid>`.
- **SDK-Update-Plan** — done. Build SDK iOS 26.x; `UIDesignRequiresCompatibility = true` until aesthetic pass.

## TL;DR

Core CRUD done end-to-end. Past parity with archived RN app except Settings. Recent: photos, multi-recipe Cook Mode (1–4), Universal-Link sharing via Cloudflare Pages.

Active queue: sharing PR 3+4 + sign-in PR 1 / slices 1–3 (CI + portal), per-cook `TimerLiveActivityRegistry`, aesthetic/typography pass. Diagnostic alert in `RecipeDetailView` is **temporary** — revert to silent fall-through once Universal Link verified end-to-end.

## Capability map

| Capability | Where | Notes |
|---|---|---|
| Profile | `Views/Profile/ProfileView.swift` + person-circle in `LibraryView` toolbar | SIWA toggle. Identity: `App/UserAccount.swift`; `appleSub` + name in Keychain via `Lib/KeychainStore.swift`. |
| Library | `Views/Library/LibraryView.swift` | All / Favorites / tag chips. Long-press + context-menu Delete. A–Z scrub. Mascot watermark 6%. |
| Add / Import FAB | `LibraryView` | Four entries: "Write Down Your Recipe" (empty editor) / "Import From Text" / "Import From Link" / "Import From Photo". |
| Recipe Detail | `Views/Detail/RecipeDetailView.swift` | Sections, gallery + step thumbs, share menu, sourdough chip, "Add to Cook Mode" green button when active. |
| Favorite | `RecipeDetailView` | Heart toolbar, syncs `updatedAt`. |
| Export (text) | `Lib/RecipeExport.swift` | Plain-text bridge, last in share menu. |
| Recipe sharing | `Lib/CloudKitService.swift` + `Lib/RecipeShare.swift` + `Views/Components/ShareSheet.swift` + `Views/Components/LlamaProgressIndicator.swift` | **Cloud Universal Link first, local URL fallback.** `CKAccountStatus.available` → upload to public DB as `RecipeShare`; **photos as separate `CKAsset` fields `photo0`–`photo19`**. Shares `https://llamascookbook.pages.dev/r/<6char-id>`. Fallback: `llamascookbook://recipe/v2/<base64url>` (lzma, no photos). `RecipeShareActivityItem` → `LPLinkMetadata` for sender's preview header; recipient bubble preview = Cloudflare OG tags. Outbox `cloudShareOutbox.v1` (UserDefaults) for Delete-Account cascade. **Temporary diagnostic alert** surfaces CloudKit errors. |
| Recipe import (share) | `Views/Library/RecipeImportPreviewView.swift` + `RootView.onOpenURL` + `RootView.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` | Handles `.llamarecipe` files, `recipe/v<N>/`, legacy `share/<id>`, AND HTTPS Universal Links. iOS 18 delivers Universal Links via either route depending on launch state — both → `routeUniversalLink` → `fetchCloudShareRecord`. All paths → read-only mini-Detail; Save → `RecipeShare.materialize` (rewrites UUIDs, stamps `sharedBy/sharedAt/sourceShareID`) then deferred `libraryPath.append`. |
| Share Extension | `ShareExtension/ShareViewController.swift` + `Sources/Shared/SharedContainer.swift` + `Sources/Shared/Base64URL.swift` | Passthrough only. URLs → `share-url/<base64url>` → `EditorCoordinator.startImport(prefilledURL:)`. Files → App Group → `share-incoming/<uuid>`. No SwiftData / `Recipe` types. |
| Conversions | `Views/Detail/ConversionsView.swift` | Cards + live calculator. |
| Sourdough | `Views/Detail/SourdoughCalculatorView.swift` + `Lib/SourdoughCalculator.swift` | For `sourdough` / `bread` / `baking` tags. |
| Editor | `Views/Editor/RecipeEditorView.swift` | Quick-add, per-step timer toggle, drag-reorder, tags, special notes, photos. |
| Import (text) | `Views/Library/ImportFromTextView.swift` + `Lib/RecipeImporter.swift` | Pure text-paste import. Verification panel asks "is this the first ingredient?" / "is this the first step for the recipe?" so users catch parser misfires. Accepts `seedText` from photo-import partial-OCR fallback. |
| Import (URL) | `Views/Library/ImportFromLinkView.swift` + `Lib/RecipeURLImporter.swift` + `Lib/RecipeSchemaParser.swift` | URL-only import. JSON-LD → OG fallback, TikTok via oEmbed, Pinterest HTML. IG/FB blocked. Reachable from FAB ("Import From Link") and share-extension URL handoffs (`routeShareExtensionURL` → `editor.startImportFromLink(url:)`). Partial fetches hand off to text-import sheet via `editor.startImportFromText(seedText:)`. |
| Import (photo) | `Views/Library/ImportFromPhotoView.swift` + `Views/Library/PhotoImportPreviewView.swift` + `Lib/RecipeOCRImporter.swift` + `Views/Components/DocumentScannerView.swift` | Live VisionKit document scan or `PhotosPicker` → Vision text recognition + OCR cleanup pipeline → `RecipeAIParser.parseBestOf` → share-style read-only preview screen with Save/Cancel + duplicate-title rename alert. On-device only. Stricter quality gate (title + ingredients + steps); below it, partial-OCR fallback banner offers "Continue in text editor" with seed text pre-loaded. |
| AI parser | `Lib/RecipeAIParser.swift` | iOS 26+ `FoundationModels`. Public `parseBestOf` runs LLM + regex in parallel, picks the better draft. Used by URL importer (TikTok / Pinterest / OG-fallback) and OCR importer (cookbook pages). Schema carries `servings`, `cookTimeMinutes`, `prepTimeMinutes` so cookbook page metadata makes it through. Silent fallback to regex when model unavailable. |
| Cook Mode | `Views/Cook/CookModeView.swift` | Two-phase, scaler, check-off, floating timer banner, ready overlay, alarm. |
| Multi-cook pills | in `CookModeView` family | 1–4. Solid foreground, outline rest. |
| Cook tuck-down | `RootView` cover detents | `[.large, .height(80)]`. |
| Timer + Live Activity | `Lib/TimerLiveActivityController.swift` + `WidgetExtension/TimerLiveActivity.swift` | Lock screen + Dynamic Island. Background ding via `TimerNotifications`. |
| Cook persistence | `App/CookingSessionStore.swift` | `[CookingSessionState]` JSON in UserDefaults `cooking-session-states.v2`; v1→v2 migration. Force-kill recoverable. |
| Editor coordinator | `App/EditorCoordinator.swift` | Sheet open/dirty gating + discard alert. |
| Accent | `App/AppearanceSettings.swift` | Hex-persisted. |

## Tech stack

Swift 5.10, SwiftUI, iOS 18+. State: `@State` / `@Observable` / SwiftData `@Model`. Persistence: SwiftData + UserDefaults (cook session, accent, owner profile, user-account aux) + Keychain (`appleSub`, name). Nav: `NavigationStack` + `.sheet` + `.fullScreenCover` (Cook Mode + Editor hoisted to `RootView`). Notifications: `UNUserNotificationCenter`, per-cook ID `cooking-timer-<cookID>`. Live Activity: `ActivityKit`, `TimerAttributes` cross-compiled via `Sources/Shared/`. AI: `FoundationModels` (iOS 26+), regex floor. OCR: `Vision` (`VNRecognizeTextRequest`) + `VisionKit` (`VNDocumentCameraViewController`) — both stdlib, on-device, no Required Reason API entries. Alarm: bundled `timer-alarm.caf` (CI-generated by ffmpeg + afconvert), `AVAudioPlayer` loop. Project file: XcodeGen `ios-native/project.yml`. Build: GH Actions `macos-26` → `xcodebuild archive` → TestFlight via `xcrun altool`, manual `workflow_dispatch`. **Build SDK iOS 26.x** (ITMS-90725). Min iOS 18.0. iPhone-only, portrait.

**Don't use:** UIKit beyond two `appearance()` proxies + `ShareSheet` (`UIViewControllerRepresentable`); no Combine; no SPM/CocoaPods; no Core Data.

## Data model

`Sources/Models/Recipe.swift` — five `@Model` classes:

```swift
@Model final class Recipe {
    var id, title, summary, sourceUrl, imageUri, servings, cookTimeMinutes,
        prepTimeMinutes, notes, favorite, tags, lastCookedAt, cookCount,
        createdAt, updatedAt
    var prefaceNote, epilogueNote, generalNote: String?
    @Relationship(.cascade) var ingredients: [Ingredient]
    @Relationship(.cascade) var steps: [RecipeStep]
    @Relationship(.cascade) var photos: [RecipePhoto]
    var sortedIngredients / sortedSteps / sortedPhotos
}
@Model final class Ingredient { var id, quantity: String?, unit, name, order, recipe }
@Model final class RecipeStep {
    var id, order, text, needsTimer
    var specialNote: String?
    @Attribute(.externalStorage) var image: Data? = nil   // DEPRECATED
    @Relationship(.cascade) var photos: [RecipeStepPhoto] // ≤3 per step
    var sortedStepPhotos
}
@Model final class RecipePhoto     { var id, image: Data?, caption: String?, order, recipe }
@Model final class RecipeStepPhoto { var id, image: Data?, caption: String?, order, step }
```

`RecipeStep.image` deprecated — kept for SwiftData lightweight migration; never write. `DraftRecipe` / `DraftIngredient` / `DraftStep` / `DraftPhoto` (`Models/DraftRecipe.swift`) = plain structs.

## Repo + dev loop

iOS in `ios-native/`. Repo root = docs + `outdated/rn-expo/` (archived; **do not modify**) + `cloudflare-pages/` (Universal-Link preview site; auto-builds on push to main, root = `cloudflare-pages`).

**CI-only.** Windows dev box; Swift can't build iOS on Windows. Every build runs `macos-26` via `.github/workflows/ios-native-ci.yml`, `workflow_dispatch`, ~15–25 min:
- No Xcode Previews (`#Preview` compiles, can't view).
- Compile errors live in `CompileSwift normal arm64` log section, *above* the "build commands failed" tail.
- Don't run `xcodegen` / `xcodebuild` / `pod` here.
- One CI cycle per syntactic mistake — be deliberate.

**XcodeGen, not pbxproj** — `.xcodeproj` regenerated from `ios-native/project.yml`; never hand-edit.

**Three targets, one archive:** `LlamasCookbookNative` (`com.llamascookbook.app`), `LlamasCookbookTimerWidget` (`.widget`), `LlamasCookbookShareExtension` (`.shareext`).

`CFBundleVersion = date -u +%s`. `MARKETING_VERSION = 1.0.0` (bump in `project.yml`).

App target uses **explicit `Resources/AppInfo.plist`** (`GENERATE_INFOPLIST_FILE: NO`) because `CFBundleURLTypes` + `UIDesignRequiresCompatibility` aren't expressible via `INFOPLIST_KEY_*`.

## Source layout (`ios-native/Sources/`)

- **`App/`** — `@main` `LlamasCookbookApp.swift` + `AppDelegate` (foreground notifications + deep-link routing). Coordinators on `RootView`: `CookingSession` (`activeCooks`, `foregroundedCookID`, `pendingRestoration`), `CookingSessionState` + `CookingSessionStore`, `EditorCoordinator`, `NavigationContext`, `AppearanceSettings`, `OwnerProfile`, `UserAccount`.
- **`Models/`** — five `@Model` classes; `DraftRecipe.swift` (structs + `toDraft()` / `apply(_:)`).
- **`Lib/`** — pure logic, no SwiftUI:
  - Format: `Quantity` (parse/format/scale + measurable-fraction snap, `ClockFormat.mmss`, `StringCase`), `Plural`, `IngredientDisplay`.
  - Import: `RecipeImporter`, `RecipeURLImporter`, `RecipeSchemaParser`, `RecipeAIParser` (public `parseBestOf` for callers — URL importer, OCR importer), `RecipeOCRImporter` (Vision wrapper + cleanup pipeline).
  - Recipe ops: `RecipeExport`, `SourdoughCalculator`, `TagPresets`.
  - Timer/audio: `AlarmPlayer`, `TimerNotifications`, `TimerLiveActivityController`.
  - Photos: `ImageProcessing` (`CGImageSource`/`Destination` resize + format-preserving re-encode + bytes guard, `Task.detached`).
  - Auth: `KeychainStore` (`SecItem*`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), `SignInWithAppleService` (only `AuthenticationServices` import).
  - Cloud: `CloudKitService` (wraps `CKContainer(identifier: "iCloud.com.llamascookbook.app").publicCloudDatabase`; `accountStatus()`, `uploadShare`, `fetchShare`, `deleteShare`, outbox, `deleteAuthoredShares`; record IDs = 6-char `[A-Z2-9]` minus I/O/0/1).
  - UI: `Haptics`, `KeyboardDismiss.focusedNumeric`, `Shake`.
- **`Shared/`** — Foundation only, cross-target. `TimerAttributes`, `SharedContainer` (App Group `group.com.llamascookbook.app`), `Base64URL`.
- **`Theme/`** — `AppColor` (cream/terracotta + `.onAccent`), `AppFont` (system serif), `AppSpacing` (xs=4 / sm=8 / md=12 / lg=16 / xl=24 / xxl=32 / xxxl=48), `AppRadius` (sm=8 / md=12 / lg=16 / xl=24), `ColorHex`.
- **`Views/`** — feature folders: `Components/` (`LlamaLogo`, `LlamaProgressIndicator`, `EmptyLibraryView`, `RecipeImageView` NSCache-backed, `PhotoCarouselView`, `PhotoReorderView`, `AccentColorPicker`, `ShareSheet`, `DocumentScannerView`); `Library/`, `Detail/`, `Editor/`, `Cook/`, `Profile/`.

**Reach-for helpers (don't reinvent):**
- Sort: `Recipe.sortedIngredients` / `.sortedSteps` / `.sortedPhotos`, `RecipeStep.sortedStepPhotos`. Never `.sorted { $0.order < $1.order }` inline.
- Display: `Ingredient.display(scaledBy:)` → `Display { quantity, unit, takesOf, name, measure, fullLine }`.
- Quantity: `.parse / .format / .scale / .displayFormat / .splitForChips / .combine`.
- Plural: `Plural.unit(_, for:)` / `.needsConnector(_)`.
- Photos: `RecipeImageView` (render), `PhotoCarouselView` + `PhotoReorderView` (edit), `ImageProcessing` (resize + bytes).
- UI: `FlowRow`, `shake(count:)`, `focusedNumeric(_, when:)`. House transition: `.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity.combined(with: .scale(scale: 0.9)))` + `.spring(response: 0.42, dampingFraction: 0.82)`.

## Architectural patterns

**Editor edits a draft, not the model.** Direct edits would auto-persist. Editor snapshots → `DraftRecipe`, calls `Recipe.apply(_:)` on Save. **`apply(_:)` does `removeAll()` + rebuild** on ingredients/steps/photos every save, cascade-deleting external-storage sidecars. **Bytes must travel through draft** (`DraftPhoto.image`, `DraftStep.images`) or every save silently loses every image.

**Coordinators above NavigationStack.** `CookingSession`, `EditorCoordinator`, `NavigationContext`, `AppearanceSettings` = `@State` in `RootView`, propagated via `.environment(...)`. Cook Mode `.fullScreenCover` + Editor `.sheet` hoisted to RootView. **Re-inject environments explicitly into covers** — `@Observable` values can drop across cover boundaries.

**Multi-cook session.** `activeCooks: [ActiveCook]` (private(set)) holds 0–4. `start` (replaces), `addParallel` (additive, dedups by `recipe.id`, refuses over-cap), `remove`, `foreground`, `minimize`, `resume`, `restore`. `ActiveCook.id` ≠ `recipe.id`. **`CookModeView` recreated per cook switch via `.id(cookID)`** — `@State` (phase/strikes/timer) seeds fresh from `pendingRestoration`.

**Per-cook persistence.** Every meaningful change → `persistSnapshot()` → `CookingSession.persistForegroundedSnapshot(_:)` → `CookingSessionStore.save(...)`. Force-kill mid-cook recoverable: expired timers surface ready overlay (no auto-restart of alarm).

**Per-cook timer notification IDs.** `TimerNotifications.identifier(for: cookID:)` → `cooking-timer-<uuid>`. `cancelAll` also wipes legacy `"cooking-timer"`. `userInfo` carries `recipeID` + `cookID`; `AppDelegate.didReceive` routes `llamascookbook://cook/<recipeID>`; widget bakes same URL.

**Multi-cook timer hole (outstanding).** `TimerLiveActivityController` is per-`CookModeView`. Backgrounded cook's Live Activity unmanaged (iOS keeps ticking via `endDate`, but extending/cancelling from foreground won't reach it). Fix: `TimerLiveActivityRegistry` keyed by `cookID`.

**Quantity = String, not number.** `Ingredient.quantity: String?` (`"2 & 1/2"`) for mixed-fraction round-trip. `Quantity.swift` snaps to measurable fractions. Both `&` and space accepted; `&` canonical on output.

**Per-step timer flag.** `RecipeStep.needsTimer: Bool` is source of truth. `CookModeView.timerSeconds(for:)` extracts from step text first (range regex takes *smaller* number) → `recipe.cookTimeMinutes` → 5-min default.

**Special notes — four slots.** `Recipe.prefaceNote` / `epilogueNote` / `generalNote` + `RecipeStep.specialNote`. `SpecialNotesEditor` enforces "one per slot."

**Detail vs Editor gallery.** Detail mutates `recipe.photos` directly (`append` + `modelContext.delete`) — **immediate persist, no Save**. Editor mutates `draft.photos`, commits via `apply(_:)` on Save; Cancel discards. **Reorder same dichotomy:** Detail rewrites `RecipePhoto.order` on live `@Model` (nil-image rows pushed past visible tail); Editor reseats `draft.photos`. Step-photo reorder: `step.images.move(fromOffsets:toOffset:)`.

**Single keyboard `Done` for numeric fields.** One `@FocusState private var isNumericFocused: Bool` in `RecipeEditorView`, threaded via binding; `focusedNumeric(_, when:)` attaches it only to numeric keyboards. Single root `ToolbarItemGroup(placement: .keyboard)` shows Done when focused. Add new numeric fields with this helper.

**`placement: .keyboard` unreliable inside `TabView(.page)` in a sheet — use `safeAreaInset(edge: .bottom)`.** Toolbar misses first focus, intermittently appears later. See `PhotoCarouselView.captionKeyboardAccessory`: custom Done bar in `safeAreaInset(edge: .bottom)`, gated by lifted `@FocusState<Int?>`. iOS keyboard-avoidance lifts the inset above keyboard automatically.

**SF Symbols + SwiftUI primitives only.** Logo = bitmap from `Assets.xcassets/LlamaLogo.imageset`; PNG body color baked, only drop shadow tintable. Three deliberate UIKit reaches: global tint (`UIView.appearance().tintColor`, kept synced to accent by `AppearanceSettings.applyToUIKit()` — keyboard Return key, nav back chevron, selection handles follow picker), PageControl dot color (`UIPageControl.appearance()`), `ShareSheet` wraps `UIActivityViewController` (SwiftUI `ShareLink` can't trigger programmatically — async upload must complete before sheet presents).

**Universal Links are HTTPS, not custom-scheme.** Sender mints `https://llamascookbook.pages.dev/r/<recordName>` (`CloudKitService.shareLinkHost` + `shareLinkPathPrefix`). Why: (1) iMessage refuses rich previews for `customscheme://` (anti-spoofing) — bare URL bubble. (2) HTTPS → Cloudflare Pages with OG tags → recipient sees recipe photo + title. (3) Universal Link opens app when installed (validated against AASA at host); else friendly "Get the app" page. Receiver handles BOTH `.onOpenURL` AND `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` — iOS 18 delivers via either depending on cold/warm launch; duplicate calls no-op via `pendingShareImport`. **Sender preview header** uses `RecipeShareActivityItem` returning `LPLinkMetadata` from `activityViewControllerLinkMetadata`; **`itemForActivityType` always returns raw URL** so Messages/Mail can put it in body — returning `LPLinkMetadata` there leaves Messages compose empty. Recipient bubble preview = Cloudflare OG tags, NOT inline `LPLinkMetadata`.

**OCR is just another text source.** `RecipeOCRImporter.recognize` produces a `String` after a cleanup pipeline (smart-quote normalize, bullet glyph normalize, page-number strip, section-header isolation, OCR confusion repair, whitespace collapse, de-hyphenate, repeated-header strip). The same `RecipeAIParser.parseBestOf(text:sourceUrl:)` (lifted out of `RecipeURLImporter`) consumes it — best-of LLM + regex with the regex pipeline as the floor. New input shapes plug in here without touching the parser. The share-style `PhotoImportPreviewView` mirrors `RecipeImportPreviewView`'s read-only preview chrome (Save / Cancel toolbar, duplicate-title rename alert reuses `RecipeShare.libraryContainsRecipe` / `resolveImportTitle`) so users get the same accept-or-cancel metaphor regardless of where the recipe came from. Photo flow uses a stricter quality gate (title + ingredients + steps) than URL flow's OR gate; below that, partial-OCR fallback banner offers "Continue in text editor" via `editor.startImportFromText(seedText:)` — a smooth in-place sheet swap from `.importFromPhoto` to `.importFromText` since both live in the same `EditorCoordinator.ActiveSheet` enum.

**Four-way FAB import split.** "Write Down Your Recipe" → empty editor. "Import From Text" → `ImportFromTextView` (text-only paste, redesigned verification panel asking "is this the first ingredient?" / "is this the first step for the recipe?"). "Import From Link" → `ImportFromLinkView` (URL fetch only; partial fetches hand off to text-import with seed text). "Import From Photo" → `ImportFromPhotoView` (camera + library picker + OCR). Each maps to a distinct `EditorCoordinator.ActiveSheet` case (`.importFromText(seedText:)`, `.importFromLink(prefilledURL:)`, `.importFromPhoto`); identity / equality ignores associated values so seed/prefill swaps don't trip the dirty-state discard alert. Share-extension URL handoff routes to `editor.startImportFromLink(url:)`, not the text path.

## UX principles (binding)

1. One-thumb operable. Primary actions in bottom half or toolbar.
2. Input friction = death. Quick-add, visible add buttons, Return-submits-and-refocuses, one conditional Done.
3. Cook Mode is its own world. Warmer bg, larger type (`ingredientCook`), slower pacing.
4. Gestures have visible fallbacks. Long-press Delete also in context-menu.
5. Generous whitespace.
6. Silent save. Only warn on Cancel when there's real loss.
7. Forgiving. Deletions confirmed. Timer cancel destructive-styled.

**Don't regress:**
- Quantity chips: two rows (wholes bigger/bolder, fractions smaller). Only measurable fractions — no 3/8 · 5/8 · 7/8. Tap active to deselect.
- Ampersand fractions: `2 & 1/2 cups` on display. Parser also accepts `2 1/2`.
- Detail ingredient row: `•  2 & 1/2 cups  —  flour`. Quantity in accent semibold monospaced, em-dash, name in textPrimary.
- Per-step timer = clock glyph on step quick-add and row editor.
- Floating timer banner pinned between phase header and scroll. Tap → 1–60 min wheel sheet.
- Ready overlay: full-screen terracotta + bell + `"{Label} timer ready!"`, MinutePicker + filled Extend (preserves `timerStepId`) + outlined Stop. Vibration + haptic every 1.2s until Stop/Extend.

## Signing & CI gotchas

- **Bundle ids:** `com.llamascookbook.app`, `.widget`, `.shareext`. **Team:** `GYFN949Q5E`. **ASC app id:** `6762527184`.
- **`Resources/PrivacyInfo.xcprivacy`** required. Declares `NSPrivacyAccessedAPICategoryUserDefaults` (CA92.1) + `NSPrivacyAccessedAPICategoryFileTimestamp` (C617.1, for `SharedContainer.sweepShareInbox`). `NSPrivacyTracking = false`. New required-reason API → declare BEFORE next upload.
- **`NSCameraUsageDescription`** in `Resources/AppInfo.plist`. Required for `VNDocumentCameraViewController` (the photo-import path). Apple Reviewer auto-rejects builds that present a camera UI without a usage-description string. The string itself doubles as user-facing copy in the iOS permission prompt — keep it honest about scope ("photos stay on your device"). No `PrivacyInfo.xcprivacy` change is needed; Vision text recognition isn't on the Required Reason API list.
- **GitHub Secrets:** `IOS_DIST_CERT_P12_BASE64`/`_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`, `IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64`, `APPSTORE_API_KEY_P8_BASE64`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`.

Intentional — see `ios-native-ci.yml` comments before changing:

- **`macos-26` runner pinned.** `macos-latest` = macOS 15 / Xcode 16 → ITMS-90725.
- **Xcode 26 picker prefers stable over beta.** Beta SDKs ship simulator-runtime mismatch breaking `actool` even on device builds. Globs `Xcode_26*.app`, filters `beta`, sorts by version, falls back with `::warning::`. **Don't hardcode app name** — Apple ships point releases; naive `sort -V | tail -1` picks beta because `26.5_beta > 26.4.1`.
- **`DEVELOPER_DIR` written to `$GITHUB_ENV`** alongside `xcode-select -s` — runner pre-sets `DEVELOPER_DIR` in shell profile pointing at default Xcode (currently beta), silently overrides.
- **`xcodebuild -downloadPlatform iOS`** runs after `-runFirstLaunch`; `actool` thinning cross-checks simulator runtimes even on device builds. 3-attempt retry — Apple's content endpoint flaky from CI.
- **App icon PNGs sanitized at CI** with ImageMagick `-alpha remove -alpha off -colorspace sRGB -define png:color-type=2`. Xcode 26 hard-rejects RGBA; empty appiconset fails fast.
- **Timer alarm `.caf` generated at CI** (ffmpeg + afconvert). `optional: true` in `project.yml`; falls back to `UNNotificationSound.default`.
- **`UIDesignRequiresCompatibility = true`** in `AppInfo.plist` — Liquid Glass opt-out on iOS 26. Apple has signaled removal in iOS 27.
- **Share Extension App Group entitlement** (`group.com.llamascookbook.app`) MUST be on BOTH main app and extension profiles. Enabling on App ID requires regenerating profile (entitlement baked at issue). Three literals must agree: `SharedContainer.appGroupID`, entitlements files in `Resources/` + `ShareExtension/`, App Group ID in Portal.
- **`LSSupportsOpeningDocumentsInPlace = <false/>`** required because we declare `CFBundleDocumentTypes` (for `.llamarecipe`); else ITMS-90737. `false` is right — copy into Inbox, materialize, never touch source.
- **SIWA entitlement:** `com.apple.developer.applesignin = ["Default"]` in `Resources/LlamasCookbook.entitlements`. Capability on App ID + profile regenerated + `IOS_PROVISIONING_PROFILE_BASE64` updated.
- **iCloud / CloudKit entitlement:** `com.apple.developer.icloud-container-identifiers = ["iCloud.com.llamascookbook.app"]` + `com.apple.developer.icloud-services = ["CloudKit"]`. Capability + container in portal + profile regenerated. `RecipeShare` fields: `envelope` (Asset), `senderDisplayName` (String), `recipeTitle` (String), `createdAt` (Date/Time, queryable + sortable), `photo0`–`photo19` (Asset, optional). Indexes: `createdAt` queryable + sortable; `createdUserRecordName` (a.k.a. `___createdBy` / `creatorUserRecordID`) queryable for Delete-Account cascade. **Schema must be deployed Dev→Prod before any TestFlight build that exercises cloud-share.** **`photo0`–`photo19` auto-create in dev only when a record carries that index — dev's auto-discovered schema usually missing most. Add MANUALLY in dev before deploying prod, else uploads throw "cannot create or modify field photoN in record RecipeShare"** (verified 2026-04-29). Container ID matches across entitlement, `CloudKitService.containerID`, Portal.
- **Associated Domains entitlement:** `com.apple.developer.associated-domains = ["applinks:llamascookbook.pages.dev"]`. Capability + profile regenerated + secret updated. Without all four, iOS silently strips entitlement at sign-time → Universal Links open in Safari. Domain string must match `CloudKitService.shareLinkHost` and `applinks:` host in `cloudflare-pages/.well-known/apple-app-site-association` (declares `GYFN949Q5E.com.llamascookbook.app` against `/r/*`). One host string, no drift.
- **Cloudflare Pages dependency:** previews depend on `https://llamascookbook.pages.dev`. `cloudflare-pages/` = deployment source (auto-builds on push to main; root = `cloudflare-pages`). Required env (Production AND Preview): `CLOUDKIT_CONTAINER_ID`, `CLOUDKIT_KEY_ID`, `CLOUDKIT_PRIVATE_KEY` (Secret), `CLOUDKIT_ENVIRONMENT=production`. `CLOUDKIT_PRIVATE_KEY` = ECDSA P-256 PEM from CloudKit Console → Server-to-Server (read-only public DB sufficient); Worker signs with ECDSA-SHA256 in `cloudflare-pages/lib/cloudkit.js`. Worker reads `recipeTitle` + `photo0`, renders OG-tagged HTML at `/r/<id>`, proxies photo at `/img/<id>`. `_headers` forces `Content-Type: application/json` on AASA (Apple is strict). Key revocation = generic-fallback previews ("A Recipe" + llama icon).
- **SwiftData `cloudKitDatabase: .none` opt-out:** `LlamasCookbookApp.makeModelContainer()` builds `ModelConfiguration` with `cloudKitDatabase: .none` explicitly. Default `.automatic` detects iCloud entitlement → tries CloudKit-backed sync → fails on our schema (`.cascade` + non-optional w/o defaults). **Failure mode silent** — falls back to in-memory, recipes save then vanish on relaunch. Discovered 2026-04-28; explicit `.none` mandatory. **Don't switch to `.modelContainer(for:)` modifier** — doesn't expose `cloudKitDatabase`.

Watch: `Print toolchain` step's `iphoneos --show-sdk-version` is the canary — if it drops below 26.x, ITMS-90725 returns.

## Known limitations / deferred

- Multi-cook timer registry (see "Multi-cook timer hole").
- Settings screen — stub (only accent wired).
- Keep-awake during Cook Mode — `isIdleTimerDisabled` not wired.
- iPad — iPhone only.
- Live Activity App Intents (in-island +1/−1/cancel) deferred.
- Custom type — Fraunces / Inter not bundled; system serif placeholder.
- iCloud sync for SwiftData — intentional `.none` opt-out.
- `RecipeStep.image: Data?` — deprecated, kept for migration.
- Liquid Glass — must adopt before iOS 27 makes `UIDesignRequiresCompatibility` removal mandatory.
- **Cloud-share diagnostic alert** — `RecipeDetailView.cloudShareError` + alert temporary. Revert `tryShareViaCloud` catch + `shareViaPreferredTransport` guard to silent fall-through once Universal Link verified end-to-end.
- Cloudflare preview falls back to "A Recipe" + llama icon if CloudKit lookup fails (env vars missing, network blip, deleted record). Working as intended.

## What's next

1. Sharing PR 3+4 land (CI).
2. Sign-in PR 1 + slices 1–3 land (CI + portal).
3. Verify Universal Link end-to-end on real devices, then revert temporary diagnostic alert.
4. Per-cook `TimerLiveActivityRegistry` (lift controller out of `CookModeView`, key by `cookID`).
5. Aesthetic / typography pass.
6. Liquid Glass adoption.

Queued: dark mode (palette is sRGB-explicit, needs semantic tokens), Settings, iPad, App Intents on Live Activity.

## Working with this doc

- **CLAUDE.md is kept current.** Update when product behavior changes.
- **Code wins.** When memory or docs disagree with code, code wins; update the doc.
- Plan docs decay after implementation; grep code before quoting.
