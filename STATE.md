# Llamas Cookbook — State of the App

> Snapshot: **2026-04-26**. Supersedes the "current status" and layout
> sections of [PROJECT.md](./PROJECT.md). The product vision and UX
> principles in [llamas-cookbook-plan.md](./llamas-cookbook-plan.md)
> remain authoritative; everything tech-stack / implementation-detail
> below is the newer source of truth. Companion docs:
> [Photo-Capability.md](./Photo-Capability.md) (next push),
> [SDK-Update-Plan.md](./SDK-Update-Plan.md), [ROADMAP.md](./ROADMAP.md).

---

## TL;DR — we're in a strong spot

Core CRUD is done end-to-end. The Swift native port has reached feature
parity with the archived RN app on every screen except Settings, and
has gone past it on several: Conversions reference + calculator,
**recipe import (text paste *and* URL — TikTok, Pinterest, recipe
blogs — with an on-device AI parser fallback that's gated to iOS 26 +
Apple Intelligence)**, ShareLink export, Live Activity / Dynamic
Island timer, A–Z letter index, drag-to-reorder steps, and a
minimizable Cook Mode that can tuck to a small detent while the user
browses the rest of the app.

The foundation is tight, deduped, and themed. The two active feature
pushes ahead of the aesthetic pass are **photos** (gallery + per-step
images — see [Photo-Capability.md](./Photo-Capability.md)) and
**multi-recipe Cook Mode** (cooking two or more recipes in parallel
under one cooking session). See §9.

---

## 1. What works, one line per capability

| Capability | Where it lives | Notes |
|---|---|---|
| Library list (sorted, filtered) | [LibraryView](ios-native/Sources/Views/Library/LibraryView.swift) | All · Favorites · one chip per tag. Long-press / context-menu Delete. |
| A–Z letter scrub | [LibraryView:338](ios-native/Sources/Views/Library/LibraryView.swift:338) | Right-edge strip, tap or drag to jump. Dimmed letters still route to the next populated one. |
| Mascot watermark | [LibraryView:87](ios-native/Sources/Views/Library/LibraryView.swift:87) | 6% opacity llama pinned behind the list. |
| Add / Import FAB | [LibraryView:250](ios-native/Sources/Views/Library/LibraryView.swift:250) | Menu: "New recipe" · "Import from text" (opens the unified import view that handles both URL fetch and text paste). |
| Recipe Detail | [RecipeDetailView](ios-native/Sources/Views/Detail/RecipeDetailView.swift) | Title, summary, times, tag pills, ingredients with bullet + em-dash, numbered steps with timer glyph, quoted notes, source link, signature row. |
| Favorite toggle | [RecipeDetailView:117](ios-native/Sources/Views/Detail/RecipeDetailView.swift:117) | Heart toolbar button, syncs `updatedAt`. |
| Export | [RecipeExport.swift](ios-native/Sources/Lib/RecipeExport.swift) + ShareLink in Detail | Plain-text output — Notes, Messages, Mail, AirDrop all work. |
| Conversions sheet | [ConversionsView](ios-native/Sources/Views/Detail/ConversionsView.swift) | Static reference cards + **live calculator** (volume, weight, temperature, cross-category guard). |
| Sourdough calculator | [SourdoughCalculatorView](ios-native/Sources/Views/Detail/SourdoughCalculatorView.swift) + [SourdoughCalculator](ios-native/Sources/Lib/SourdoughCalculator.swift) | Hydration / starter math sheet — total flour + hydration % → water + starter contribution. Surfaced from Detail when a recipe is tagged `sourdough` / `bread` / `baking`. |
| Recipe Editor | [RecipeEditorView](ios-native/Sources/Views/Editor/RecipeEditorView.swift) | Hero row, required title, summary, quick-add rows for ingredients/steps, per-step timer toggle, tag input with presets, drag-to-reorder steps, keyboard management, spring animations on row add/remove. |
| Recipe Import (text) | [ImportRecipeView](ios-native/Sources/Views/Library/ImportRecipeView.swift) + [RecipeImporter](ios-native/Sources/Lib/RecipeImporter.swift) | Single textbox for the whole recipe, live "Title / First ingredient / First Step" checklist with animated symbols showing what the parser pulled. Block format (blank-line separated) is the default; labeled `Ingredients` / `Steps` headers also accepted. Caption-style fallback handles single-newline pastes (TikTok-flavored) by classifying lines as ingredients vs. steps. Post-parse: comma-then split, parenthetical → specialNote, `while X` lift, sentence-case repair, timer auto-flag w/ compound-noun guard. First-run help sheet ([ImportHelpView](ios-native/Sources/Views/Library/ImportHelpView.swift)). |
| Recipe Import (URL) | [RecipeURLImporter](ios-native/Sources/Lib/RecipeURLImporter.swift) + [RecipeSchemaParser](ios-native/Sources/Lib/RecipeSchemaParser.swift) | Fetches recipe blogs (JSON-LD `Recipe` schema → OpenGraph fallback), Pinterest, TikTok (oEmbed); blocks Instagram/Facebook with a "paste the caption" hint. Hashtags + creator `@-handles` stripped; tags deliberately not auto-populated. |
| AI parser (hybrid) | [RecipeAIParser](ios-native/Sources/Lib/RecipeAIParser.swift) | iOS 26+ on-device LLM via `FoundationModels` (`@Generable` schema). Runs alongside the regex parser on messy URL paths; best-of comparison picks whichever produced the more usable draft (regex wins if AI's longest step > 200 chars or step count drops below 70% of regex's). Drops to nil silently on older OS / no Apple Intelligence / model errors. |
| Cook Mode | [CookModeView](ios-native/Sources/Views/Cook/CookModeView.swift) | Two-phase (Prep ↔ Cook), servings scaler, per-step check-off, floating timer banner, adjust sheet, full-screen ready overlay, vibration + looped alarm sound, Mark-as-cooked. |
| Cook Mode tuck-down | [RootView:22](ios-native/Sources/App/RootView.swift:22) | `.presentationDetents([.large, .height(80)])` — user can minimize Cook Mode to a tab-sized bar and keep browsing. |
| Timer w/ Live Activity | [TimerLiveActivityController](ios-native/Sources/Lib/TimerLiveActivityController.swift) + [WidgetExtension](ios-native/WidgetExtension/TimerLiveActivity.swift) | Lock screen row, Dynamic Island (compact / minimal / expanded). Background ding via [TimerNotifications](ios-native/Sources/Lib/TimerNotifications.swift). Ready overlay vibrates every 1.2s and loops a bundled `timer-alarm.caf` (generated in CI). |
| Editor coordinator | [EditorCoordinator](ios-native/Sources/App/EditorCoordinator.swift) | Single source of truth for "is an editor sheet open"; gates sheet switches behind a discard alert when the current draft is dirty. |
| Cooking session coordinator | [CookingSession](ios-native/Sources/App/CookingSession.swift) | Same pattern for the Cook Mode sheet. Lives above the NavigationStack. |

