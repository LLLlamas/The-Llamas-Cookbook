# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Source of truth — read these in order

1. **[STATE.md](./STATE.md)** is the most current implementation snapshot (last refreshed 2026-04-26 + multi-cook landed in commits 4bc8835…78f4672 since). When STATE.md disagrees with PROJECT.md, STATE wins.
2. **[PROJECT.md](./PROJECT.md)** is the stable project reference — tech-stack rationale, signing, dev workflow.
3. **[llamas-cookbook-plan.md](./llamas-cookbook-plan.md)** is the original product spec — vision / JTBD / UX principles still authoritative.
4. **[ROADMAP.md](./ROADMAP.md)** — deferred work + the Live Activity portal-setup checklist.

Feature design docs are *plans*, not specs — verify against the code before quoting them:

- **[Multi-Recipe-Cook-Mode.md](./Multi-Recipe-Cook-Mode.md)** — **mostly implemented** (PR 1 + PR 2 landed). `CookingSession.activeCooks` array, `addParallel`, `remove(cookID:)`, `foreground(cookID:)`, multi-cook pills bar, "Add to Cook Mode" green button on Detail, v1→v2 persistence migration. **Not yet done:** per-cook timer registry — `TimerLiveActivityController` is still a single instance per `CookModeView`, so two parallel timers will collide on Live Activity / alarm (see Audit notes when extending).
- **[Photo-Capability.md](./Photo-Capability.md)** — **fully implemented** beyond the plan: gallery (`Recipe.photos` → `RecipePhoto`), per-step gallery up to 3 photos (`RecipeStep.photos` → `RecipeStepPhoto`, **not** the original `RecipeStep.image: Data?` slot — that field is deprecated and lingers for migration only), shared `PhotoCarouselView` + `RecipeImageView` + `ImageProcessing` infra. Carousel has add-confirmation alert and a 350ms picker-dismiss delay (workaround for an iOS 18 sheet-in-sheet alert race).
- **[SDK-Update-Plan.md](./SDK-Update-Plan.md)** — done. Build SDK is iOS 26.x; `UIDesignRequiresCompatibility = true` keeps the legacy chrome until the aesthetic pass adopts Liquid Glass.

## Live code lives in `ios-native/` only

Repo root = docs + `outdated/rn-expo/` (archived first implementation; **do not modify**). All app work happens under [`ios-native/`](./ios-native): SwiftUI + SwiftData, **iOS 18+ deployment**, **iOS 26 SDK build**, Swift 5.10, iPhone-only.

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
- **`Models/`** — `Recipe.swift` declares five `@Model` classes: `Recipe`, `Ingredient`, `RecipeStep`, `RecipePhoto`, `RecipeStepPhoto`. `DraftRecipe.swift` holds the editor draft structs (`DraftRecipe`, `DraftIngredient`, `DraftStep`, `DraftPhoto`) and the `toDraft()` / `apply(_:)` bridge.
- **`Lib/`** — pure logic / utilities (no SwiftUI views):
  - Formatting: `Quantity` (parse/format/scale + measurable-fraction snap + `ClockFormat.mmss` + `StringCase`), `Plural` (unit pluralization + `needsConnector` for "of" insertion), `IngredientDisplay` (`Ingredient.display(scaledBy:)` → `Display { quantity, unit, takesOf, name, measure, fullLine }`)
  - Import: `RecipeImporter` (text-paste, three-fallback step splitter, caption-style fallback), `RecipeURLImporter` (platform-routed fetch), `RecipeSchemaParser` (JSON-LD + OG), `RecipeAIParser` (iOS 26+ FoundationModels with quality gate)
  - Recipe ops: `RecipeExport`, `SourdoughCalculator`, `TagPresets`
  - Timer + audio: `AlarmPlayer` (looped `.caf` via `AVAudioPlayer`), `TimerNotifications` (per-cook `cooking-timer-<cookID>` identifiers, legacy-id cleanup), `TimerLiveActivityController` (per-instance ActivityKit wrapper)
  - Photos: `ImageProcessing` (`CGImageSource`/`CGImageDestination` resize + format-preserving re-encode + bytes guard, `Task.detached`)
  - UI utilities: `Haptics`, `KeyboardDismiss.focusedNumeric`, `Shake`
