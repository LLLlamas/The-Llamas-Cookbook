# CLAUDE.md

Single source of truth for the current state of the app. When this file disagrees with PROJECT.md or any feature plan doc, this file wins. When it disagrees with the code, the code wins — update this file. Last refreshed 2026-04-29.

## Source of truth — read in this order

1. **CLAUDE.md** (this file) — current snapshot, patterns, CI gotchas. Loaded automatically.
2. **[PROJECT.md](./PROJECT.md)** — tech-stack rationale, signing material, dev workflow. Its "current status" sections are stale.
3. **[llamas-cookbook-plan.md](./llamas-cookbook-plan.md)** — original product spec. Vision / JTBD / UX principles still authoritative.
4. **[ROADMAP.md](./ROADMAP.md)** — deferred work + Live Activity portal-setup checklist.
5. **STATE.md** — archived 2026-04-27, do not update.

Feature design docs are *plans*, not specs — verify against code before quoting:

- **[Multi-Recipe-Cook-Mode.md](./Multi-Recipe-Cook-Mode.md)** — PR 1 + PR 2 landed (`activeCooks` array, pills bar, v1→v2 migration). **Not done:** per-cook `TimerLiveActivityRegistry`; two parallel timers collide on Live Activity / alarm.
- **[Photo-Capability.md](./Photo-Capability.md)** — fully implemented. Gallery + per-step photos (≤3), shared `PhotoCarouselView` / `PhotoReorderView` / `RecipeImageView` / `ImageProcessing` infra. `RecipeStep.image: Data?` is **deprecated** (migration only); never write to it.
- **[Recipe-Sharing.md](./Recipe-Sharing.md)** — PR 1–3 implemented. URL-deep-link is the only outbound Llamas-Cookbook share form, lzma-compressed and v2-prefixed. `.llamarecipe` file form is wired for AirDrop-incoming + paranoid fallback only. PR 4 (Share Extension) implemented in parallel.
- **[Implementing-User-Sign-In.md](./Implementing-User-Sign-In.md)** — architecture pivoted 2026-04-28: friend-code + inbox + push dropped, replaced by cloud-permalink hosting. PR 1 (Sign-in-with-Apple + Profile + Keychain) implemented; PR 2 reframed as three slices (iCloud entitlement + `CloudKitService`; cloud upload + permalink + receive; Delete-Account cascade), all three implemented locally. **Sign-in-with-Apple is no longer required for sharing** — only iCloud (system-level). Further pivot 2026-04-29: share permalinks switched from custom-scheme `llamascookbook://share/<id>` to HTTPS Universal Links `https://llamascookbook.pages.dev/r/<id>` so recipient-side Messages bubbles render rich previews — added `cloudflare-pages/` Pages site and Associated Domains entitlement.
- **[Share-Extension-Plan.md](./Share-Extension-Plan.md)** — PR 4 implemented. Separate `LlamasCookbookShareExtension` target. Transparent passthrough to main app via `llamascookbook://share-url/<base64url>` (URLs) or App Group `share-inbox/<uuid>.llamarecipe` + `llamascookbook://share-incoming/<uuid>` (files).
- **[SDK-Update-Plan.md](./SDK-Update-Plan.md)** — done. Build SDK iOS 26.x; `UIDesignRequiresCompatibility = true` keeps legacy chrome until aesthetic pass.

## TL;DR

Core CRUD is done end-to-end. Library, Detail, Editor, Cook Mode, Conversions, Sourdough, ShareLink export, Live Activity / Dynamic Island timer, A–Z scrub, drag-to-reorder steps, minimizable Cook Mode. Past parity with the archived RN app on every screen except Settings.

Recent feature pushes: photos (gallery + per-step ≤3), multi-recipe Cook Mode (1–4 active cooks), recipe-share Universal Links via Cloudflare Pages (rich preview bubbles in Messages on the recipient side).

Active queue: recipe sharing PR 3 + PR 4 (awaiting CI), user sign-in PR 1 + PR 2 slices 1–3 (awaiting CI + portal capability), per-cook `TimerLiveActivityRegistry`, aesthetic / typography pass. Recipe-share Universal Link flow shipped 2026-04-29 — diagnostic alert in `RecipeDetailView` is **temporary** and should be reverted to silent fall-through once end-to-end is verified.

## Capability map

