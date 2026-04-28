# CLAUDE.md

This file is the single source of truth for the current state of the app. When this file disagrees with PROJECT.md or any feature plan doc, this file wins. When it disagrees with the code, the code wins — update this file. Last refreshed 2026-04-28 (sign-in PR 1 + share-link rework integrated).

## Source of truth — read in this order

1. **CLAUDE.md** (this file) — current implementation snapshot, architectural patterns, CI gotchas, what's done / what's deferred. Loaded automatically every session.
2. **[PROJECT.md](./PROJECT.md)** — stable project reference: tech-stack rationale, signing material, dev workflow. The "current status" sections are stale; this file supersedes them.
3. **[llamas-cookbook-plan.md](./llamas-cookbook-plan.md)** — original product spec. Vision / JTBD / UX principles still authoritative.
4. **[ROADMAP.md](./ROADMAP.md)** — deferred work + the Live Activity portal-setup checklist.
5. **STATE.md** — **archived 2026-04-27**, content folded into this file. Kept on disk for historical reference; do not update.

Feature design docs are *plans*, not specs — verify against the code before quoting them:

- **[Multi-Recipe-Cook-Mode.md](./Multi-Recipe-Cook-Mode.md)** — **mostly implemented** (PR 1 + PR 2 landed). `CookingSession.activeCooks` array, `addParallel`, `remove(cookID:)`, `foreground(cookID:)`, multi-cook pills bar, "Add to Cook Mode" green button on Detail, v1→v2 persistence migration. **Not yet done:** per-cook timer registry — `TimerLiveActivityController` is still a single instance per `CookModeView`, so two parallel timers will collide on Live Activity / alarm (see Audit notes when extending).
- **[Photo-Capability.md](./Photo-Capability.md)** — **fully implemented** beyond the plan: gallery (`Recipe.photos` → `RecipePhoto`), per-step gallery up to 3 photos (`RecipeStep.photos` → `RecipeStepPhoto`, **not** the original `RecipeStep.image: Data?` slot — that field is deprecated and lingers for migration only), shared `PhotoCarouselView` + `RecipeImageView` + `ImageProcessing` infra. Carousel has add-confirmation alert and a 350ms picker-dismiss delay (workaround for an iOS 18 sheet-in-sheet alert race).
- **[Recipe-Sharing.md](./Recipe-Sharing.md)** — **PR 1 + PR 2 + PR 3 implemented, all four PRs of recipe-sharing in flight; share-menu reworked 2026-04-28 so URL-deep-link is the only Llamas-Cookbook-aware share form, lzma-compressed and v2-prefixed (~60% URL shrink), and Save in import preview pushes the recipient straight to Detail**. Adds app-to-app recipe sharing via a `llamascookbook://recipe/v2/<base64url-of-lzma(JSON)>` deep link — works in Messages / Mail / chat apps that respect custom schemes, photos stripped via `LCRecipeShareV1.withoutPhotos()` before encoding. The `.llamarecipe` file form (UTType + base64-photo JSON envelope) is still wired for AirDrop-incoming (`onOpenURL` file-URL branch) but the outbound user-facing menu entry was dropped because `.llamarecipe` attachments don't reliably open from Messages. Full-fidelity photo cloud transport designed in but queued behind PR 2 of [Implementing-User-Sign-In.md](./Implementing-User-Sign-In.md). **Done:** schema (`LCRecipeShareV1`), encode/decode/materialize (`Lib/RecipeShare.swift`), `OwnerProfile` Observable, provenance fields on `Recipe`, UTType + `LSSupportsOpeningDocumentsInPlace` Plist additions (PR 1); Detail share menu with `ShareSheet` UIActivityViewController wrapper + first-share name prompt + 350ms post-alert delay (PR 2); `RootView.onOpenURL` branches for `recipe` URL scheme + `.llamarecipe` file URLs, `RecipeImportPreviewView` (read-only mini-Detail with Save/Cancel that drives `RecipeShare.materialize` on save), provenance line in `RecipeDetailView` rendering "Originally shared by Lorenzo · Apr 27" below the title when `Recipe.sharedBy` is non-nil (PR 3). PR 4 (Share Extension) implemented in parallel — see Share-Extension-Plan.md.
- **[Implementing-User-Sign-In.md](./Implementing-User-Sign-In.md)** — **PR 1 implemented, awaiting CI verification + portal setup**. Sign-in-with-Apple identity primitive, Profile sheet, Keychain-backed `appleSub` persistence. **Done:** entitlement (`com.apple.developer.applesignin`), `Lib/KeychainStore.swift`, `Lib/SignInWithAppleService.swift`, `App/UserAccount.swift` Observable (signedOut / signingIn / signedIn(UserIdentity) / signInFailed states), `Views/Profile/ProfileView.swift` with `SignInWithAppleButton` (signed-out) + display-name editor + Sign Out + Delete Account confirmation (signed-in), person-circle toolbar button on `LibraryView`, RootView cold-launch revocation check via `userAccount.refreshCredentialState()`. **Deferred:** PR 2 wires CloudKit container + `User`/`RecipeShare` records + Send flow; PR 3 inbox + push subscription; PR 4 friend-code sharing + privacy labels. Apple Developer Portal must enable Sign-in-with-Apple capability on the main App ID + regenerate the provisioning profile before the build will sign — see Implementing-User-Sign-In.md §10.
- **[Share-Extension-Plan.md](./Share-Extension-Plan.md)** — **PR 4 implemented, awaiting CI verification**. Adds a separate `LlamasCookbookShareExtension` app-extension target (`com.llamascookbook.app.shareext`) so Llamas Cookbook appears as a destination in iOS share sheets across all apps (Safari, Files, Mail, Reddit, etc.). Activation rule accepts `public.url` and `com.llamascookbook.recipe` UTIs. Architecture is **transparent passthrough** — `ShareViewController` reads the NSItemProvider, hands off to the main app via deep link (URLs encoded as `llamascookbook://share-url/<base64url>`, `.llamarecipe` files written to an App Group shared container at `group.com.llamascookbook.app/share-inbox/<uuid>.llamarecipe` and handed off via `llamascookbook://share-incoming/<uuid>`). No SwiftData in the extension, no duplicated parsers. New `Sources/Shared/SharedContainer.swift` + `Sources/Shared/Base64URL.swift` are cross-target helpers. Apple Developer Portal setup (App Group + new App ID + new provisioning profile) is required before the build will sign — see Share-Extension-Plan.md §8.
- **[SDK-Update-Plan.md](./SDK-Update-Plan.md)** — done. Build SDK is iOS 26.x; `UIDesignRequiresCompatibility = true` keeps the legacy chrome until the aesthetic pass adopts Liquid Glass.