- **`Shared/`** — `TimerAttributes` (cross-target `ActivityAttributes`). Carries `recipeID` + optional `cookID` (nil for legacy activities pre-multi).
- **`Theme/`** — `AppColor` (cream/terracotta palette + `.onAccent` semantic token), `AppFont` (system serif placeholder; Fraunces/Inter not bundled), `AppSpacing`/`AppRadius`, `ColorHex` (Color↔"#RRGGBB" round-trip).
- **`Views/`** — one folder per feature area:
  - `Components/` — `LlamaMascot` (Canvas-drawn), `EmptyLibraryView`, `RecipeImageView` (single rendering surface for all photos, NSCache-backed), `PhotoCarouselView` (closure-driven gallery + step-image viewer), `AccentColorPicker`
  - `Library/` — `LibraryView` (FAB menu, A–Z scrub, mascot watermark, filter chips), `RecipeCardView`, `ImportRecipeView`, `ImportHelpView`
  - `Detail/` — `RecipeDetailView` (sections, gallery + step-photo thumbnails, ShareLink, sourdough chip), `ConversionsView` (reference cards + live calculator), `SourdoughCalculatorView`
  - `Editor/` — `RecipeEditorView` (root form, drag-to-reorder steps via `StepDropDelegate`, photos button, special-notes editor), `IngredientQuickAdd`, `IngredientRowEditor`, `StepQuickAdd`, `StepRowEditor`, `TagInputView`, `SpecialNotesEditor`, `PhotoToggleButton`, `Chips/{QuantityChips,UnitChips}`
  - `Cook/` — `CookModeView` (the whole single-cook UI; presented per-foregrounded cook via `.id(cookID)`)

## Architectural patterns worth knowing

**Editor edits a draft, not the model.** `Recipe` is a SwiftData `@Model` (reference type), so direct edits would auto-persist on every keystroke. The editor takes a snapshot into `DraftRecipe` on open and only calls `Recipe.apply(_:)` on Save. **Critical sub-rule:** `apply(_:)` does `ingredients.removeAll()` + `steps.removeAll()` + `photos.removeAll()` + `step.photos` rebuild on every save, which cascade-deletes external-storage sidecars. **Bytes must be carried through the draft** (`DraftPhoto.image: Data?` for gallery, `DraftStep.images: [Data]` for step photos) or every save silently loses every image. See `Recipe.apply(_:)` in `Models/DraftRecipe.swift`.

**Coordinators above the NavigationStack.** `CookingSession`, `EditorCoordinator`, `NavigationContext`, `AppearanceSettings` all live as `@State` in `RootView` and are propagated via `.environment(...)`. The Cook Mode `.fullScreenCover` and editor/import `.sheet` are both hoisted to RootView so they survive Library→Detail navigation. Re-inject environments explicitly into covers — `@Observable` values can drop out across cover boundaries (see `RootView` line ~109).

**Multi-cook session shape.** `CookingSession.activeCooks: [ActiveCook]` (private(set)) holds 0–4 cooks. Mutations route through `start` (replaces), `addParallel` (additive, refuses duplicates and over-cap), `remove(cookID:)` (drops one; if last, `endAll`; if foregrounded, hands off + seeds `pendingRestoration`), `foreground(cookID:)`, `minimize`, `resume`, `restore`. **`ActiveCook.id` is distinct from `recipe.id`** because the same recipe could in principle be cooked twice — but `addParallel` *currently dedups by `recipe.id`*, so v1 disallows that case in the UI even though the model would allow it. **`CookModeView` is recreated on every cook switch** via `.id(cookID)` in RootView, so its `@State` for phase/strikes/timer seeds fresh per cook from `pendingRestoration`.

**Per-cook persistence.** Every meaningful state change in `CookModeView` calls `persistSnapshot()` → `CookingSession.persistForegroundedSnapshot(_:)` → `CookingSessionStore.save(...)` (writes the full `[CookingSessionState]` JSON to UserDefaults under `cooking-session-states.v2`). v1→v2 migration runs once on first load, wraps the legacy single-state payload in a 1-element array, and removes the v1 key. Force-kill mid-cook is recoverable: `CookingSession.restore` on launch rebuilds from disk, expired timers surface the ready overlay on first render rather than auto-restarting the alarm (re-opening to a screaming app would be hostile).

**Timer notification IDs are per-cook.** `TimerNotifications.identifier(for: cookID:)` produces `cooking-timer-<uuid>`. Two parallel cooks each get distinct lock-screen banners. `cancelAll` also wipes the legacy single-id `"cooking-timer"` for clean upgrades. Notification `userInfo` carries `recipeID` + `cookID`; the `AppDelegate.didReceive` handler routes via `llamascookbook://cook/<recipeID>` and the Live Activity widget bakes the same URL into `widgetURL`. RootView's `onOpenURL` looks up the matching `ActiveCook` by `recipe.id` and calls `foreground(cookID:)`.

**`TimerLiveActivityController` is per-CookModeView, not per-session.** Each `CookModeView` instance owns one controller; `adopt(forRecipeID:)` filters by `attributes.recipeID` so kill/restore re-attaches the right Live Activity. This is the **outstanding multi-cook hole**: when two cooks have running timers simultaneously, only the foregrounded cook's CookModeView exists, so the backgrounded cook's Live Activity is unmanaged from the app side. iOS will keep ticking it (because `TimerAttributes.ContentState.endDate` drives countdown locally), but extending/cancelling from the foregrounded cook's banner won't reach it. See Multi-Recipe-Cook-Mode.md §6 for the planned `TimerLiveActivityRegistry` lift.