| Capability | Where | Notes |
|---|---|---|
| Profile sheet | `Views/Profile/ProfileView.swift` + person-circle in `LibraryView` toolbar | Sign-in-with-Apple toggle. Identity in `App/UserAccount.swift`; `appleSub` + display name in Keychain via `Lib/KeychainStore.swift`. |
| Library list | `Views/Library/LibraryView.swift` | All / Favorites / tag chips. Long-press + context-menu Delete. A–Z scrub on right edge. Mascot watermark 6%. |
| Add / Import FAB | `LibraryView` | "New recipe" / "Import from text" (text paste + URL fetch). |
| Recipe Detail | `Views/Detail/RecipeDetailView.swift` | Sections, gallery + step thumbnails, share menu, sourdough chip, "Add to Cook Mode" green button when a cook is active. |
| Favorite toggle | `RecipeDetailView` | Heart toolbar, syncs `updatedAt`. |
| Export (text) | `Lib/RecipeExport.swift` | Plain-text bridge for non-app recipients. Last option in share menu. |
| Recipe sharing | `Lib/CloudKitService.swift` + `Lib/RecipeShare.swift` + `Views/Components/ShareSheet.swift` + `Views/Components/LlamaProgressIndicator.swift` | **Cloud-permalink Universal Link first, local URL fallback.** When `CKAccountStatus.available`, uploads to public DB as `RecipeShare` record; **photos travel as separate `CKAsset` fields** (`photo0`–`photo19`) so envelope JSON stays KB-scale. Sender shares `https://llamascookbook.pages.dev/r/<6char-id>` (Universal Link → Cloudflare Pages renders OG-tagged preview page → recipient sees rich bubble in Messages with actual recipe photo + title). Fallback when iCloud unavailable: `llamascookbook://recipe/v2/<base64url>` (lzma-compressed, photos stripped). `RecipeShareActivityItem` (in `ShareSheet.swift`) supplies `LPLinkMetadata` for the **sender's** share-sheet preview header (recipe title + llama icon) — recipient bubble preview comes from Cloudflare-hosted OG tags, not from inline metadata. Outbox in UserDefaults (`cloudShareOutbox.v1`) lets Delete-Account cascade-delete every record this device authored. Upload runs behind branded `LlamaProgressIndicator` overlay; **temporary diagnostic alert** surfaces underlying CloudKit errors instead of silent fall-through (revert once verified). |
| Recipe import (share) | `Views/Library/RecipeImportPreviewView.swift` + `RootView.onOpenURL` + `RootView.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` | Receiver flow for `.llamarecipe` files, `recipe/v<N>/` URLs, legacy `share/<id>` custom-scheme permalinks, AND HTTPS Universal Links (`https://<shareLinkHost>/r/<id>`). iOS 18 delivers Universal Links via either `.onOpenURL` or `.onContinueUserActivity` depending on launch state — both routes converge on `routeUniversalLink` → `fetchCloudShareRecord`. All paths converge on read-only mini-Detail with Save/Cancel; Save calls `RecipeShare.materialize` (rewrites UUIDs, stamps `sharedBy/sharedAt/sourceShareID`) then pushes recipient onto Detail via deferred `libraryPath.append`. |
| Share Extension | `ShareExtension/ShareViewController.swift` + `Sources/Shared/SharedContainer.swift` + `Sources/Shared/Base64URL.swift` | Transparent passthrough. URLs → `share-url/<base64url>` → `EditorCoordinator.startImport(prefilledURL:)`. Files → App Group → `share-incoming/<uuid>`. No SwiftData / `Recipe` types in extension. |
| Conversions | `Views/Detail/ConversionsView.swift` | Reference cards + live calculator (vol / weight / temp). |
| Sourdough calculator | `Views/Detail/SourdoughCalculatorView.swift` + `Lib/SourdoughCalculator.swift` | Surfaced for `sourdough` / `bread` / `baking` tags. |
| Recipe Editor | `Views/Editor/RecipeEditorView.swift` | Quick-add ingredients/steps, per-step timer toggle, drag-to-reorder, tags, special notes, photos. |
| Recipe Import (text) | `Views/Library/ImportRecipeView.swift` + `Lib/RecipeImporter.swift` | Live "Title / First ingredient / First Step" checklist. |
| Recipe Import (URL) | `Lib/RecipeURLImporter.swift` + `Lib/RecipeSchemaParser.swift` | JSON-LD → OG fallback, TikTok via oEmbed, Pinterest HTML. IG/FB blocked with paste-the-caption hint. |
| AI parser (hybrid) | `Lib/RecipeAIParser.swift` | iOS 26+ `FoundationModels` / `@Generable`. `pickBetterDraft` vs regex. Silent fallback. |
| Cook Mode | `Views/Cook/CookModeView.swift` | Two-phase, servings scaler, per-step check-off, floating timer banner, ready overlay, alarm. |
| Multi-cook pills | in `CookModeView` family | 1–4 cooks. Solid foreground pill, outline rest. |
| Cook Mode tuck-down | `RootView` cover detents | `[.large, .height(80)]`. |
| Timer w/ Live Activity | `Lib/TimerLiveActivityController.swift` + `WidgetExtension/TimerLiveActivity.swift` | Lock screen + Dynamic Island. Background ding via `TimerNotifications`. |
| Persistence (cook session) | `App/CookingSessionStore.swift` | `[CookingSessionState]` JSON in UserDefaults under `cooking-session-states.v2`; v1→v2 migration. Force-kill recoverable. |
| Editor coordinator | `App/EditorCoordinator.swift` | Sheet open/dirty gating with discard alert. |
| Appearance (accent) | `App/AppearanceSettings.swift` | User-customizable accent, persisted as hex. |