## TL;DR — where the app stands

Core CRUD is done end-to-end. Library, Detail, Editor, Cook Mode, Conversions, Sourdough calculator, ShareLink export, Live Activity / Dynamic Island timer, A–Z scrub, drag-to-reorder steps, minimizable Cook Mode (tucks to a small detent while the user browses). Past parity with the archived RN app on every screen except Settings (still a stub).

Two recent feature pushes have landed:
- **Photos** — gallery + per-step photos (up to 3 per step), shared rendering/carousel infra.
- **Multi-recipe Cook Mode** — `CookingSession.activeCooks` (1–4), pills bar, persistence v1→v2 migration. Outstanding hole: per-cook timer registry (see §"Multi-cook timer hole" below).

Active queue: recipe sharing between users (PR 1 + PR 2 shipped — schema, UTType, Detail share menu; PR 3 + PR 4 implemented — inbound `onOpenURL` + Import Preview + provenance line + Share Extension target with App Group handoff, all awaiting CI verification), user sign-in (PR 1 implemented — Sign-in-with-Apple + Profile sheet + Keychain identity, awaiting CI + portal capability), then per-cook `TimerLiveActivityRegistry`, then the aesthetic / typography pass.

## Capability map — one line per surface

| Capability | Where it lives | Notes |
|---|---|---|
| Profile sheet | `Views/Profile/ProfileView.swift` + person-circle in `LibraryView` toolbar | Sign-in-with-Apple toggle (signed-out: SwiftUI `SignInWithAppleButton` + explainer; signed-in: editable display name, friend-code "Coming soon" placeholder, friends-list placeholder, Sign Out, Delete Account confirm). Identity flows through `App/UserAccount.swift` Observable; `appleSub` + display name persist in Keychain via `Lib/KeychainStore.swift` so they survive reinstall. |
| Library list | `Views/Library/LibraryView.swift` | All / Favorites / one chip per tag. Long-press + context-menu Delete. |
| A–Z letter scrub | `LibraryView` right-edge strip | Tap or drag to jump. Dimmed letters route to next populated. |
| Mascot watermark | `LibraryView` | 6% opacity llama pinned behind the list. |
| Add / Import FAB | `LibraryView` | Menu: "New recipe" · "Import from text" (handles URL fetch and text paste). |
| Recipe Detail | `Views/Detail/RecipeDetailView.swift` | Sections, gallery + step-photo thumbnails, share menu (link / text), sourdough chip, "Add to Cook Mode" green button when a cook is already active. |
| Favorite toggle | `RecipeDetailView` | Heart toolbar, syncs `updatedAt`. |
| Export (text) | `Lib/RecipeExport.swift` + share menu | Plain-text out — Notes, Messages, Mail, AirDrop. Second / last option in the share menu (bridge for recipients without the app); the URL-link default precedes it. |
| Recipe sharing (link) | `Lib/RecipeShare.swift` + `Views/Components/ShareSheet.swift` | **Link is the only Llamas-Cookbook-aware share form** — `llamascookbook://recipe/v2/<base64url>` deep link, always available, photos stripped via `LCRecipeShareV1.withoutPhotos()` and JSON lzma-compressed before base64url so it slides well under `RecipeShare.urlByteCeiling`. Tapping the link in Messages / Mail opens the recipient's app and lands them in `RecipeImportPreviewView`. The decoder accepts both v1 (legacy uncompressed) and v2 (current) URL paths. The `.llamarecipe` file form (`encodeFile` / `materialize` from a file URL) is still wired for AirDrop / Files / Mail incoming, but the user-facing "Share with photos" menu entry was removed 2026-04-28 — recipient-side `.llamarecipe` attachment opening from Messages turned out to be unreliable, and full-fidelity photo cloud-transport is queued behind PR 2 of [Implementing-User-Sign-In.md](./Implementing-User-Sign-In.md). State-machine driven: first-share name prompt → `UIActivityViewController` via `ShareSheet`. |
| Recipe import (share) | `Views/Library/RecipeImportPreviewView.swift` + `RootView.onOpenURL` branches | Receiver flow for incoming `.llamarecipe` files (AirDrop / Files / Mail) and `llamascookbook://recipe/v<N>/<base64url>` chat links (decoder handles both v1 uncompressed and v2 lzma-compressed paths). Read-only mini-Detail preview with Save/Cancel; Save calls `RecipeShare.materialize` (rewrites UUIDs, stamps `sharedBy/sharedAt/sourceShareID`, resolves title collisions, re-runs photos through `ImageProcessing`) then invokes `onSaved(recipe)` — RootView captures the new `Recipe`, dismisses the sheet, and pushes the recipient straight onto Detail via `libraryPath.append(recipe)` (`NavigationPath` bound to RootView's `NavigationStack`, push deferred ~350ms so it doesn't race the sheet's dismiss animation). Provenance line renders in `RecipeDetailView` below the title and is sticky through editor saves (`Recipe.apply(_:)` leaves it untouched). |
| Share Extension | `ShareExtension/ShareViewController.swift` + `Sources/Shared/SharedContainer.swift` + `Sources/Shared/Base64URL.swift` | Separate `app-extension` target (`com.llamascookbook.app.shareext`) — appears as a destination in OTHER apps' share sheets (Safari, Files, Reddit, Mail, etc.). Accepts URLs and `.llamarecipe` files via `NSExtensionActivationRule`. Transparent passthrough: encodes a deep link and calls `extensionContext.open(_:)` to launch the main app. URLs go through `llamascookbook://share-url/<base64url>` → `EditorCoordinator.startImport(prefilledURL:)` → `ImportRecipeView` auto-fetches. Files written to App Group at `group.com.llamascookbook.app/share-inbox/<uuid>.llamarecipe` + handed off via `llamascookbook://share-incoming/<uuid>` → main app reads, decodes, presents Import Preview. No SwiftData / `Recipe` types in the extension. |
| Conversions | `Views/Detail/ConversionsView.swift` | Reference cards + live calculator (vol / weight / temp, cross-category guard). |
| Sourdough calculator | `Views/Detail/SourdoughCalculatorView.swift` + `Lib/SourdoughCalculator.swift` | Hydration / starter math. Surfaced when recipe tagged `sourdough` / `bread` / `baking`. |
| Recipe Editor | `Views/Editor/RecipeEditorView.swift` | Hero, required title, summary, ingredient/step quick-add, per-step timer toggle, drag-to-reorder, tags, special notes, photos button. |
| Recipe Import (text) | `Views/Library/ImportRecipeView.swift` + `Lib/RecipeImporter.swift` | Single textbox, live "Title / First ingredient / First Step" checklist. Block format default; labeled headers and TikTok-style single-newline pastes both handled. |
| Recipe Import (URL) | `Lib/RecipeURLImporter.swift` + `Lib/RecipeSchemaParser.swift` | JSON-LD → OG fallback, TikTok via oEmbed, Pinterest HTML, IG/FB blocked with "paste the caption" hint. |
| AI parser (hybrid) | `Lib/RecipeAIParser.swift` | iOS 26+ `FoundationModels` / `@Generable`. Best-of vs regex via `pickBetterDraft` — regex wins if AI's longest step > 200 chars or step count drops below 70% of regex's. Silent fallback to regex on older OS / no Apple Intelligence. |
| Cook Mode | `Views/Cook/CookModeView.swift` | Two-phase (Prep ↔ Cook), servings scaler, per-step check-off, floating timer banner, adjust sheet, ready overlay, alarm sound, Mark-as-cooked. |
| Multi-cook pills bar | `Views/Cook/...` (in CookModeView family) | 1–4 active cooks. Foregrounded cook in solid pill; rest as outline pills with tap-to-foreground. "Add to Cook Mode" only when current Detail recipe isn't already an active cook. |
| Cook Mode tuck-down | `RootView` cover detents | `[.large, .height(80)]` — minimize to a tab-sized bar and keep browsing. |
| Timer w/ Live Activity | `Lib/TimerLiveActivityController.swift` + `WidgetExtension/TimerLiveActivity.swift` | Lock screen + Dynamic Island (compact / minimal / expanded). Background ding via `TimerNotifications`. Ready overlay vibrates every 1.2s, loops bundled `timer-alarm.caf`. |
| Persistence (cook session) | `App/CookingSessionStore.swift` | `[CookingSessionState]` JSON in UserDefaults under `cooking-session-states.v2`; v1→v2 migration on first load. Force-kill mid-cook recoverable. |
| Editor coordinator | `App/EditorCoordinator.swift` | Single source of truth for editor sheet open/dirty; gates sheet switches behind a discard alert. |
| Appearance (accent) | `App/AppearanceSettings.swift` | User-customizable accent, persisted as hex string. |

## Tech stack

| Layer | Choice |
|---|---|
| Language | Swift 5.10 |
| UI | SwiftUI, iOS 18+ deployment |
| State | `@State`, `@Observable`, SwiftData `@Model` |
| Persistence | SwiftData (`ModelContainer` injected at `@main`) + UserDefaults (cook-session JSON, accent hex, owner profile, user-account auxiliaries) + Keychain (`appleSub` + display name via `Lib/KeychainStore.swift`, survives reinstall, no iCloud sync) |
| Navigation | `NavigationStack` + `.sheet` + `.fullScreenCover`. Cook Mode and Editor/Import sheets hoisted to `RootView` with coordinators. |
| Notifications | `UNUserNotificationCenter` — per-cook identifier `cooking-timer-<cookID>`, scheduled at timer start, rescheduled on extend, cancelled on stop. |
| Live Activity | `ActivityKit`. Shared `TimerAttributes` (in `Sources/Shared/`) cross-compiled into both targets. |
| On-device AI | `FoundationModels` (iOS 26+, Apple Intelligence). `LanguageModelSession` + `@Generable` schema. Hard-gated by `@available(iOS 26.0, *)` and `SystemLanguageModel.default.availability`. Regex pipeline is the universal floor. |
| Alarm sound | Bundled `timer-alarm.caf` (generated in CI by ffmpeg + afconvert), played on loop via `AVAudioPlayer`. Falls back silently when missing. |
| Haptics | `Lib/Haptics.swift` wrapper around UIKit feedback generators. |
| Icons | SF Symbols only. Mascot is a SwiftUI `Canvas` port (not an asset). |
| Project file | XcodeGen — `ios-native/project.yml`, `.xcodeproj` gitignored, regenerated per CI run. |
| Build | GitHub Actions `macos-26` → `xcodebuild archive` → TestFlight upload via `xcrun altool`. Manual `workflow_dispatch`, ~15–25 min round-trip. |
| Build SDK | **iOS 26.x** (currently 26.4 SDK from `Xcode_26.4.1.app`). Required by Apple's 2026-04-28 ITMS-90725 cutoff. |
| Min iOS | 18.0 (build SDK and deployment target are independent). |
| Devices | iPhone only, portrait. |

What we don't use and won't without a clear reason: **no UIKit views beyond two `appearance()` proxies (keyboard tint, PageControl dot color), no Combine, no SPM/CocoaPods packages, no Core Data.**

## Data model

`Sources/Models/Recipe.swift` declares **five `@Model` classes**:

```swift
@Model final class Recipe {
    var id, title, summary, sourceUrl, imageUri, servings, cookTimeMinutes,
        notes, favorite, tags, lastCookedAt, cookCount, createdAt, updatedAt
    var prefaceNote, epilogueNote, generalNote: String?   // recipe-level note slots
    @Relationship(.cascade) var ingredients: [Ingredient]
    @Relationship(.cascade) var steps: [RecipeStep]
    @Relationship(.cascade) var photos: [RecipePhoto]    // gallery
    var sortedIngredients / sortedSteps / sortedPhotos
}

@Model final class Ingredient {
    var id, quantity: String?, unit, name, order, recipe
}

@Model final class RecipeStep {
    var id, order, text, needsTimer
    var specialNote: String?                              // per-step note
    @Attribute(.externalStorage) var image: Data? = nil   // DEPRECATED — see note
    @Relationship(.cascade) var photos: [RecipeStepPhoto] // up to 3 per step
    var sortedStepPhotos
}

@Model final class RecipePhoto {
    var id, image: Data?, caption: String?, order, recipe
}   // @Attribute(.externalStorage) on image

@Model final class RecipeStepPhoto {
    var id, image: Data?, caption: String?, order, step
}   // @Attribute(.externalStorage) on image
```

`RecipeStep.image: Data?` is **deprecated** but kept declared so SwiftData lightweight migration doesn't drop it on existing TestFlight installs. Step photos go through `RecipeStep.photos` (the relationship); never write to `image`.

`DraftRecipe` / `DraftIngredient` / `DraftStep` / `DraftPhoto` (in `Models/DraftRecipe.swift`) are plain structs — see "Editor edits a draft, not the model" pattern below.

## Live code lives in `ios-native/` only

Repo root = docs + `outdated/rn-expo/` (archived first implementation; **do not modify**). All app work happens under [`ios-native/`](./ios-native).

## Dev loop is CI-only — there is no local build

The developer is on Windows; Swift cannot build iOS apps on Windows. Every build runs on `macos-26` via [`.github/workflows/ios-native-ci.yml`](./.github/workflows/ios-native-ci.yml), triggered by manual `workflow_dispatch`. Round-trip is ~15–25 min per build.

Implications:
- No Xcode Previews. `#Preview` blocks compile in CI but cannot be visually inspected. Layout/visual issues need a real TestFlight install.
- Compile errors live in the `CompileSwift normal arm64` log section, *above* the "The following build commands failed" tail.
- Don't assume any Mac-side tooling is available — do not run `xcodegen`, `xcodebuild`, or `pod` from this environment.
- Plan one CI cycle per syntactic mistake (missing import, missing `await`). Be deliberate.

## Project generation, not project file

`ios-native/LlamasCookbookNative.xcodeproj` is **gitignored and regenerated** from [`ios-native/project.yml`](./ios-native/project.yml) by [XcodeGen](https://github.com/yonaskolb/XcodeGen) on every CI run. To add files, source folders, or build settings, edit `project.yml` — never hand-edit a pbxproj.

Two targets ship from one archive:
- `LlamasCookbookNative` — the app, `com.llamascookbook.app`, sources `Sources/` + `Resources/Assets.xcassets` (+ optional `Resources/timer-alarm.caf` generated in CI).
- `LlamasCookbookTimerWidget` — Live Activity / widget extension, `com.llamascookbook.app.widget`, sources `WidgetExtension/` + the shared `Sources/Shared/TimerAttributes.swift` cross-compiled into both targets.

Each target carries its own `PROVISIONING_PROFILE_SPECIFIER: $(MAIN_PROFILE_NAME)` / `$(WIDGET_PROFILE_NAME)`, which CI passes as build settings at archive time. `CFBundleVersion = date -u +%s` (Unix timestamp) so re-runs never collide on TestFlight. `MARKETING_VERSION = 0.1.0` is bumped manually in `project.yml`.

The app target uses an **explicit Info.plist** (`Resources/AppInfo.plist`, `GENERATE_INFOPLIST_FILE: NO`) because `CFBundleURLTypes` (the `llamascookbook://` URL scheme) and `UIDesignRequiresCompatibility` (Liquid Glass opt-out) can't be expressed via `INFOPLIST_KEY_*`. The widget target uses its own `WidgetExtension/Info.plist`.

## Source layout (under `ios-native/Sources/`)

- **`App/`** — `@main` (`LlamasCookbookApp.swift` + `AppDelegate` for `UNUserNotificationCenter` foreground handling and `didReceive` deep-link routing) and the app-scope coordinators all hung off `RootView`:
  - `CookingSession` (multi-cook state — `activeCooks: [ActiveCook]`, `foregroundedCookID`, `pendingRestoration`)
  - `CookingSessionState` + `CookingSessionStore` (Codable mirror + UserDefaults persistence with v1→v2 migration)
  - `EditorCoordinator` (single-sheet gating with dirty-flag discard alert)
  - `NavigationContext` (which `Recipe.id` is currently in Detail — read by the multi-cook pills bar to decide whether to show "Add to Cook Mode")
  - `AppearanceSettings` (user-customizable accent, persisted as hex string)
  - `OwnerProfile` (sender display name + first-share-prompt flag for app-to-app recipe sharing, persisted to UserDefaults)
  - `UserAccount` (Sign-in-with-Apple identity — `Status` enum (signedOut / signingIn / signedIn(UserIdentity) / signInFailed), `appleSub` + display name in Keychain, other fields in UserDefaults; `cloudKitUserRecordID` and `friendCode` nil throughout PR 1, populated when PR 2 lands. Migrates `OwnerProfile.userName` once on first sign-in. `refreshCredentialState()` runs from `RootView`'s cold-launch task.)
- **`Models/`** — `Recipe.swift` declares five `@Model` classes: `Recipe`, `Ingredient`, `RecipeStep`, `RecipePhoto`, `RecipeStepPhoto`. `DraftRecipe.swift` holds the editor draft structs (`DraftRecipe`, `DraftIngredient`, `DraftStep`, `DraftPhoto`) and the `toDraft()` / `apply(_:)` bridge.
- **`Lib/`** — pure logic / utilities (no SwiftUI views):
  - Formatting: `Quantity` (parse/format/scale + measurable-fraction snap + `ClockFormat.mmss` + `StringCase`), `Plural` (unit pluralization + `needsConnector` for "of" insertion), `IngredientDisplay` (`Ingredient.display(scaledBy:)` → `Display { quantity, unit, takesOf, name, measure, fullLine }`)
  - Import: `RecipeImporter` (text-paste, three-fallback step splitter, caption-style fallback), `RecipeURLImporter` (platform-routed fetch), `RecipeSchemaParser` (JSON-LD + OG), `RecipeAIParser` (iOS 26+ FoundationModels with quality gate)
  - Recipe ops: `RecipeExport`, `SourdoughCalculator`, `TagPresets`
  - Timer + audio: `AlarmPlayer` (looped `.caf` via `AVAudioPlayer`), `TimerNotifications` (per-cook `cooking-timer-<cookID>` identifiers, legacy-id cleanup), `TimerLiveActivityController` (per-instance ActivityKit wrapper)
  - Photos: `ImageProcessing` (`CGImageSource`/`CGImageDestination` resize + format-preserving re-encode + bytes guard, `Task.detached`)
  - Auth: `KeychainStore` (string in / string out wrapper around `SecItem*` keyed by service+account, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so survives reboot but doesn't sync across devices), `SignInWithAppleService` (only place that imports `AuthenticationServices` — configures `ASAuthorizationAppleIDRequest` scopes, processes the SwiftUI `SignInWithAppleButton` completion `Result` into a flat `Credential`, async `credentialState(for:)` for cold-launch revocation checks)
  - UI utilities: `Haptics`, `KeyboardDismiss.focusedNumeric`, `Shake`
- **`Shared/`** — cross-target Swift files compiled into multiple targets. `TimerAttributes` (`ActivityAttributes`, used by main app + widget; carries `recipeID` + optional `cookID`). `SharedContainer` (App Group container access for the share extension, `group.com.llamascookbook.app`). `Base64URL` (URL-safe base64 helpers — used by `RecipeShare.encodeURL/decode(url:)` and the share extension's URL handoff). Anything in `Sources/Shared/` must be self-contained (Foundation only — no SwiftData, no SwiftUI) so it compiles cleanly into both extension targets.
- **`Theme/`** — `AppColor` (cream/terracotta palette + `.onAccent` semantic token), `AppFont` (system serif placeholder; Fraunces/Inter not bundled), `AppSpacing`/`AppRadius`, `ColorHex` (Color↔"#RRGGBB" round-trip).
- **`Views/`** — one folder per feature area:
  - `Components/` — `LlamaLogo` (bitmap brand artwork from `Assets.xcassets/LlamaLogo.imageset` with an accent-driven drop shadow — replaces the old hand-drawn `LlamaMascot` Canvas), `EmptyLibraryView`, `RecipeImageView` (single rendering surface for all photos, NSCache-backed), `PhotoCarouselView` (closure-driven gallery + step-image viewer), `AccentColorPicker`
  - `Library/` — `LibraryView` (FAB menu, A–Z scrub, mascot watermark, filter chips), `RecipeCardView`, `ImportRecipeView`, `ImportHelpView`
  - `Detail/` — `RecipeDetailView` (sections, gallery + step-photo thumbnails, ShareLink, sourdough chip), `ConversionsView` (reference cards + live calculator), `SourdoughCalculatorView`
  - `Editor/` — `RecipeEditorView` (root form, drag-to-reorder steps via `StepDropDelegate`, photos button, special-notes editor), `IngredientQuickAdd`, `IngredientRowEditor`, `StepQuickAdd`, `StepRowEditor`, `TagInputView`, `SpecialNotesEditor`, `PhotoToggleButton`, `Chips/{QuantityChips,UnitChips}`
  - `Cook/` — `CookModeView` (the whole single-cook UI; presented per-foregrounded cook via `.id(cookID)`)
  - `Profile/` — `ProfileView` (sheet-presented from `LibraryView`'s person-circle toolbar button; signed-out renders `SignInWithAppleButton` + tagline, signed-in renders editable display-name row + friend-code placeholder + Coming-soon friends row + Sign Out + Delete Account confirm)

## Architectural patterns worth knowing

**Editor edits a draft, not the model.** `Recipe` is a SwiftData `@Model` (reference type), so direct edits would auto-persist on every keystroke. The editor takes a snapshot into `DraftRecipe` on open and only calls `Recipe.apply(_:)` on Save. **Critical sub-rule:** `apply(_:)` does `ingredients.removeAll()` + `steps.removeAll()` + `photos.removeAll()` + `step.photos` rebuild on every save, which cascade-deletes external-storage sidecars. **Bytes must be carried through the draft** (`DraftPhoto.image: Data?` for gallery, `DraftStep.images: [Data]` for step photos) or every save silently loses every image. See `Recipe.apply(_:)` in `Models/DraftRecipe.swift`.

**Coordinators above the NavigationStack.** `CookingSession`, `EditorCoordinator`, `NavigationContext`, `AppearanceSettings` all live as `@State` in `RootView` and are propagated via `.environment(...)`. The Cook Mode `.fullScreenCover` and editor/import `.sheet` are both hoisted to RootView so they survive Library→Detail navigation. Re-inject environments explicitly into covers — `@Observable` values can drop out across cover boundaries (see `RootView` line ~109).

**Multi-cook session shape.** `CookingSession.activeCooks: [ActiveCook]` (private(set)) holds 0–4 cooks. Mutations route through `start` (replaces), `addParallel` (additive, refuses duplicates and over-cap), `remove(cookID:)` (drops one; if last, `endAll`; if foregrounded, hands off + seeds `pendingRestoration`), `foreground(cookID:)`, `minimize`, `resume`, `restore`. **`ActiveCook.id` is distinct from `recipe.id`** because the same recipe could in principle be cooked twice — but `addParallel` *currently dedups by `recipe.id`*, so v1 disallows that case in the UI even though the model would allow it. **`CookModeView` is recreated on every cook switch** via `.id(cookID)` in RootView, so its `@State` for phase/strikes/timer seeds fresh per cook from `pendingRestoration`.

**Per-cook persistence.** Every meaningful state change in `CookModeView` calls `persistSnapshot()` → `CookingSession.persistForegroundedSnapshot(_:)` → `CookingSessionStore.save(...)` (writes the full `[CookingSessionState]` JSON to UserDefaults under `cooking-session-states.v2`). v1→v2 migration runs once on first load, wraps the legacy single-state payload in a 1-element array, and removes the v1 key. Force-kill mid-cook is recoverable: `CookingSession.restore` on launch rebuilds from disk, expired timers surface the ready overlay on first render rather than auto-restarting the alarm (re-opening to a screaming app would be hostile).

**Timer notification IDs are per-cook.** `TimerNotifications.identifier(for: cookID:)` produces `cooking-timer-<uuid>`. Two parallel cooks each get distinct lock-screen banners. `cancelAll` also wipes the legacy single-id `"cooking-timer"` for clean upgrades. Notification `userInfo` carries `recipeID` + `cookID`; the `AppDelegate.didReceive` handler routes via `llamascookbook://cook/<recipeID>` and the Live Activity widget bakes the same URL into `widgetURL`. RootView's `onOpenURL` looks up the matching `ActiveCook` by `recipe.id` and calls `foreground(cookID:)`.

**Multi-cook timer hole (outstanding).** `TimerLiveActivityController` is per-`CookModeView`, not per-session. Each `CookModeView` instance owns one controller; `adopt(forRecipeID:)` filters by `attributes.recipeID` so kill/restore re-attaches the right Live Activity. **When two cooks have running timers simultaneously, only the foregrounded cook's CookModeView exists**, so the backgrounded cook's Live Activity is unmanaged from the app side. iOS will keep ticking it (because `TimerAttributes.ContentState.endDate` drives countdown locally), but extending/cancelling from the foregrounded cook's banner won't reach it. See Multi-Recipe-Cook-Mode.md §6 for the planned `TimerLiveActivityRegistry` lift.

**Quantity strings, not numbers.** `Ingredient.quantity` is `String?` (`"2 & 1/2"`) so mixed fractions survive a round trip. `Lib/Quantity.swift` parses, scales (Cook Mode servings scaler), and formats — snapping scaled values to measurable fractions only (no `0.42 tsp`). Both `&` and space-separated forms accepted on input; `&` is canonical on output.

**Per-step timer flag with text-based duration extraction.** `RecipeStep.needsTimer: Bool` is the source of truth for "should this step show a timer affordance in Cook Mode." When true, `CookModeView.timerSeconds(for:)` extracts a duration from the step text first (`extractDurationSeconds` regex pair handles ranges by taking the *smaller* number), then falls back to `recipe.cookTimeMinutes`, then to a 5-minute hard default. The keyword extractor (`oven`, `bake`, `simmer`, …) only labels the timer chip — it doesn't gate visibility.

**Special notes have four placement slots.** `Recipe.prefaceNote` / `epilogueNote` / `generalNote` are recipe-level; `RecipeStep.specialNote` is per-step. The `SpecialNotesEditor` enforces "one note per slot" at the picker layer (only shows empty slots) — to edit, the user taps the existing row and types into the same slot.

**Detail-quick-edit vs. Editor-full-edit gallery.** Gallery photos in Detail mutate `recipe.photos` directly through `recipe.photos.append(RecipePhoto(...))` and `modelContext.delete(sorted[index])` — **persistence is immediate** (like favorite-toggle), no Save needed. Gallery photos in Editor mutate `draft.photos` and only commit on Save through `Recipe.apply(_:)` — which means Cancel discards adds. Both paths use `PhotoCarouselView` with closure-based callbacks; the carousel doesn't know which mode it's in.

**Single keyboard `Done` for numeric fields.** A single `@FocusState private var isNumericFocused: Bool` lives in `RecipeEditorView` and is threaded down via `FocusState<Bool>.Binding`; `focusedNumeric(_, when:)` in `Lib/KeyboardDismiss.swift` attaches it only to numeric keyboards. The single root `ToolbarItemGroup(placement: .keyboard)` lights up the Done button only when `isNumericFocused == true`. Add new numeric fields with this helper, not their own toolbar.

**SF Symbols + SwiftUI primitives only.** No UIKit views beyond `UIViewRepresentable` last-resort, no Combine, no SPM/CocoaPods packages. The brand logo is a bitmap loaded from `Assets.xcassets/LlamaLogo.imageset` (`Views/Components/LlamaLogo.swift`) — the old Canvas-port `LlamaMascot` was replaced when the design system shipped real artwork. The PNG body color is baked in; only the drop shadow is tintable, and it tracks `appearance.accentColor` so the user's color picker drives the halo (mirrors the SVG export's `--llama-shadow` CSS variable contract). UIKit appearance proxies are used twice deliberately: keyboard tint (`UIView.appearance().tintColor` in `App.init`) and PageControl dot color (`UIPageControl.appearance()` in `PhotoCarouselView.stylePageControl`). One `UIViewControllerRepresentable` exception: `Views/Components/ShareSheet.swift` wraps `UIActivityViewController` because SwiftUI's `ShareLink` can't be triggered programmatically — the recipe-sharing flow needs the first-share prompt to resolve before the share sheet opens, which forces state-driven presentation. Single-purpose, no other UIKit reaches downstream.

## Shared helpers — reach for these before rolling local versions

**Theme tokens (`Theme/AppColor.swift`):** `.background`, `.surface`, `.surfaceRaised`, `.surfaceSunken`; `.textPrimary` / `.textSecondary` / `.textTertiary`; `.accent` / `.accentDeep` / `.accentSoft`; **`.onAccent`** (cream text/icon on accent fills — 25 hard-coded `Color(red: 1, green: 0.992, blue: 0.972)` literals were replaced by this token); `.success`, `.destructive`, `.divider`, `.dividerStrong`, `.cookModeBackground`, `.shadow`, `.shadowSoft`.

**Type (`Theme/AppFont.swift`):** `.display`, `.recipeTitle`, `.sectionHeading`, `.eyebrow`, `.body`, `.ingredient`, `.ingredientCook`, `.caption`. `Text.eyebrowStyle(_:)` for small-caps eyebrows. All system fonts (`.serif` design for headings); custom Fraunces/Inter not bundled — target of the aesthetic pass.

**Spacing (`Theme/AppSpacing.swift`):** `xs=4 / sm=8 / md=12 / lg=16 / xl=24 / xxl=32 / xxxl=48`. `AppRadius`: `sm=8 / md=12 / lg=16 / xl=24`.

**Formatting:**
- `Recipe.sortedIngredients` / `.sortedSteps` / `.sortedPhotos`, `RecipeStep.sortedStepPhotos` — single sort helpers; never write `.sorted { $0.order < $1.order }` inline.
- `Ingredient.display(scaledBy:)` → `Display { quantity, unit, takesOf, name, measure, fullLine }` — single qty + plural unit + "of" connector + name pipeline.
- `ClockFormat.mmss(_:)` — "M:SS" countdown.
- `StringCase.capitalizeFirst(_:)` / `.titleCase(_:)`.
- `Quantity.parse / format / scale / displayFormat / splitForChips / combine` — all quantity math goes through here. Snaps to measurable fractions on format.
- `Plural.unit(_, for:)` / `.needsConnector(_)` — English -s/-es; `needsConnector` flags discrete-count units ("3 cloves of garlic" vs "2 cups flour").
- `RecipeImporter.parse(_:)` — text-paste path, three-fallback step splitter (newlines → numbered markers → comma-then / comma-digit → sentence boundaries). Caption-style fallback: when ≤2 blank-line blocks but ≥6 lines, hand off to `parseUnstructuredLines` + `looksLikeIngredient`.
- `RecipeURLImporter.fetch(_:)` + `RecipeSchemaParser.parse(html:)` — JSON-LD → OG fallback; `aiParse(_:sourceUrl:)` runs both regex and AI, `pickBetterDraft` chooses. Tags are **not** auto-populated from hashtags / keywords (user-controlled via `TagPresets`); hashtags are stripped from caption text.
- `RecipeAIParser.parse(_:sourceUrl:)` — iOS 26+ on-device LLM, returns nil silently on unavailable / quality-gate fail.
- `recipe.exportText` — plain-text export.

**Photos:**
- `RecipeImageView` — single rendering surface; NSCache-backed; size hints to drive thumbnail vs full-bleed.
- `PhotoCarouselView` — closure-driven (doesn't know Detail-quick-edit vs Editor-draft mode).
- `ImageProcessing` — `Task.detached` resize + format-preserving re-encode + bytes guard via `CGImageSource`/`CGImageDestination`.

**UI utilities:**
- `FlowRow` — line-wrapping chip container.
- `shake(count:)` — counter-driven horizontal shake; pair with `Haptics.warning()`.
- `focusedNumeric(_, when:)` — single editor-root Done button for numeric keyboards only.
- House list-row transition: `.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity.combined(with: .scale(scale: 0.9)))` + `.spring(response: 0.42, dampingFraction: 0.82)`.

## UX principles (still binding)

From llamas-cookbook-plan.md and PROJECT.md §6:

1. **One-thumb operable.** Primary actions in bottom half or toolbar.
2. **Input friction = death.** Quick-add, visible add buttons, Return-submits-and-refocuses, one conditional Done.
3. **Cook Mode is its own world.** Warmer bg, larger type (`ingredientCook`), slower pacing.
4. **Gestures have visible fallbacks.** Long-press Delete also has a context-menu Delete.
5. **Generous whitespace.**
6. **Silent save.** Only warn on Cancel when there's real loss.
7. **Forgiving.** Deletions confirmed. Timer cancel is destructive-styled.

**Canonical interaction details (don't regress):**
- Quantity chips: two rows (wholes bigger/bolder, fractions smaller). Only measurable fractions — no 3/8 · 5/8 · 7/8. Tapping active deselects. Cook-mode scaling snaps to the same set.
- Ampersand fractions: `2 & 1/2 cups` on display. Parser also accepts `2 1/2`.
- Detail ingredient row: `•  2 & 1/2 cups  —  flour`. Quantity in accent semibold monospaced, em-dash, name in textPrimary.
- Per-step timer flag: clock glyph on step quick-add and row editor. Cook Mode shows the timer affordance only for `needsTimer == true`.
- Floating timer banner pinned between phase header and scroll. Tap opens the running-timer sheet with a 1–60 min wheel.
- Ready overlay: full-screen terracotta with bell + `"{Label} timer ready!"`, embedded MinutePicker + filled Extend (preserves `timerStepId`), outlined Stop. Vibration + haptic warning every 1.2s until Stop/Extend.

## Signing & CI gotchas

- **Bundle id:** `com.llamascookbook.app` (widget: `com.llamascookbook.app.widget`). **Team:** `GYFN949Q5E`. **ASC app id:** `6762527184`.
- **CFBundleVersion** = Unix timestamp; **MARKETING_VERSION** = `0.1.0` (bump in `project.yml`).
- **Secrets** (GitHub Actions): `IOS_DIST_CERT_P12_BASE64`/`_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`, `APPSTORE_API_KEY_P8_BASE64`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`.

These are intentional and have stories — don't "clean them up" without checking comments in [`ios-native-ci.yml`](./.github/workflows/ios-native-ci.yml):

- **`macos-26` runner pinned explicitly.** `macos-latest` resolves to macOS 15 / Xcode 16, which fails ITMS-90725.
- **Xcode 26 selection prefers stable over beta.** Beta SDKs ship a simulator-runtime build mismatch that breaks `actool` during archive even on device builds (e.g. `error: No simulator runtime version from [...] available to use with iphonesimulator SDK version 23F5054d`). The picker globs `Xcode_26*.app`, filters `beta`, sorts by version (`sort -V`), falls back to beta with a `::warning::` only if no stable exists. **Don't hardcode the app name** — Apple ships point releases (26.0.1, 26.1.1, 26.4.1) and a hardcoded path fails fast. A naive `sort -V | tail -1` picks the beta because `26.5_beta > 26.4.1`.
- **`DEVELOPER_DIR` written to `$GITHUB_ENV`** as belt-and-suspenders alongside `xcode-select -s`. The runner image pre-sets `DEVELOPER_DIR` in shell profile pointing at the default Xcode (currently beta), which silently overrides `xcode-select` for every subsequent step's fresh shell.
- **`xcodebuild -downloadPlatform iOS`** runs after `-runFirstLaunch` even though we're not building for the simulator; `actool`'s thinning step still cross-checks simulator runtimes. Includes a 3-attempt retry loop with backoff because Apple's content endpoint is flaky from CI.
- **App icon PNGs sanitized at CI time** by ImageMagick with `-alpha remove -alpha off -colorspace sRGB -define png:color-type=2`. The legacy multi-size icon set (14 PNGs under `Assets.xcassets/AppIcon.appiconset/`) ships as committed RGBA from the design export pipeline; the CI step strips alpha in place per build because Xcode 26 hard-rejects RGBA app icons (`CompileAssetCatalogVariant thinned` archive failure). The placeholder-generation fallback is gone now that real artwork is committed — if the appiconset is empty CI fails fast with a clear error rather than silently shipping a placeholder.
- **Timer alarm `.caf` generated at CI time** by ffmpeg + afconvert. Listed `optional: true` in `project.yml`; the app falls back to `UNNotificationSound.default` and `AlarmPlayer.start` no-ops silently when missing.
- **`UIDesignRequiresCompatibility = true`** in `Resources/AppInfo.plist` keeps legacy chrome rendering on iOS 26 (Liquid Glass opt-out). The flag is **temporary** — Apple has signaled removal in iOS 27. Adoption is queued as part of the aesthetic pass.
- **Share Extension provisioning** — the `LlamasCookbookShareExtension` target ships with its own bundle id (`com.llamascookbook.app.shareext`) + provisioning profile (`IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64` secret). The App Group entitlement (`group.com.llamascookbook.app`) MUST be present on BOTH the main app's profile and the extension's profile, or signing fails with `Provisioning profile doesn't include the app-groups entitlement`. After enabling App Groups on a target's App ID in the Apple Developer Portal, the matching provisioning profile must be regenerated (Edit → Save) — the entitlement is baked into the profile at issue time. Three string literals must agree: `SharedContainer.appGroupID` (Swift), the entitlements files in `Resources/` and `ShareExtension/`, and the App Group identifier in the Developer Portal. See [Share-Extension-Plan.md §8](./Share-Extension-Plan.md) for the full portal walkthrough.
- **`LSSupportsOpeningDocumentsInPlace = <false/>`** in `Resources/AppInfo.plist` is required because we declare `CFBundleDocumentTypes` (for `.llamarecipe`). Without it App Store Connect emits `ITMS-90737` on every upload (warning, not rejection — but pollutes the build report). `false` is the right semantic: we copy the incoming file into our Inbox, materialize into SwiftData, and never touch the source again. Switching to `true` would imply security-scoped editing of the original file, which is the document-based-app pattern, not ours. If we ever add another `CFBundleDocumentTypes` entry, this same key still covers it (it's app-wide, not per-type).
- **Sign-in-with-Apple entitlement** — `com.apple.developer.applesignin = ["Default"]` in `Resources/LlamasCookbook.entitlements`. The capability MUST also be enabled on the main App ID in the Apple Developer Portal (Identifiers → `com.llamascookbook.app` → Capabilities → Sign In with Apple → Configure → Enable as primary App ID), and the provisioning profile MUST be regenerated after enabling — the entitlement is baked into the profile at issue time. Build fails to sign with "Provisioning profile doesn't include the com.apple.developer.applesignin entitlement" otherwise; `IOS_PROVISIONING_PROFILE_BASE64` GitHub Secret needs the freshly-regenerated profile pasted in. No new GitHub Secret needed for the auth itself — Apple manages all keys server-side. See [Implementing-User-Sign-In.md §10](./Implementing-User-Sign-In.md) for the full portal walkthrough.

Watch points for the next image rotation: the `Print toolchain` CI step's `iphoneos --show-sdk-version` line is the canary — if it drops below 26.x, ITMS-90725 returns. The picker's `::warning::` line will also appear in the log if only a beta is available.

## Known limitations / deferred

- **Multi-cook timer registry** — see "Multi-cook timer hole" pattern above. Two parallel running timers, the backgrounded one is unmanaged. `TimerLiveActivityRegistry` lift is the planned fix.
- **Settings screen** — still a stub. Nothing wired beyond accent color (which lives elsewhere via `AppearanceSettings`).
- **App icon** — placeholder generated in CI. Real 1024×1024 artwork not yet in the asset catalog.
- **Keep-awake during Cook Mode** — `UIApplication.shared.isIdleTimerDisabled = true` not yet wired.
- **iPad** — iPhone only; no iPad layout.
- **Live Activity App Intents** — in-island +1/−1/cancel deferred.
- **Custom type** — Fraunces / Inter not bundled; `AppFont` uses system serif as placeholder.
- **iCloud sync** — not configured (SwiftData + CloudKit is the path).
- **`RecipeStep.image: Data?`** — deprecated single-image slot, kept for migration. Will be removed in a future cleanup migration.

## What's next

**Short-term active queue:**
1. **Recipe sharing between users**, per [Recipe-Sharing.md](./Recipe-Sharing.md) + [Share-Extension-Plan.md](./Share-Extension-Plan.md). Four-PR sequence: PR 1 schema/UTType/provenance fields (✅ shipped) → PR 2 outbound Detail share menu + first-share prompt (✅ shipped) → PR 3 inbound `onOpenURL` + Import Preview + provenance display (✅ implemented, awaiting CI verification) → PR 4 Share Extension target + App Group handoff + main-app `share-url` / `share-incoming` routing (✅ implemented, awaiting CI verification — Apple Developer Portal setup done, GitHub Secrets updated with regenerated main + new share-ext profiles). Cloud transport designed in but not implemented.
2. **User sign-in + cloud recipe delivery**, per [Implementing-User-Sign-In.md](./Implementing-User-Sign-In.md). Four-PR sequence: PR 1 Sign-in-with-Apple + Profile sheet + Keychain identity (✅ implemented, awaiting CI + portal capability — see Signing & CI Gotchas) → PR 2 CloudKit `User`/`RecipeShare` records + friend code + send flow → PR 3 inbox + push subscription → PR 4 friends-list polish + privacy nutrition labels + privacy policy URL.
3. Per-cook `TimerLiveActivityRegistry` (lift the controller out of `CookModeView`, key by `cookID`, stop the foregrounded-only blind spot).
4. Aesthetic / typography pass — Fraunces + Inter bundled, real app icon, richer Library cards, Detail rhythm (drop caps, dividers), Cook Mode differentiation, transitions polish.
5. Liquid Glass adoption (must land before iOS 27 SDK becomes mandatory and `UIDesignRequiresCompatibility` is removed).

**Queued / deferred:** dark mode (palette is sRGB-explicit; needs semantic light/dark tokens), Settings screen, iPad layout, iCloud sync, App Intents on the Live Activity.

## Working with this documentation

- **CLAUDE.md is the document the user keeps current.** When you change product behavior, update this file.
- **Code wins over docs.** When memory or docs disagree with code, code wins, and update the doc.
- Feature plan docs (`Multi-Recipe-Cook-Mode.md`, `Photo-Capability.md`, etc.) decay after implementation; before quoting them, grep the code for the type / function they reference.
- PROJECT.md's "current status" sections are stale — defer to this file.