---

## 2. Tech stack

| Layer | Choice |
|---|---|
| Language | Swift 5.10 |
| UI | SwiftUI, iOS 18+ |
| State | `@State`, `@Observable` (via SwiftData `@Model`) |
| Persistence | SwiftData (iOS 17+) — `ModelContainer` injected at `@main`. |
| Navigation | `NavigationStack` + `.sheet` + `.fullScreenCover`. Cook Mode and the Editor/Import sheets are both hoisted to `RootView` with coordinators. |
| Notifications | `UNUserNotificationCenter` — scheduled at timer start, rescheduled on extend, cancelled on stop. |
| Live Activity | `ActivityKit` — shared `TimerAttributes` type in `Sources/Shared/` used by both the app and the widget target. |
| On-device AI | `FoundationModels` (iOS 26+, Apple Intelligence). `LanguageModelSession` + `@Generable` schema for recipe parsing. Hard-gated by `@available(iOS 26.0, *)` and `SystemLanguageModel.default.availability`; the regex pipeline is the universal floor when it's not. |
| Alarm sound | Bundled `timer-alarm.caf` generated at CI time (ffmpeg + afconvert), played on loop via `AVAudioPlayer` while the ready overlay is visible. Falls back silently when missing. |
| Haptics | [Haptics](ios-native/Sources/Lib/Haptics.swift) wrapper around UIKit feedback generators. |
| Icons | SF Symbols only. |
| Project file | [XcodeGen](https://github.com/yonaskolb/XcodeGen) — [`project.yml`](ios-native/project.yml), `.xcodeproj` gitignored, generated per CI run. |
| Build | GitHub Actions `macos-26` → `xcodebuild archive` → TestFlight upload via `xcrun altool`. Workflow globs for stable Xcode 26.x (skips betas; see §11) and runs `xcodebuild -downloadPlatform iOS` defensively. |
| Build SDK | **iOS 26.x** (currently 26.4 SDK from `Xcode_26.4.1.app`). Required by Apple's 2026-04-28 ITMS-90725 cutoff. |
| Min iOS | 18.0. (Build SDK and deployment target are independent — see §11.) |
| Devices | iPhone only (portrait). |

What the app doesn't use and won't without a clear reason: **no UIKit
views (only `.appearance().tintColor` for UIKit-keyboard tint), no
Combine, no external SPM packages, no Core Data.**

---

## 3. Data model

`Sources/Models/Recipe.swift` — three SwiftData `@Model` classes:

```swift
@Model final class Recipe {
    var id: UUID
    var title: String
    var summary: String?
    var sourceUrl: String?
    var imageUri: String?          // on model; not surfaced yet
    var servings: Int?
    var cookTimeMinutes: Int?
    var notes: String
    var favorite: Bool
    var tags: [String]             // stored lowercase, displayed title-case
    var lastCookedAt: Date?
    var cookCount: Int
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Ingredient.recipe)
    var ingredients: [Ingredient] = []

    @Relationship(deleteRule: .cascade, inverse: \RecipeStep.recipe)
    var steps: [RecipeStep] = []

    func markCooked() { … }
    var sortedIngredients: [Ingredient] { … }   // ← new, shared
    var sortedSteps: [RecipeStep]       { … }   // ← new, shared
}

@Model final class Ingredient {
    var id: UUID
    var quantity: String?     // string so "3 & 1/4" survives
    var unit: String?
    var name: String
    var order: Int
    var recipe: Recipe?
}

@Model final class RecipeStep {
    var id: UUID
    var order: Int
    var text: String
    var needsTimer: Bool = false
    var recipe: Recipe?
}
```

### `DraftRecipe` — why it exists

`Recipe` is a SwiftData reference type; every mutation persists. The
editor builds a plain-struct [`DraftRecipe`](ios-native/Sources/Models/DraftRecipe.swift)
on open and only calls `apply(_:)` on Save, so Cancel never destroys
work. `Recipe.toDraft()` and `Recipe.apply(_:)` are the only legal
bridge between the two shapes.

---

## 4. Directory layout

```
The-Llamas-Cookbook/
├── PROJECT.md                ← stable project reference
├── ROADMAP.md                ← deferred work items
├── STATE.md                  ← this file (current-state snapshot)
├── README.md                 ← short onboarding hook
├── llamas-cookbook-plan.md   ← original product spec (authoritative for vision / JTBD)
├── .github/workflows/
│   └── ios-native-ci.yml     ← archive + TestFlight upload
├── ios-native/
│   ├── project.yml           ← XcodeGen config (app + widget targets, signing specifiers)
│   ├── README.md             ← Swift-port-specific notes
│   ├── Sources/
│   │   ├── App/
│   │   │   ├── LlamasCookbookApp.swift       ← @main, SwiftData container, UIKit tint init, notification permission
│   │   │   ├── RootView.swift                ← NavigationStack + both coordinator-driven sheets + EditorSheetHost
│   │   │   ├── CookingSession.swift          ← @Observable "active cooking recipe" holder
│   │   │   └── EditorCoordinator.swift       ← @Observable editor/import sheet + dirty-flag + discard queue
│   │   ├── Models/
│   │   │   ├── Recipe.swift                  ← @Model types + sorted* helpers
│   │   │   └── DraftRecipe.swift             ← editor struct + toDraft/apply bridges
│   │   ├── Theme/
│   │   │   ├── AppColor.swift                ← palette (incl. new `onAccent` token)
│   │   │   ├── AppFont.swift                 ← type scale + `eyebrowStyle()`
│   │   │   └── AppSpacing.swift              ← spacing + radius constants
│   │   ├── Lib/
│   │   │   ├── AlarmPlayer.swift             ← bundled CAF loop player
│   │   │   ├── Conversions.swift             ← calculator engine + static reference sections
│   │   │   ├── Haptics.swift                 ← UIKit feedback wrappers
│   │   │   ├── IngredientDisplay.swift       ← `Ingredient.display(scaledBy:)` + `.measure` / `.fullLine`
│   │   │   ├── KeyboardDismiss.swift         ← `focusedNumeric(_, when:)` modifier
│   │   │   ├── Plural.swift                  ← unit pluralization + `needsConnector`
│   │   │   ├── Quantity.swift                ← parse / format / scale / chip split + `ClockFormat.mmss` + `StringCase`
│   │   │   ├── RecipeAIParser.swift          ← FoundationModels (iOS 26+) `@Generable` recipe parser
│   │   │   ├── RecipeExport.swift            ← plain-text exporter
│   │   │   ├── RecipeImporter.swift          ← text → DraftRecipe parser (block + labeled + caption-style fallback)
│   │   │   ├── RecipeSchemaParser.swift      ← JSON-LD / OpenGraph extractor (HTML)
│   │   │   ├── RecipeURLImporter.swift      ← URL fetch + platform routing (TikTok, Pinterest, blogs, IG/FB block)
│   │   │   ├── Shake.swift                   ← counter-driven horizontal shake effect
│   │   │   ├── SourdoughCalculator.swift     ← starter / hydration math
│   │   │   ├── TagPresets.swift              ← canonical preset tag list (incl. `sourdough`)
│   │   │   ├── TimerLiveActivityController.swift ← start/update/end wrapper around ActivityKit
│   │   │   └── TimerNotifications.swift      ← local-notification scheduler
│   │   ├── Shared/
│   │   │   └── TimerAttributes.swift         ← app + widget ActivityAttributes
│   │   └── Views/
│   │       ├── Components/
│   │       │   ├── EmptyLibraryView.swift
│   │       │   └── LlamaMascot.swift         ← Canvas-drawn mascot
│   │       ├── Library/
│   │       │   ├── LibraryView.swift         ← list + filters + A–Z index + FAB
│   │       │   ├── RecipeCardView.swift      ← card with gradient + tag chips + dates
│   │       │   ├── ImportRecipeView.swift    ← paste + format checklist + preview
│   │       │   └── ImportHelpView.swift      ← first-run tutorial sheet
│   │       ├── Detail/
│   │       │   ├── RecipeDetailView.swift    ← hero + sections + ShareLink + start-cooking bar
│   │       │   ├── ConversionsView.swift     ← reference cards + live calculator
│   │       │   └── SourdoughCalculatorView.swift ← hydration / starter math sheet
│   │       ├── Cook/
│   │       │   └── CookModeView.swift        ← phase toggle, scaler, timer bar, adjust sheet, ready overlay, MinutePicker
│   │       └── Editor/
│   │           ├── RecipeEditorView.swift    ← form root + sheet save/cancel + drag-to-reorder steps
│   │           ├── IngredientQuickAdd.swift  ← validated add-row with shake on error
│   │           ├── IngredientRowEditor.swift ← inline view / edit swap
│   │           ├── StepQuickAdd.swift        ← step add + `TimerToggleButton`
│   │           ├── StepRowEditor.swift       ← tap to edit, keyboard-aware
│   │           ├── TagInputView.swift        ← preset scroller + custom text field
│   │           └── Chips/
│   │               ├── QuantityChips.swift   ← wholes + measurable fractions
│   │               └── UnitChips.swift       ← common unit picker
│   ├── Resources/
│   │   └── Assets.xcassets/                  ← placeholder AppIcon (regenerated in CI)
│   └── WidgetExtension/
│       ├── Info.plist
│       ├── TimerWidgetBundle.swift           ← @main WidgetBundle
│       └── TimerLiveActivity.swift           ← lock-screen + Dynamic Island layouts
├── outdated/rn-expo/                         ← archived RN/Expo implementation
└── credentials/ + credentials.json           ← local signing material (gitignored)
```

---

## 5. Shared helpers (post-DRY pass)

This is the deduped set of "don't reinvent these" utilities. When
writing a new view, reach for these before rolling a local version.

### Theme tokens — [AppColor](ios-native/Sources/Theme/AppColor.swift)

- `.background` / `.surface` / `.surfaceRaised` / `.surfaceSunken` — 4-tier cream system.
- `.textPrimary` / `.textSecondary` / `.textTertiary` — 3-tier type color.
- `.accent` / `.accentDeep` / `.accentSoft` — terracotta family.
- `.onAccent` — **cream text/iconography to use on `.accent`-filled
  surfaces.** Before 2026-04-24 this was pasted as
  `Color(red: 1, green: 0.992, blue: 0.972)` in ~25 places; now it's
  named.
- `.success`, `.destructive`, `.divider`, `.dividerStrong`.
- `.cookModeBackground` — warm cream used as Cook Mode's page bg.
- `.shadow`, `.shadowSoft` — low-sat warm-brown shadow tints.

### Type — [AppFont](ios-native/Sources/Theme/AppFont.swift)

Scales: `.display`, `.recipeTitle`, `.sectionHeading`, `.eyebrow`,
`.body`, `.ingredient`, `.ingredientCook`, `.caption`. `Text.eyebrowStyle(_:)`
applies small-caps eyebrow styling in one modifier.

All currently system fonts (`.system(…, design: .serif)` for headings).
Custom fonts (Fraunces / Inter) are not bundled — likely target of the
aesthetic pass.

### Spacing — [AppSpacing](ios-native/Sources/Theme/AppSpacing.swift)

`xs=4 · sm=8 · md=12 · lg=16 · xl=24 · xxl=32 · xxxl=48`.
`AppRadius`: `sm=8 · md=12 · lg=16 · xl=24`.

### Formatting

- **`Recipe.sortedIngredients` / `.sortedSteps`** — single definition
  replacing four copies of the `.sorted { $0.order < $1.order }` line.
- **`Ingredient.display(scaledBy:)`** → `Display { quantity, unit, takesOf, name, measure, fullLine }`
  — the "qty + pluralized unit + 'of' connector + name" pipeline in
  one place, replacing the triplicate that lived in `RecipeExport`,
  `RecipeDetailView.ingredientRow`, and `CookModeView.ingredientDisplay`.
- **`ClockFormat.mmss(_:)`** — "M:SS" countdown formatting, one copy.
- **`StringCase.capitalizeFirst(_:)` / `.titleCase(_:)`** — shared
  between Cook Mode timer labels, tag display, and notification copy.
- **`Quantity.parse / format / scale / displayFormat / splitForChips / combine`**
  — all quantity math goes through here. Snaps to measurable fractions
  on format (never surfaces "0.42 tsp"). See `PROJECT.md §6` for the
  "hard-won" chip rules still binding.
- **`Plural.unit(_, for:)` / `.needsConnector(_)`** — English -s/-es
  with invariants; `needsConnector` flags discrete-count units
  ("3 cloves of garlic" vs "2 cups flour").
- **`RecipeImporter.parse(_:)`** — text-paste path. Block format is
  the default; falls through to the labeled format when explicit
  `Ingredients` / `Steps` headers exist; falls through to the
  caption-style classifier when blank-line separators are missing
  (TikTok-flavored single-newline pastes). All three end at the same
  step pipeline: `splitIntoSteps` → `parseStep` → `enrichStep`
  (`liftWhileClause`, `hasTimerSignal`).
- **`RecipeURLImporter.fetch(_:)` + `RecipeSchemaParser.parse(html:)`** —
  URL path. Schema parser handles JSON-LD + OG fallback; URL importer
  routes per platform (TikTok oEmbed, Pinterest HTML, blog HTML, IG/FB
  block-with-hint). Best-of comparison with `RecipeAIParser` lives in
  `RecipeURLImporter.aiParse(_:sourceUrl:)`.
- **`RecipeAIParser.parse(_:sourceUrl:)`** — iOS 26+ on-device LLM
  parse, `@Generable` schema mirrors `DraftRecipe`. Returns nil on
  unavailable / model error / quality-gate fail; caller falls back to
  the regex pipeline.
- **`recipe.exportText`** — output formatting.

### UI utilities

- **`FlowRow` layout** — line-wrapping chip container, used for tags.
- **`shake(count:)`** — counter-driven horizontal shake for validation
  errors. Pair with `Haptics.warning()` and a red-border flash.
- **`focusedNumeric(_, when:)`** — lights up the single editor-root
  Done button only for decimal/number keyboards.
- **Transitions**: `.asymmetric(insertion: .move(edge: .leading)
  .combined(with: .opacity), removal: .opacity.combined(with:
  .scale(scale: 0.9)))` + `.spring(response: 0.42, dampingFraction:
  0.82)` is the house list-row transition.

---

## 6. UX principles (still binding)

From [PROJECT.md §6](./PROJECT.md) and [llamas-cookbook-plan.md](./llamas-cookbook-plan.md):

1. **One-thumb operable.** All primary actions bottom half or toolbar.
2. **Input friction = death.** Quick-add, visible add buttons,
   Return-submits-and-refocuses, one conditional Done.
3. **Cook Mode is its own world.** Warmer bg, larger type (`ingredientCook`),
   slower pacing.
4. **Gestures have visible fallbacks.** Long-press Delete also has a
   context-menu Delete.
5. **Generous whitespace.**
6. **Silent save.** Only warn on Cancel when there's real loss.
7. **Forgiving.** Deletions confirmed. Timer cancel is destructive
   styled.

### Canonical interaction details (don't regress these)

- **Quantity chips**: two rows (wholes bigger/bolder, fractions
  smaller). Only measurable fractions — no 3/8 · 5/8 · 7/8. Tapping
  active deselects. Cook-mode scaling snaps to the same measurable set.
- **Ampersand fractions**: `2 & 1/2 cups` on display. Parser + chips
  still accept the space-only `2 1/2` for backward compat.
- **Detail-view ingredient row**: `•  2 & 1/2 cups  —  flour`. Quantity
  in accent semibold monospaced, em-dash divider, name in textPrimary.
- **Per-step timer flag**: clock glyph on step input (both quick-add
  and row editor). Cook Mode surfaces a timer affordance only for
  steps where `needsTimer == true`; the keyword extractor (oven,
  bake, grill, …) still runs but only as a label fallback.
- **Floating timer banner** stays pinned between the phase header and
  the scroll view. Tapping opens the running-timer sheet with a wheel
  MinutePicker (1–60 min).
- **Ready overlay**: full-screen terracotta cover with bell icon +
  `"{Label} timer ready!"`, embedded MinutePicker + filled Extend
  button (preserves `timerStepId` through expiry), outlined Stop as
  secondary. Vibration + haptic warning every 1.2s until Stop/Extend.

---

## 7. Signing & CI

- **Bundle id**: `com.llamascookbook.app` (widget: `com.llamascookbook.app.widget`).
- **Team**: `GYFN949Q5E`. **ASC app id**: `6762527184`.
- **CFBundleVersion** = Unix timestamp (`date -u +%s`).
- **MARKETING_VERSION** = `0.1.0` (bump in `project.yml` to promote).
- **Runner**: `macos-26` (arm64). Pinned explicitly — `macos-latest`
  still resolves to macOS 15 / Xcode 16, which won't satisfy ITMS-90725.
- **Xcode picker**: globs `/Applications/Xcode_26*.app`, filters out
  anything with `beta` in the name, picks the highest stable via
  `sort -V`. Falls back to beta with a `::warning::` only if no stable
  exists. **Do not replace this with a hardcoded path** — Apple ships
  point releases (`26.0.1`, `26.1.1`, `26.4.1`, …) and the picker
  needs to keep working as the runner image rotates. See §11 for the
  full incident.
- **`DEVELOPER_DIR` is required**, not just `xcode-select`. The
  `macos-26` runner image pre-sets `DEVELOPER_DIR` in its shell
  profile pointing at the image's default Xcode (currently beta 2),
  which silently overrides `xcode-select -s` for every subsequent
  step's fresh shell. The picker writes `DEVELOPER_DIR=…` to
  `$GITHUB_ENV` so the override travels with our chosen Xcode. This
  is the bug that made one CI run keep archiving with beta despite
  the picker correctly logging "Selecting Xcode_26.4.1.app".
- **Simulator runtime download**: `xcodebuild -downloadPlatform iOS`
  runs after Xcode selection. Idempotent no-op when the runtime is
  preinstalled; pulls the matching runtime when we end up on a beta
  Xcode whose iphonesimulator SDK doesn't match anything on disk.
- **Secrets** (GitHub Actions): `IOS_DIST_CERT_P12_BASE64/_PASSWORD`,
  `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`,
  `APPSTORE_API_KEY_P8_BASE64`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`.
- **Widget profile**: see [ROADMAP.md §0](./ROADMAP.md) — Apple Developer
  portal setup still owes one `.mobileprovision` + repo secret.

Dev cycle is Windows → git push → workflow_dispatch → ~20 min CI
iteration → TestFlight. No Xcode Previews locally, no `xcodebuild` on
Windows, no device-attached debug loop. Write accordingly.

---

## 8. Known limitations / deferred

- **Photos** — `Recipe.imageUri` exists on the model but is unused;
  no image picker, no gallery, no per-step images yet. Full plan in
  [Photo-Capability.md](./Photo-Capability.md). **Active next push.**
- **Multi-recipe Cook Mode** — today `CookingSession` holds a single
  active recipe. Cooking two dishes in parallel (common reality —
  pasta + sauce, main + side) requires a session model that holds N
  recipes, a switcher UI inside Cook Mode, and a timer registry that
  doesn't trample when one recipe's step fires while another's is
  pending. **Active next push.**
- **Settings screen** — still a stub. Nothing wired.
- **App icon** — placeholder generated in CI. Real 1024×1024 artwork
  not yet in the asset catalog.
- **Keep-awake during Cook Mode** — `UIApplication.shared.isIdleTimerDisabled = true` one-liner not yet wired.
- **iPad** — target family is iPhone only; no iPad layout.
- **Live Activity App Intents** — in-island +1/−1/cancel (iOS 17+)
  deferred.
- **Timer state persistence** — force-kill during a running timer
  ends the Live Activity but leaves the in-app state empty. Plan is
  to mirror `timerEndsAt / timerStepId / timerLabel` to `UserDefaults`.
- **Custom type** — Fraunces / Inter not bundled yet; `AppFont` uses
  system serif as placeholder.
- **iCloud sync** — not configured (SwiftData + CloudKit is the path).
- **PROJECT.md §2 "Where we are in the port"** table is slightly out
  of date — use the table in §1 of this doc until the next refresh.

---

## 9. What's next — two active feature pushes, then the aesthetic pass

### 9.1 Photos (active push #1)

Full plan in [Photo-Capability.md](./Photo-Capability.md). Two-slot
design — gallery per recipe + per-step images — sharing one
`ImageProcessing` / `RecipeImageView` / `PhotoCarouselView` /
`PhotoToggleButton` infrastructure. Three-PR sequence:

1. Schema + shared infra (`RecipePhoto` `@Model`, `RecipeStep.image`,
   `DraftRecipe` carries bytes through `apply(_:)` — see Photo-Capability §3).
2. Gallery button in Detail + Editor (carousel modal).
3. Per-step images (toggle in step row, thumbnail in Detail, full-width
   in Cook Mode).

The land-mine to remember: `Recipe.apply(_:)` does
`steps.removeAll()` and (will do) `photos.removeAll()` on every save.
If `DraftRecipe` doesn't carry image bytes through, every save silently
loses every image. Tests #6 + #11 in Photo-Capability §14 are the
must-pass guardrails.

### 9.2 Multi-recipe Cook Mode (active push #2)

The reality: pasta + sauce, main + side, a bake while a stovetop
simmers — cooks routinely run two recipes in parallel. Today
`CookingSession` is single-recipe (`@Observable` holding one `Recipe?`),
and the timer state in `CookModeView` (`timerStepId`, `timerEndsAt`,
`timerLabel`) is a single set of `@State`s. Going multi means:

- **Session model**: `CookingSession` becomes a list of "active
  cooks", each with its own current phase (Prep/Cook), step cursor,
  servings scale, and timer slot.
- **Switcher UI**: a tab strip or side-by-side header inside Cook
  Mode so the user flips between active recipes without exiting.
  Tuck-down (`.height(80)` detent) should show *all* active timers,
  not just the currently-foregrounded one.
- **Timer registry**: today's "one timer per Cook Mode" assumption
  is everywhere — `TimerLiveActivityController` holds one Activity,
  notifications are scheduled with a single identifier, the alarm
  player is one-shot. Each needs to key off `recipe.id` instead of
  being singletons.
- **Live Activity fan-out**: ActivityKit allows multiple concurrent
  Live Activities of the same type. Each active recipe with a running
  timer should get its own — Dynamic Island stacks (or rotates) them
  on iOS 17+.
- **Mark-as-cooked scope**: completing one recipe shouldn't dismiss
  Cook Mode if others are still active. Today the dismiss is implicit
  via `CookingSession.activeRecipe = nil`.

A separate plan doc will cover this before implementation lands.
Dependency note: the timer-state-persistence work (currently in
[ROADMAP §1](./ROADMAP.md)) becomes load-bearing here — restoring
*one* timer is a workaround, restoring *N* is non-optional once
multi-recipe ships.

### 9.3 Aesthetic / UX pass (queued, not active)

After photos + multi-recipe land. Candidates rough-ordered by
impact-per-effort:

1. **Custom typography.** Drop Fraunces + Inter into `Resources/`,
   wire through `AppFont`. Biggest single lift for "feels like a real
   cookbook".
2. **Real app icon.** 1024×1024 artwork featuring the llama mascot.
3. **Library card treatment.** Richer hero area (gallery first photo
   once available), stronger rhythm.
4. **Empty states.** More copy, more character, more mascot presence.
5. **Detail view rhythm.** Illustrated section dividers, drop cap on
   step 1, numbered-page feel.
6. **Cook Mode differentiation.** Bigger type scale, subtle texture.
7. **Transitions / micro-interactions.** Servings scaler jump, chip
   fill, timer start/stop could each get more character.
8. **Dark mode.** Whole palette is sRGB-explicit — needs a semantic
   `.primary` / `.secondary` bridge or light/dark variants per token.
9. **Liquid Glass adoption.** Currently opted out via
   `UIDesignRequiresCompatibility` (see §11). Apple removes the flag
   in iOS 27 SDK; adoption needs to land before that becomes mandatory.

Non-goals during the active feature pushes: no settings screen, no
iPad, no cloud sync. Those are their own tracks.

---

## 10. Recent DRY / optimization pass (2026-04-24)

Captured here so a future session doesn't re-do this work:

- Introduced `AppColor.onAccent`; removed 25 `Color(red: 1, green: 0.992, blue: 0.972)` literals across 10 files.
- Introduced `Recipe.sortedIngredients` / `.sortedSteps`; removed 4 copies of the `.sorted { $0.order < $1.order }` pattern (Cook Mode, Detail, Export, DraftRecipe).
- Introduced `Ingredient.display(scaledBy:)` returning `Display { quantity, unit, takesOf, name, measure, fullLine }`; collapsed the three-site copy of "format qty + plural unit + 'of' connector + name" into one helper.
- Introduced `ClockFormat.mmss(_:)`; removed 2 duplicate `formatClock` copies in `CookModeView` + `RunningTimerSheet`.
- Removed `TimerNotifications.capitalizedFirst` — uses the shared `StringCase.capitalizeFirst` now.
- Routed `DraftRecipe.toDraft()` through the new sorted helpers.

Result: ~60 LOC removed net, zero behavior change, single source of
truth for each transformation.

---

## 11. SDK 26 + Liquid Glass opt-out (2026-04-26)

> **Why this section exists:** Apple's ITMS-90725 cutoff on
> **2026-04-28** required all TestFlight uploads to be built with the
> iOS 26 SDK. The bump itself was three small file edits, but CI
> surfaced two surprises that cost real cycles. Capturing the
> lessons here so the next image rotation / Xcode beta drop doesn't
> re-bite. Companion doc: [SDK-Update-Plan.md](./SDK-Update-Plan.md).

### What changed in code

- **[`.github/workflows/ios-native-ci.yml`](./.github/workflows/ios-native-ci.yml)** — runner pinned to `macos-26`, added `Select Xcode 26` (stable-preferring glob), `Print toolchain` (logs `iphoneos --show-sdk-version` so the SDK is provable from the log alone), and `Ensure iOS Simulator runtime` (`xcodebuild -downloadPlatform iOS`).
- **[`ios-native/Resources/AppInfo.plist`](./ios-native/Resources/AppInfo.plist)** — added `UIDesignRequiresCompatibility = true` next to `ITSAppUsesNonExemptEncryption`. Lives in the plist (not as an `INFOPLIST_KEY_*` setting in `project.yml`) because the main app already uses an explicit Info.plist via `GENERATE_INFOPLIST_FILE: NO`.
- **`Generate placeholder app icon` step** — hardened the ImageMagick command with `-alpha off`, `-colorspace sRGB`, and `-define png:color-type=2` so the icon ships as opaque sRGB. Apple has always required this; Xcode 16 tolerated RGBA, Xcode 27 likely won't.
- **`IPHONEOS_DEPLOYMENT_TARGET` stays at 18.0.** Build SDK and deployment target are different things — we build *with* iOS 26 SDK, we still run *on* iOS 18+.

### Surprise #1 — naive `sort -V` picks the beta

`actions/runner-images` ships **six** Xcodes side-by-side on `macos-26`: `26.0.1`, `26.1.1`, `26.2`, `26.3`, `26.4.1`, plus the latest beta (currently `Xcode_26.5_beta_2.app`). A glob + `sort -V | tail -1` picks the beta because `26.5 > 26.4`. Fix: filter out anything with `beta` in the filename first, fall back to beta only if no stable matches. **Do not** hardcode the app name — point releases roll forward (`26.4` → `26.4.1` → `26.5.x`) and a hardcoded path fails fast.

### Surprise #2 — beta SDKs trip actool on device archives

When the picker landed on `Xcode_26.5_beta_2.app`, `actool` failed `CompileAssetCatalogVariant thinned` with:

```
error: No simulator runtime version from ["23B86", "23C54", "23E254a"]
available to use with iphonesimulator SDK version 23F5054d
```

`actool` cross-checks simulator runtimes during asset thinning — even on `--platform iphoneos` (device) archives, where simulator should be irrelevant. Beta Xcode SDKs ship with build numbers that don't match any preinstalled runtime. Two-part defense:

1. Prefer stable Xcode (Surprise #1's fix sidesteps this in practice).
2. `xcodebuild -downloadPlatform iOS` as belt-and-suspenders — fast no-op when runtimes match, ~3 min download when they don't.

### Liquid Glass — deferred deliberately

Building with the iOS 26 SDK auto-opts the app into Liquid Glass on iOS 26 devices. `UIDesignRequiresCompatibility = true` keeps the legacy chrome rendering. The flag is **temporary** — Apple has signaled removal in iOS 27. Adoption is queued as part of the aesthetic / UX pass in §9; until then we keep the terracotta + cream system intact and audit deliberately on a real device.

### What to watch for next

- **Image rotation**: when `actions/runner-images` ships a new `macos-26` image, the `Print toolchain` step's `iphoneos --show-sdk-version` line is the canary. If it drops below 26.x, ITMS-90725 returns. The picker's `::warning::` line will also appear in the log if only a beta is available.
- **Xcode 27 release**: `UIDesignRequiresCompatibility` goes away. Liquid Glass adoption needs to land before that build SDK becomes mandatory (analogous deadline pattern).
- **Icon flags**: leave the `-alpha off` / `sRGB` / `color-type=2` flags in even when we replace the placeholder with real artwork. They're correct regardless.

---

## 12. Recipe import pipeline (2026-04-26)

The recipe import flow grew significantly in this session. Captured
here so a future session knows what was learned and doesn't re-litigate
the parser heuristics.

### Architecture

```
ImportRecipeView
   ├─ "From a link" — URL field + Fetch button
   │     └─ RecipeURLImporter.fetch(url) → Outcome
   │           ├─ .full(draft)    → straight to editor preview
   │           ├─ .partial(...)   → seed textbox + info banner
   │           ├─ .blocked(...)   → warning banner ("paste the caption")
   │           └─ .failed(msg)    → error banner
   │
   └─ "From text" — paste box + live check panel
         └─ RecipeImporter.parse(text) → DraftRecipe
```

`RecipeURLImporter` routes by host: TikTok via oEmbed, Pinterest via
HTML scrape, blogs via JSON-LD/OG, Instagram + Facebook return a
"paste the caption" hint (their public surfaces don't expose caption
text without auth).

### Hybrid AI parser — best-of, not AI-first

Inside `RecipeURLImporter.aiParse(_:sourceUrl:)`, both parsers run
on every messy URL path and `pickBetterDraft` chooses:

1. If only one side returns a usable draft, use it.
2. If AI's longest step > 200 chars → AI mashed actions, regex wins.
3. If regex got 5+ steps and AI has < 70% of that count → AI under-split, regex wins.
4. Otherwise AI wins (it's better at title cleanup, qty/unit splitting, parenthetical lifting).

**Why not AI-first**: a TikTok caption that came back from the LLM
with all 13 cooking steps glued into Step 4 is what forced this. The
regex pipeline is a strong baseline — let it win when AI loses.

### Caption-style fallback (the no-blank-line trap)

TikTok's oEmbed response uses single `\n` line breaks, not blank-line
section separators. Without a defense, blank-line block parsing
collapses everything into the title block and emits zero steps —
which means `makeRegexDraft` returns nil, AI's bad output wins by
default, and step 4 inherits the recipe.

Defense: `parseBlocks` checks for the no-blank-line shape (≤ 2 blocks
but ≥ 6 total lines) and hands off to `parseUnstructuredLines`,
which classifies each line independently using `looksLikeIngredient`
(matches `<number><unit>` at the start of the line). For the user's
sourdough TikTok, this produces ~13 steps regardless of whether
oEmbed returns blank lines.

### Step parsing — what the heuristics actually do

`splitIntoSteps` is a four-level fallback:

1. **Newlines** — cleanest signal.
2. **Numbered markers** — `Step 1:`, `1.`, `1)`. Drops the marker.
3. **Comma-then / comma-digit** — `,\s+(?=[Tt]hen\b|\d)`. Caption
   authors glue waits to follow-up actions with commas
   (`"…1 hour, then do 8 folds"`); the lookahead requires "then" or a
   digit so prose lists like "flour, salt, water" stay intact.
4. **Sentence boundaries** — letter + period + space + (capital or
   digit). Last resort.

Post-split enrichment in `enrichStep`:

- **`liftWhileClause`** — extract parenthetical content first
  (`"(start preheating while dough is proofing)"` → cleaned
  specialNote), then fall back to bare `while X` splits. This is the
  fix for the trailing-`)` bug.
- **`hasTimerSignal`** — auto-flag `needsTimer = true` when a
  duration appears, *but* require it to be followed by punctuation,
  end-of-text, or a connector word (`with`, `then`, `until`, `in`,
  …). This is the compound-noun guard — `"8 hour sourdough"` is no
  longer a timer signal because `"sourdough"` isn't a stopword.

Cook Mode's `extractDurationSeconds` handles ranges by preferring the
*smaller* number (`"3-4 hours"` → 3 hours). Rationale: the user can
extend a running timer; they can't take time back once it's elapsed.

### Tags are user-controlled, not auto-populated

Both URL paths used to lift hashtags / JSON-LD `keywords` into
`draft.tags`. Removed deliberately — categories are the user's call,
picked from `TagPresets` (which now includes `sourdough`) in the
editor. Hashtags are still *stripped* from the caption text so
`#fyp #cooking` doesn't show up glued to a step.

### Title cleanup

`stripTitleLabel` handles three caption conventions in order:
`"Title: Foo"` (old labeled), `"Recipe👇 Foo"` (TikTok-style intro),
and trailing emoji/exclamation runs (`"Sourdough!😍🙌🏻"` → `"Sourdough"`).

### What the user-facing UX looks like

Inside `ImportRecipeView`:

- **Single textbox** for the whole recipe — no separate
  Title/Ingredients/Steps fields.
- **Live check panel above** showing `Title — <text>`, `First
  ingredient — <text>`, `First Step — <text>` with animated
  symbol-replace check icon as the parser pulls more out of the
  paste.
- **Custom placeholder** with horizontal divider lines visually
  separating title / ingredients / steps zones, so the blank-line
  convention is communicated by structure, not prose.
- **Single tip line** below the check panel: "First line is your
  recipe title — blank lines separate the sections below."
- **Keyboard scroll** anchors the *editor* to the bottom of the
  visible area on focus; TextEditor's internal scroll handles cursor
  visibility from there. No per-keystroke parent scrolls.