## Tech stack

| Layer | Choice |
|---|---|
| Language | Swift 5.10 |
| UI | SwiftUI, iOS 18+ deployment |
| State | `@State`, `@Observable`, SwiftData `@Model` |
| Persistence | SwiftData + UserDefaults (cook session, accent, owner profile, user-account aux) + Keychain (`appleSub` + display name) |
| Navigation | `NavigationStack` + `.sheet` + `.fullScreenCover`. Cook Mode and Editor sheets hoisted to `RootView`. |
| Notifications | `UNUserNotificationCenter` — per-cook ID `cooking-timer-<cookID>`. |
| Live Activity | `ActivityKit`. `TimerAttributes` cross-compiled into both targets via `Sources/Shared/`. |
| On-device AI | `FoundationModels` (iOS 26+, Apple Intelligence). Hard-gated. Regex pipeline is the universal floor. |
| Alarm sound | Bundled `timer-alarm.caf` (CI-generated by ffmpeg + afconvert), `AVAudioPlayer` loop. |
| Project file | XcodeGen — `ios-native/project.yml`, `.xcodeproj` gitignored, regenerated per CI run. |
| Build | GitHub Actions `macos-26` → `xcodebuild archive` → TestFlight via `xcrun altool`. Manual `workflow_dispatch`. |
| Build SDK | **iOS 26.x** (required by Apple's 2026-04-28 ITMS-90725 cutoff). |
| Min iOS | 18.0. |
| Devices | iPhone only, portrait. |

**What we don't use:** no UIKit views beyond two `appearance()` proxies (keyboard tint, PageControl dot color) and one `UIViewControllerRepresentable` (`ShareSheet`); no Combine; no SPM/CocoaPods packages; no Core Data.

## Data model

`Sources/Models/Recipe.swift` declares **five `@Model` classes**:

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
    @Relationship(.cascade) var photos: [RecipeStepPhoto] // up to 3 per step
    var sortedStepPhotos
}

@Model final class RecipePhoto     { var id, image: Data?, caption: String?, order, recipe }
@Model final class RecipeStepPhoto { var id, image: Data?, caption: String?, order, step }
```

`RecipeStep.image: Data?` is deprecated but kept declared so SwiftData lightweight migration doesn't drop it on existing TestFlight installs. Step photos go through the `photos` relationship; never write to `image`.

`DraftRecipe` / `DraftIngredient` / `DraftStep` / `DraftPhoto` (in `Models/DraftRecipe.swift`) are plain structs — see "Editor edits a draft" below.

## Repo + dev loop

iOS code lives in `ios-native/`. Repo root = docs + `outdated/rn-expo/` (archived; **do not modify**) + `cloudflare-pages/` (Pages site for recipe-share Universal Link previews; static + Functions, deployed by Cloudflare on every push to main, see `cloudflare-pages/README.md`).

**Dev loop is CI-only.** Developer is on Windows; Swift can't build iOS on Windows. Every build runs on `macos-26` via `.github/workflows/ios-native-ci.yml`, manual `workflow_dispatch`, ~15–25 min round-trip. Implications:
- No Xcode Previews. `#Preview` blocks compile but can't be visually inspected.
- Compile errors live in the `CompileSwift normal arm64` log section, *above* the "build commands failed" tail.
- Don't run `xcodegen` / `xcodebuild` / `pod` from this environment.
- Plan one CI cycle per syntactic mistake. Be deliberate.

**XcodeGen, not pbxproj.** `LlamasCookbookNative.xcodeproj` is gitignored and regenerated from `ios-native/project.yml`. Add files / source folders / build settings via `project.yml` — never hand-edit a pbxproj.

**Three targets ship from one archive:**
- `LlamasCookbookNative` — app, `com.llamascookbook.app`.
- `LlamasCookbookTimerWidget` — Live Activity, `com.llamascookbook.app.widget`.
- `LlamasCookbookShareExtension` — system share-sheet target, `com.llamascookbook.app.shareext`.

`CFBundleVersion = date -u +%s` (Unix timestamp) so re-runs never collide on TestFlight. `MARKETING_VERSION = 1.0.0` bumped manually in `project.yml`.

App target uses **explicit Info.plist** (`Resources/AppInfo.plist`, `GENERATE_INFOPLIST_FILE: NO`) because `CFBundleURLTypes` and `UIDesignRequiresCompatibility` can't be expressed via `INFOPLIST_KEY_*`.

## Source layout (under `ios-native/Sources/`)