**Quantity strings, not numbers.** `Ingredient.quantity` is `String?` (`"2 & 1/2"`) so mixed fractions survive a round trip. `Lib/Quantity.swift` parses, scales (Cook Mode servings scaler), and formats — snapping scaled values to measurable fractions only (no `0.42 tsp`). Both `&` and space-separated forms accepted on input; `&` is canonical on output.

**Per-step timer flag with text-based duration extraction.** `RecipeStep.needsTimer: Bool` is the source of truth for "should this step show a timer affordance in Cook Mode." When true, `CookModeView.timerSeconds(for:)` extracts a duration from the step text first (`extractDurationSeconds` regex pair handles ranges by taking the *smaller* number), then falls back to `recipe.cookTimeMinutes`, then to a 5-minute hard default. The keyword extractor (`oven`, `bake`, `simmer`, …) only labels the timer chip — it doesn't gate visibility.

**Special notes have four placement slots.** `Recipe.prefaceNote` / `epilogueNote` / `generalNote` are recipe-level; `RecipeStep.specialNote` is per-step. The `SpecialNotesEditor` enforces "one note per slot" at the picker layer (only shows empty slots) — to edit, the user taps the existing row and types into the same slot.

**Detail-quick-edit vs. Editor-full-edit gallery.** Gallery photos in Detail mutate `recipe.photos` directly through `recipe.photos.append(RecipePhoto(...))` and `modelContext.delete(sorted[index])` — **persistence is immediate** (like favorite-toggle), no Save needed. Gallery photos in Editor mutate `draft.photos` and only commit on Save through `Recipe.apply(_:)` — which means Cancel discards adds. Both paths use `PhotoCarouselView` with closure-based callbacks; the carousel doesn't know which mode it's in.

**Single keyboard `Done` for numeric fields.** A single `@FocusState private var isNumericFocused: Bool` lives in `RecipeEditorView` and is threaded down via `FocusState<Bool>.Binding`; `focusedNumeric(_, when:)` in `Lib/KeyboardDismiss.swift` attaches it only to numeric keyboards. The single root `ToolbarItemGroup(placement: .keyboard)` lights up the Done button only when `isNumericFocused == true`. Add new numeric fields with this helper, not their own toolbar.

**SF Symbols + SwiftUI primitives only.** No UIKit views beyond `UIViewRepresentable` last-resort, no Combine, no SPM/CocoaPods packages. The mascot is a SwiftUI `Canvas` port (`Views/Components/LlamaMascot.swift`), not a bundled asset. UIKit appearance proxies are used twice deliberately: keyboard tint (`UIView.appearance().tintColor` in `App.init`) and PageControl dot color (`UIPageControl.appearance()` in `PhotoCarouselView.stylePageControl`).

## CI gotchas baked into the workflow

These are intentional and have stories — don't "clean them up" without checking the comments in [`ios-native-ci.yml`](./.github/workflows/ios-native-ci.yml):

- **`macos-26` runner pinned explicitly.** `macos-latest` still resolves to macOS 15 / Xcode 16, which won't satisfy ITMS-90725.
- **Xcode 26 selection prefers stable point releases over beta.** Beta SDKs ship a simulator-runtime build mismatch that breaks `actool` during archive, even on device builds. The picker globs `Xcode_26*.app`, filters `beta`, sorts by version, falls back to beta with a warning only if no stable exists. **Don't hardcode the app name** — Apple ships point releases (26.0.1, 26.1.1, 26.4.1) and a hardcoded path fails fast.
- **`DEVELOPER_DIR` written to `$GITHUB_ENV`** as belt-and-suspenders alongside `xcode-select -s`. The runner image pre-sets `DEVELOPER_DIR` in shell profile pointing at the default Xcode (currently beta), which silently overrides `xcode-select` for every subsequent step's fresh shell.
- **`xcodebuild -downloadPlatform iOS`** runs after `-runFirstLaunch` even though we're not building for the simulator; `actool`'s thinning step still cross-checks simulator runtimes. Includes a 3-attempt retry loop with backoff because Apple's content endpoint is flaky from CI.
- **App icon PNG generated at CI time** by ImageMagick with `-alpha off -colorspace sRGB -define png:color-type=2`. Xcode 26 hard-rejects RGBA app icons. Replace with real artwork by dropping a 1024×1024 opaque-RGB PNG at `ios-native/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` and removing the "Generate placeholder app icon" step. **Keep the flags** — they're correct regardless of the source.
- **Timer alarm `.caf` generated at CI time** by ffmpeg + afconvert. Listed `optional: true` in `project.yml`; the app falls back to `UNNotificationSound.default` and `AlarmPlayer.start` no-ops silently when missing.

## Working with the documentation set

When updating product behavior, **STATE.md is the document the user keeps current** — it supersedes PROJECT.md's "current status" sections. Feature-specific plan docs decay after implementation; before quoting them, grep the code for the type / function they reference. The user explicitly asked: when memory or docs disagree with code, code wins, and update the doc.
