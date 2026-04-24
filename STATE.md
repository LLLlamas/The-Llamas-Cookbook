# Llamas Cookbook — State of the App

> Snapshot: **2026-04-24**. Supersedes the "current status" and layout
> sections of [PROJECT.md](./PROJECT.md). The product vision and UX
> principles in [llamas-cookbook-plan.md](./llamas-cookbook-plan.md)
> remain authoritative; everything tech-stack / implementation-detail
> below is the newer source of truth.

---

## TL;DR — we're in a strong spot

Core CRUD is done end-to-end. The Swift native port has reached feature
parity with the archived RN app on every screen except Settings, and
has gone past it on several: Conversions reference + calculator, text
import, ShareLink export, Live Activity / Dynamic Island timer, A–Z
letter index, drag-to-reorder steps, and a minimizable Cook Mode that
can tuck to a small detent while the user browses the rest of the app.

The foundation is tight, deduped, and themed. The next pass is
**frontend / aesthetic / UX refinement** — not features.

---

## 1. What works, one line per capability

| Capability | Where it lives | Notes |
|---|---|---|
| Library list (sorted, filtered) | [LibraryView](ios-native/Sources/Views/Library/LibraryView.swift) | All · Favorites · one chip per tag. Long-press / context-menu Delete. |
| A–Z letter scrub | [LibraryView:338](ios-native/Sources/Views/Library/LibraryView.swift:338) | Right-edge strip, tap or drag to jump. Dimmed letters still route to the next populated one. |
| Mascot watermark | [LibraryView:87](ios-native/Sources/Views/Library/LibraryView.swift:87) | 6% opacity llama pinned behind the list. |
| Add / Import FAB | [LibraryView:250](ios-native/Sources/Views/Library/LibraryView.swift:250) | Menu: "New recipe" · "Import from text". |
| Recipe Detail | [RecipeDetailView](ios-native/Sources/Views/Detail/RecipeDetailView.swift) | Title, summary, times, tag pills, ingredients with bullet + em-dash, numbered steps with timer glyph, quoted notes, source link, signature row. |
| Favorite toggle | [RecipeDetailView:117](ios-native/Sources/Views/Detail/RecipeDetailView.swift:117) | Heart toolbar button, syncs `updatedAt`. |
| Export | [RecipeExport.swift](ios-native/Sources/Lib/RecipeExport.swift) + ShareLink in Detail | Plain-text output — Notes, Messages, Mail, AirDrop all work. |
| Conversions sheet | [ConversionsView](ios-native/Sources/Views/Detail/ConversionsView.swift) | Static reference cards + **live calculator** (volume, weight, temperature, cross-category guard). |
| Recipe Editor | [RecipeEditorView](ios-native/Sources/Views/Editor/RecipeEditorView.swift) | Hero row, required title, summary, quick-add rows for ingredients/steps, per-step timer toggle, tag input with presets, drag-to-reorder steps, keyboard management, spring animations on row add/remove. |
| Text Import | [ImportRecipeView](ios-native/Sources/Views/Library/ImportRecipeView.swift) + [RecipeImporter](ios-native/Sources/Lib/RecipeImporter.swift) | Paste box, live format checklist (Title / Ingredients / Steps), editor pre-filled for review before save. First-run help sheet ([ImportHelpView](ios-native/Sources/Views/Library/ImportHelpView.swift)). |
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
| Alarm sound | Bundled `timer-alarm.caf` generated at CI time (ffmpeg + afconvert), played on loop via `AVAudioPlayer` while the ready overlay is visible. Falls back silently when missing. |
| Haptics | [Haptics](ios-native/Sources/Lib/Haptics.swift) wrapper around UIKit feedback generators. |
| Icons | SF Symbols only. |
| Project file | [XcodeGen](https://github.com/yonaskolb/XcodeGen) — [`project.yml`](ios-native/project.yml), `.xcodeproj` gitignored, generated per CI run. |
| Build | GitHub Actions `macos-latest` → `xcodebuild archive` → TestFlight upload via `xcrun altool`. |
| Min iOS | 18.0. |
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
│   │   │   ├── IngredientDisplay.swift       ← ← new: `Ingredient.display(scaledBy:)` + `.measure` / `.fullLine`
│   │   │   ├── KeyboardDismiss.swift         ← `focusedNumeric(_, when:)` modifier
│   │   │   ├── Plural.swift                  ← unit pluralization + `needsConnector`
│   │   │   ├── Quantity.swift                ← parse / format / scale / chip split + `ClockFormat.mmss` + `StringCase`
│   │   │   ├── RecipeExport.swift            ← plain-text exporter
│   │   │   ├── RecipeImporter.swift          ← text → DraftRecipe parser
│   │   │   ├── Shake.swift                   ← counter-driven horizontal shake effect
│   │   │   ├── TagPresets.swift              ← canonical preset tag list
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
│   │       │   └── ConversionsView.swift     ← reference cards + live calculator
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
- **`RecipeImporter.parse(_:)`** — input validation happens here; the
  editor gets a clean `DraftRecipe`.
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

## 7. Signing & CI (unchanged)

- **Bundle id**: `com.llamascookbook.app` (widget: `com.llamascookbook.app.widget`).
- **Team**: `GYFN949Q5E`. **ASC app id**: `6762527184`.
- **CFBundleVersion** = Unix timestamp (`date -u +%s`).
- **MARKETING_VERSION** = `0.1.0` (bump in `project.yml` to promote).
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

- **Settings screen** — still a stub. Nothing wired.
- **App icon** — placeholder generated in CI. Real 1024×1024 artwork
  not yet in the asset catalog.
- **Hero image** — `Recipe.imageUri` exists on the model; no image
  picker, no display.
- **Keep-awake during Cook Mode** — `UIApplication.shared.isIdleTimerDisabled = true` one-liner not yet wired.
- **iPad** — target family is iPhone only; no iPad layout.
- **URL import** — text-paste covers manual; no URL scraper.
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

## 9. What's next — the aesthetic / UX pass

Content below is the *framing* for the next session, not a commitment.

**The app is functionally complete for personal use.** What it hasn't
had yet is a deliberate visual design pass. Candidates for that pass,
roughly ordered by impact-per-effort:

1. **Custom typography.** Drop Fraunces + Inter into `Resources/`,
   wire through `AppFont`. Biggest single lift for "feels like a real
   cookbook" — current system-serif is a placeholder.
2. **Real app icon.** 1024×1024 artwork featuring the llama mascot,
   cream + terracotta palette. Remove the CI placeholder step.
3. **Library card treatment.** Cards are currently clean but flat.
   Could benefit from a richer hero area (hero image once that's in,
   or a generated fallback motif per tag), stronger rhythm, better
   use of vertical whitespace.
4. **Empty states.** `EmptyLibraryView` and the empty-filter state
   are functional but spartan. Could land more copy, more character,
   more mascot presence.
5. **Detail view rhythm.** Section dividers are small accent capsules
   today — could push further (illustrated section dividers, numbered
   page feel, drop caps on step 1).
6. **Cook Mode differentiation.** Already uses a warmer bg; could push
   further (bigger type scale, simplified chrome, maybe a subtle
   texture on the background).
7. **Transitions / micro-interactions.** Current animations are
   solid but utilitarian — servings scaler jump, chip fill, timer
   start/stop could each get a touch more character.
8. **Dark mode.** Not tested. Whole palette is defined in sRGB — a
   semantic dark-mode pass would mean introducing `.primary` /
   `.secondary` systemColor bridges or explicit light/dark variants.

Non-goals to consciously hold: don't add features. No settings
screen, no iPad, no image picker, no cloud sync during the aesthetic
pass — those are their own tracks.

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