- **`App/`** — `@main` (`LlamasCookbookApp.swift` + `AppDelegate` for foreground notifications + deep-link routing) and coordinators hung off `RootView`:
  - `CookingSession` (multi-cook state — `activeCooks`, `foregroundedCookID`, `pendingRestoration`)
  - `CookingSessionState` + `CookingSessionStore` (Codable + UserDefaults, v1→v2 migration)
  - `EditorCoordinator` (single-sheet gating with dirty-flag discard alert)
  - `NavigationContext` (current Detail's `Recipe.id` — read by pills bar)
  - `AppearanceSettings` (accent hex)
  - `OwnerProfile` (sender display name; read directly at envelope-build time, empty == no provenance)
  - `UserAccount` (Sign-in-with-Apple identity; Keychain-backed `appleSub` + display name; `refreshCredentialState()` from cold-launch task)
- **`Models/`** — five `@Model` classes; `DraftRecipe.swift` holds editor draft structs + `toDraft()` / `apply(_:)` bridge.
- **`Lib/`** — pure logic, no SwiftUI views:
  - Formatting: `Quantity` (parse / format / scale + measurable-fraction snap, `ClockFormat.mmss`, `StringCase`), `Plural` (unit pluralization + `needsConnector`), `IngredientDisplay`
  - Import: `RecipeImporter` (text paste, three-fallback step splitter), `RecipeURLImporter`, `RecipeSchemaParser`, `RecipeAIParser` (iOS 26+, quality gate)
  - Recipe ops: `RecipeExport`, `SourdoughCalculator`, `TagPresets`
  - Timer + audio: `AlarmPlayer`, `TimerNotifications` (per-cook IDs), `TimerLiveActivityController` (per-instance ActivityKit wrapper)
  - Photos: `ImageProcessing` (`CGImageSource`/`CGImageDestination` resize + format-preserving re-encode + bytes guard, `Task.detached`)
  - Auth: `KeychainStore` (`SecItem*` wrapper, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), `SignInWithAppleService` (only place that imports `AuthenticationServices`)
  - Cloud: `CloudKitService` (wraps `CKContainer(identifier: "iCloud.com.llamascookbook.app").publicCloudDatabase`; `accountStatus()`, `uploadShare`, `fetchShare`, `deleteShare`, outbox, `deleteAuthoredShares`; record IDs are 6-char `[A-Z2-9]` minus I/O/0/1)
  - UI utilities: `Haptics`, `KeyboardDismiss.focusedNumeric`, `Shake`
- **`Shared/`** — cross-target Swift, Foundation only (no SwiftData, no SwiftUI). `TimerAttributes` (main app + widget). `SharedContainer` (App Group `group.com.llamascookbook.app`). `Base64URL` (URL-safe base64).
- **`Theme/`** — `AppColor` (cream/terracotta + `.onAccent` semantic token), `AppFont` (system serif placeholder), `AppSpacing` (xs=4 / sm=8 / md=12 / lg=16 / xl=24 / xxl=32 / xxxl=48), `AppRadius` (sm=8 / md=12 / lg=16 / xl=24), `ColorHex`.
- **`Views/`** — one folder per feature area:
  - `Components/` — `LlamaLogo` (bitmap from `Assets.xcassets/LlamaLogo.imageset` + accent-driven drop shadow), `LlamaProgressIndicator` (branded indeterminate progress: halo fills bottom-to-top via `TimelineView`), `EmptyLibraryView`, `RecipeImageView` (NSCache-backed), `PhotoCarouselView`, `PhotoReorderView` (3-column tile-grid drag-and-drop), `AccentColorPicker`, `ShareSheet` (UIActivityViewController wrapper)
  - `Library/` — `LibraryView`, `RecipeCardView`, `ImportRecipeView`, `ImportHelpView`, `RecipeImportPreviewView`
  - `Detail/` — `RecipeDetailView`, `ConversionsView`, `SourdoughCalculatorView`
  - `Editor/` — `RecipeEditorView`, `IngredientQuickAdd`, `IngredientRowEditor`, `StepQuickAdd`, `StepRowEditor`, `TagInputView`, `SpecialNotesEditor`, `PhotoToggleButton`, `Chips/{QuantityChips,UnitChips}`
  - `Cook/` — `CookModeView` (single-cook UI; presented per-foregrounded cook via `.id(cookID)`)
  - `Profile/` — `ProfileView`

**Reach-for helpers** (don't roll local versions):
- Sort: `Recipe.sortedIngredients` / `.sortedSteps` / `.sortedPhotos`, `RecipeStep.sortedStepPhotos`. Never `.sorted { $0.order < $1.order }` inline.
- Display: `Ingredient.display(scaledBy:)` → `Display { quantity, unit, takesOf, name, measure, fullLine }`.
- Quantity: `Quantity.parse / format / scale / displayFormat / splitForChips / combine`.
- Plural: `Plural.unit(_, for:)` / `.needsConnector(_)`.
- Photos: `RecipeImageView` (rendering), `PhotoCarouselView` + `PhotoReorderView` (edit), `ImageProcessing` (resize + bytes guard).
- UI: `FlowRow`, `shake(count:)`, `focusedNumeric(_, when:)`. House list-row transition: `.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity.combined(with: .scale(scale: 0.9)))` + `.spring(response: 0.42, dampingFraction: 0.82)`.

## Architectural patterns worth knowing

**Editor edits a draft, not the model.** `Recipe` is a SwiftData `@Model` (reference type), so direct edits would auto-persist on every keystroke. Editor snapshots into `DraftRecipe` on open and only calls `Recipe.apply(_:)` on Save. **Critical:** `apply(_:)` does `ingredients.removeAll()` + `steps.removeAll()` + `photos.removeAll()` + step photos rebuild on every save, cascade-deleting external-storage sidecars. **Bytes must be carried through the draft** (`DraftPhoto.image: Data?`, `DraftStep.images: [Data]`) or every save silently loses every image.

**Coordinators above the NavigationStack.** `CookingSession`, `EditorCoordinator`, `NavigationContext`, `AppearanceSettings` live as `@State` in `RootView`, propagated via `.environment(...)`. Cook Mode `.fullScreenCover` and editor `.sheet` are hoisted to RootView so they survive Library→Detail nav. **Re-inject environments explicitly into covers** — `@Observable` values can drop out across cover boundaries.

**Multi-cook session shape.** `CookingSession.activeCooks: [ActiveCook]` (private(set)) holds 0–4. Mutations: `start` (replaces), `addParallel` (additive, dedups by `recipe.id`, refuses over-cap), `remove(cookID:)`, `foreground(cookID:)`, `minimize`, `resume`, `restore`. `ActiveCook.id` is distinct from `recipe.id` (model allows duplicates; UI v1 doesn't). **`CookModeView` is recreated on every cook switch** via `.id(cookID)` in RootView, so `@State` for phase/strikes/timer seeds fresh from `pendingRestoration`.

**Per-cook persistence.** Every meaningful state change in `CookModeView` calls `persistSnapshot()` → `CookingSession.persistForegroundedSnapshot(_:)` → `CookingSessionStore.save(...)` (full `[CookingSessionState]` JSON to UserDefaults under `cooking-session-states.v2`). v1→v2 migration runs once on first load. Force-kill mid-cook recoverable: expired timers surface ready overlay rather than auto-restarting alarm (re-opening to a screaming app would be hostile).

**Timer notification IDs are per-cook.** `TimerNotifications.identifier(for: cookID:)` produces `cooking-timer-<uuid>`. `cancelAll` also wipes legacy single-id `"cooking-timer"` for clean upgrades. `userInfo` carries `recipeID` + `cookID`; `AppDelegate.didReceive` routes via `llamascookbook://cook/<recipeID>`; widget bakes same URL into `widgetURL`.

**Multi-cook timer hole (outstanding).** `TimerLiveActivityController` is per-`CookModeView`, not per-session. When two cooks have running timers simultaneously, only the foregrounded cook's `CookModeView` exists, so the backgrounded cook's Live Activity is unmanaged. iOS keeps ticking it (because `endDate` drives countdown locally), but extending/cancelling from foreground won't reach it. Planned fix: `TimerLiveActivityRegistry` keyed by `cookID`.

**Quantity strings, not numbers.** `Ingredient.quantity` is `String?` (`"2 & 1/2"`) so mixed fractions survive round-trip. `Lib/Quantity.swift` parses, scales, and formats — snapping to measurable fractions only (no `0.42 tsp`). Both `&` and space-separated input accepted; `&` is canonical on output.

**Per-step timer flag.** `RecipeStep.needsTimer: Bool` is the source of truth. When true, `CookModeView.timerSeconds(for:)` extracts duration from step text first (range regex takes the *smaller* number), falls back to `recipe.cookTimeMinutes`, then 5-min default. Keyword extractor labels the chip — doesn't gate visibility.

**Special notes have four placement slots.** `Recipe.prefaceNote` / `epilogueNote` / `generalNote` (recipe-level) + `RecipeStep.specialNote` (per-step). `SpecialNotesEditor` enforces "one per slot" at the picker.

**Detail-quick-edit vs. Editor-full-edit gallery.** Detail mutates `recipe.photos` directly through `append(...)` and `modelContext.delete(...)` — **persistence is immediate**, no Save. Editor mutates `draft.photos`, commits on Save through `apply(_:)` — Cancel discards. Both use `PhotoCarouselView` with closure callbacks. **Reorder follows the same dichotomy:** Detail rewrites every `RecipePhoto.order` on the live `@Model` (nil-image rows pushed past visible tail); Editor reseats `draft.photos` and waits for Save. Step-photo reorder uses `step.images.move(fromOffsets:toOffset:)` directly.

**Single keyboard `Done` for numeric fields.** A single `@FocusState private var isNumericFocused: Bool` lives in `RecipeEditorView`, threaded down via binding; `focusedNumeric(_, when:)` attaches it only to numeric keyboards. Single root `ToolbarItemGroup(placement: .keyboard)` lights up Done when `isNumericFocused == true`. Add new numeric fields with this helper, not their own toolbar.

**`placement: .keyboard` is unreliable inside `TabView(.page)` in a sheet — use `safeAreaInset(edge: .bottom)`.** The keyboard toolbar misses first focus and intermittently appears later. Deterministic fix in `PhotoCarouselView.captionKeyboardAccessory`: custom Done bar in `safeAreaInset(edge: .bottom)`, gated by lifted `@FocusState<Int?>`. iOS keyboard avoidance lifts the inset above the keyboard automatically.

**SF Symbols + SwiftUI primitives only.** No UIKit beyond `UIViewRepresentable` last-resort, no Combine, no SPM/CocoaPods. Brand logo is a bitmap from `Assets.xcassets/LlamaLogo.imageset`; PNG body color is baked in, only drop shadow is tintable (tracks `appearance.accentColor`). Three deliberate UIKit reaches: global tint (`UIView.appearance().tintColor`, kept in sync with the user's accent by `AppearanceSettings.applyToUIKit()` so the keyboard Return key, navigation back chevron, and selection handles follow the picker), PageControl dot color (`UIPageControl.appearance()`), `ShareSheet` wraps `UIActivityViewController` (SwiftUI `ShareLink` can't be triggered programmatically — async cloud upload needs to complete before the sheet presents).

**Recipe-share Universal Links are HTTPS, not custom-scheme.** Sender mints `https://llamascookbook.pages.dev/r/<recordName>` (constants in `CloudKitService.shareLinkHost` + `shareLinkPathPrefix`). Reasons: (1) iMessage refuses to render rich link previews for `customscheme://` URLs as anti-spoofing — bubble shows bare URL text. (2) HTTPS routes to a real web page (Cloudflare Pages) with proper OG tags → recipient bubble shows recipe photo + title. (3) Universal Links open the app directly when installed (validated against `apple-app-site-association` at the host) and gracefully fall back to a friendly Cloudflare-rendered "Get the app" page otherwise. Receiving side handles BOTH `.onOpenURL` (HTTPS branch) AND `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` because iOS 18 delivers Universal Links to either depending on cold/warm launch state — duplicate calls no-op since `pendingShareImport` resolves to the same envelope. **Share-sheet preview header** (sender's screen) uses `RecipeShareActivityItem` returning `LPLinkMetadata` from `activityViewControllerLinkMetadata`; **`itemForActivityType` always returns the raw URL** so Messages/Mail can put it in the body — returning `LPLinkMetadata` there leaves an empty Messages compose, easy to re-introduce by mistake. Recipient bubble preview comes from Cloudflare's OG tags, NOT from inline `LPLinkMetadata`.

## UX principles (still binding)

1. **One-thumb operable.** Primary actions in bottom half or toolbar.
2. **Input friction = death.** Quick-add, visible add buttons, Return-submits-and-refocuses, one conditional Done.
3. **Cook Mode is its own world.** Warmer bg, larger type (`ingredientCook`), slower pacing.
4. **Gestures have visible fallbacks.** Long-press Delete also has context-menu Delete.
5. **Generous whitespace.**
6. **Silent save.** Only warn on Cancel when there's real loss.
7. **Forgiving.** Deletions confirmed. Timer cancel is destructive-styled.

**Canonical interaction details (don't regress):**
- Quantity chips: two rows (wholes bigger/bolder, fractions smaller). Only measurable fractions — no 3/8 · 5/8 · 7/8. Tapping active deselects.
- Ampersand fractions: `2 & 1/2 cups` on display. Parser also accepts `2 1/2`.
- Detail ingredient row: `•  2 & 1/2 cups  —  flour`. Quantity in accent semibold monospaced, em-dash, name in textPrimary.
- Per-step timer flag: clock glyph on step quick-add and row editor.
- Floating timer banner pinned between phase header and scroll. Tap opens running-timer sheet with 1–60 min wheel.
- Ready overlay: full-screen terracotta with bell + `"{Label} timer ready!"`, embedded MinutePicker + filled Extend (preserves `timerStepId`), outlined Stop. Vibration + haptic warning every 1.2s until Stop/Extend.

## Signing & CI gotchas

- **Bundle ids:** `com.llamascookbook.app`, `.widget`, `.shareext`. **Team:** `GYFN949Q5E`. **ASC app id:** `6762527184`.
- **CFBundleVersion** = Unix timestamp; **MARKETING_VERSION** = `1.0.0` (bump in `project.yml`).
- **`Resources/PrivacyInfo.xcprivacy`** is required (auto-rejection without it since 2024-05-01). Declares `NSPrivacyAccessedAPICategoryUserDefaults` (CA92.1) + `NSPrivacyAccessedAPICategoryFileTimestamp` (C617.1, for `SharedContainer.sweepShareInbox`). `NSPrivacyTracking = false`. If a future feature touches a new required-reason API, declare it here BEFORE next TestFlight upload.
- **GitHub Secrets:** `IOS_DIST_CERT_P12_BASE64`/`_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`, `IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64`, `APPSTORE_API_KEY_P8_BASE64`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`.

These are intentional — don't "clean up" without checking comments in `ios-native-ci.yml`:

- **`macos-26` runner pinned explicitly.** `macos-latest` resolves to macOS 15 / Xcode 16, fails ITMS-90725.
- **Xcode 26 selection prefers stable over beta.** Beta SDKs ship a simulator-runtime mismatch that breaks `actool` during archive even on device builds. Picker globs `Xcode_26*.app`, filters `beta`, sorts by version, falls back to beta with `::warning::` only if no stable. **Don't hardcode the app name** — Apple ships point releases (26.0.1, 26.1.1, 26.4.1). Naive `sort -V | tail -1` picks beta because `26.5_beta > 26.4.1`.
- **`DEVELOPER_DIR` written to `$GITHUB_ENV`** as belt-and-suspenders alongside `xcode-select -s`. Runner image pre-sets `DEVELOPER_DIR` in shell profile pointing at default Xcode (currently beta), silently overrides `xcode-select`.
- **`xcodebuild -downloadPlatform iOS`** runs after `-runFirstLaunch`; `actool` thinning cross-checks simulator runtimes even on device builds. Includes 3-attempt retry loop because Apple's content endpoint is flaky from CI.
- **App icon PNGs sanitized at CI** by ImageMagick with `-alpha remove -alpha off -colorspace sRGB -define png:color-type=2`. Xcode 26 hard-rejects RGBA app icons. Empty appiconset fails fast.
- **Timer alarm `.caf` generated at CI** by ffmpeg + afconvert. `optional: true` in `project.yml`; app falls back to `UNNotificationSound.default`.
- **`UIDesignRequiresCompatibility = true`** in `Resources/AppInfo.plist` keeps legacy chrome rendering on iOS 26 (Liquid Glass opt-out). Temporary — Apple has signaled removal in iOS 27.
- **Share Extension provisioning** — App Group entitlement (`group.com.llamascookbook.app`) MUST be on BOTH main app and extension profiles. After enabling App Groups on a target's App ID, the matching profile must be regenerated (entitlement is baked at issue time). Three string literals must agree: `SharedContainer.appGroupID`, the entitlements files in `Resources/` and `ShareExtension/`, and the App Group identifier in the Developer Portal.
- **`LSSupportsOpeningDocumentsInPlace = <false/>`** in `AppInfo.plist` is required because we declare `CFBundleDocumentTypes` (for `.llamarecipe`). Without it, App Store Connect emits ITMS-90737 warning. `false` is the right semantic: we copy into Inbox, materialize, and never touch the source again.
- **Sign-in-with-Apple entitlement** — `com.apple.developer.applesignin = ["Default"]` in `Resources/LlamasCookbook.entitlements`. Capability MUST also be enabled on main App ID in Developer Portal AND profile regenerated. `IOS_PROVISIONING_PROFILE_BASE64` needs the regenerated profile.
- **iCloud / CloudKit entitlement** — `com.apple.developer.icloud-container-identifiers = ["iCloud.com.llamascookbook.app"]` and `com.apple.developer.icloud-services = ["CloudKit"]`. Capability MUST be enabled on App ID + container created in portal + profile regenerated. `RecipeShare` record type fields: `envelope` (Asset), `senderDisplayName` (String), `recipeTitle` (String), `createdAt` (Date/Time, queryable + sortable), `photo0`–`photo19` (Asset, optional). Indexes: `createdAt` queryable + sortable; `createdUserRecordName` (a.k.a. `___createdBy` / `creatorUserRecordID`) queryable for the Delete-Account cascade. **Schema must be deployed Dev→Prod before any TestFlight build that exercises cloud-share** — the canonical "works in dev, fails in TestFlight" CloudKit gotcha. **`photo0`–`photo19` fields auto-create in dev only when a record actually carries that index, so dev's auto-discovered schema is usually missing most of them; add them MANUALLY in the dev schema before deploying to prod, or production uploads throw "cannot create or modify field photoN in record RecipeShare"** (verified failure mode 2026-04-29). Container identifier shared across three places (entitlement, `CloudKitService.containerID`, portal config) — match exactly.
- **Associated Domains entitlement** — `com.apple.developer.associated-domains = ["applinks:llamascookbook.pages.dev"]` in `Resources/LlamasCookbook.entitlements`. Capability MUST be enabled on App ID in Developer Portal AND profile regenerated AND `IOS_PROVISIONING_PROFILE_BASE64` GitHub Secret updated. Without all four (entitlement file, portal capability, regenerated profile, fresh secret), iOS silently strips the entitlement at sign-time and Universal Links open in Safari instead of the app. Domain string in entitlement MUST match `CloudKitService.shareLinkHost` and the `applinks:` host configured in `cloudflare-pages/.well-known/apple-app-site-association` (declares `GYFN949Q5E.com.llamascookbook.app` against `/r/*`). Three places, one host string, no drift.
- **Cloudflare Pages dependency** — recipe-share previews depend on `https://llamascookbook.pages.dev` being live. Repo's `cloudflare-pages/` folder is the deployment source (Pages auto-builds on push to main; Root directory = `cloudflare-pages`). Required environment variables on the Cloudflare project (Production AND Preview): `CLOUDKIT_CONTAINER_ID`, `CLOUDKIT_KEY_ID`, `CLOUDKIT_PRIVATE_KEY` (Secret/encrypted), `CLOUDKIT_ENVIRONMENT=production`. `CLOUDKIT_PRIVATE_KEY` is an ECDSA P-256 PEM from CloudKit Console → Server-to-Server Keys (read-only public DB scope is enough); the Worker signs each CloudKit Web Services request with ECDSA-SHA256 in `cloudflare-pages/lib/cloudkit.js`. Worker reads `recipeTitle` + `photo0` from the `RecipeShare` record, renders OG-tagged HTML at `/r/<id>`, proxies the photo at `/img/<id>`. Static `_headers` file forces `Content-Type: application/json` on the AASA file (Apple is strict; without it, iOS rejects the AASA and Universal Links break). Server-to-Server key revocation = preview pages break (graceful fallback to generic "A Recipe" + llama icon, but recipient bubble loses per-recipe branding); rotate via CloudKit Console + update Cloudflare env var.
- **SwiftData `cloudKitDatabase: .none` opt-out** — `LlamasCookbookApp.makeModelContainer()` builds a `ModelConfiguration` with `cloudKitDatabase: .none` explicitly. Without this, SwiftData's default `.automatic` detects the iCloud entitlement and tries to back the container with CloudKit sync — which fails on our schema (`.cascade` `@Relationship` rules + non-optional properties without defaults). Failure mode is silent: container falls back to in-memory, recipes appear to save but vanish on relaunch. Discovered 2026-04-28; explicit `.none` is mandatory. **Don't switch to the `.modelContainer(for:)` modifier** — that initializer doesn't expose `cloudKitDatabase`.

Watch points: `Print toolchain` step's `iphoneos --show-sdk-version` is the canary — if it drops below 26.x, ITMS-90725 returns.

## Known limitations / deferred

- **Multi-cook timer registry** — see "Multi-cook timer hole" above.
- **Settings screen** — stub. Only accent color wired (via `AppearanceSettings`).
- **Keep-awake during Cook Mode** — `UIApplication.shared.isIdleTimerDisabled = true` not yet wired.
- **iPad** — iPhone only.
- **Live Activity App Intents** — in-island +1/−1/cancel deferred.
- **Custom type** — Fraunces / Inter not bundled; `AppFont` uses system serif.
- **iCloud sync for SwiftData** — not configured (intentional `.none` opt-out, see above).
- **`RecipeStep.image: Data?`** — deprecated, kept for migration.
- **Liquid Glass** — must adopt before iOS 27 SDK becomes mandatory and `UIDesignRequiresCompatibility` is removed.
- **Cloud-share diagnostic alert** — `RecipeDetailView.cloudShareError` + the "Cloud share diagnostic" alert are temporary. Surfaces underlying `CKError` / account-status string instead of silent fall-through to the local URL form. Revert `tryShareViaCloud` catch + `shareViaPreferredTransport` guard back to silent fall-through once recipient-side Universal Link previews are confirmed working end-to-end.
- **Cloudflare Pages preview is generic without per-recipe data** — falls back to "A Recipe" + llama icon if CloudKit lookup fails (env vars missing, network blip, record deleted, etc.). Working as intended; logs to Cloudflare's request log.

## What's next

1. Recipe sharing PR 3 + PR 4 land (CI verification).
2. User sign-in PR 1 + PR 2 slices 1–3 land (CI + portal capability).
3. Verify Universal Link share end-to-end on real devices, then revert the temporary diagnostic alert in `RecipeDetailView` back to silent fall-through.
4. Per-cook `TimerLiveActivityRegistry` (lift controller out of `CookModeView`, key by `cookID`).
5. Aesthetic / typography pass — Fraunces + Inter, real app icon, richer Library cards, Detail rhythm, Cook Mode differentiation.
6. Liquid Glass adoption.

Queued: dark mode (palette is sRGB-explicit, needs semantic light/dark tokens), Settings screen, iPad, App Intents on Live Activity.

## Working with this documentation

- **CLAUDE.md is the document the user keeps current.** When you change product behavior, update this file.
- **Code wins over docs.** When memory or docs disagree with code, code wins, and update the doc.
- Feature plan docs decay after implementation; before quoting them, grep code for the type / function they reference.
