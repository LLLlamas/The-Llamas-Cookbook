# Llamas Cookbook — Project Reference

> The source of truth for everyone (human or AI) picking this project back up.
> Last meaningful update: 2026-04-23.
> Original design spec with full rationale and JTBD: [llamas-cookbook-plan.md](./llamas-cookbook-plan.md).
> This document supersedes the tech-stack sections of that spec; the product vision and UX principles are still authoritative.

---

## 1. What this is

**Llamas Cookbook** is a personal, offline-first iOS recipe keeper. One human's recipes, in one clean place, with a dedicated Cook Mode for the stove.

It is explicitly **not** a recipe discovery app, social app, or AI-assisted meal planner. The user already has their recipes — they're just scattered. Llamas Cookbook is where they land.

### Elevator pitch
> Llamas Cookbook is your personal iOS cookbook. Save any recipe once, see it all in one place, and follow along hands-free while you cook. No more 12 open tabs.

### Target user — "The Home Cook Re-Organizer"
Someone who cooks a handful of recipes on rotation plus occasional new ones. They already have their recipes — bookmarks, screenshots, scraps, Notes entries, Google tabs. They want one clean place.

### Jobs-to-be-done
| When I'm… | I want to… | So that… |
|---|---|---|
| Discovering a recipe online | Save it to my cookbook | I can find it later without 40 bookmarks |
| Deciding what to cook tonight | Browse my saved recipes | I can pick from what I already trust |
| Actually cooking | See the recipe huge, screen-on, hands-free-ish | I don't lose my place or burn the onions |
| Tweaking a recipe | Edit it or add a note | My cookbook reflects how *I* actually make it |
| Checking rotation | See when I last made something | I don't cook the same thing three times this week |

---

## 2. Current status (2026-04-23)

**Tech pivot:** the app was originally built with Expo / React Native and shipped to TestFlight from a Windows developer machine via GitHub Actions + EAS, then GitHub Actions + custom macOS signing. On 2026-04-23 we started porting to native SwiftUI + SwiftData. The RN source is now archived under [`outdated/rn-expo/`](./outdated/rn-expo) and its workflow is disabled; the live app is Swift only.

**Where we are in the port:**

| Screen | RN (archived) | Swift |
|---|---|---|
| Library / home | ✅ | ✅ — list + empty state + tag/favorite filter + long-press delete + FAB menu (New / Import) |
| Recipe Detail | ✅ | ✅ — title, summary, times, tags, ingredients (qty · em-dash · name + Conversions chip), steps (timer glyph for timed steps), notes, reference link, signature, ShareLink export, delete |
| Recipe Editor | ✅ | ✅ — hero row, required title, ingredient quick-add (qty/unit/name validation + error glow + shake), step quick-add (with per-step clock toggle), tag input, notes, reference link, optional details (servings + cook time), toolbar Save, single conditional keyboard Done for numeric fields, tap-away keyboard dismiss, spring transitions on row insert/remove |
| Cook Mode | ✅ | ✅ — two-phase (prep ↔ cook) with prominent pill toggle, servings scaler, per-step `needsTimer` flag (keyword still used as the timer label), floating timer banner pinned at top, tap-banner adjust sheet (extend or cancel), full-screen ready overlay with extend wheel + Stop |
| Conversions reference | — | ✅ — sheet with Volume (US), US→Metric, Weight, Butter, Common Ingredients, Oven Temps |
| Import from text | — | ✅ — paste box with live format checklist (Title / Ingredients / Steps), parser pre-fills the editor for review |
| Export | — | ✅ — Detail-view `ShareLink` emits plain text (works for Notes, Messages, Mail, etc.) |
| Settings | ✅ (minimal) | ⬜ not started |
| Llama mascot | ✅ (SVG) | ✅ (SwiftUI Canvas port) |

Build pipeline: Swift archive + TestFlight upload via GitHub Actions on `macos-latest`. Fully functional — placeholder app icon, single 1024×1024 in the asset catalog, auto-downsized by actool at build time. Encryption-export compliance is declared `NO` via `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption` in [project.yml](./ios-native/project.yml), so TestFlight no longer prompts each build.

---

## 3. Tech stack

| Layer | Choice | Why |
|---|---|---|
| Language | Swift 5.10 | Native iOS dev. |
| UI | SwiftUI (iOS 18+) | No UIKit-wrapping layer; full access to new APIs (`.task(id:)`, `scrollDismissesKeyboard`, `InputAccessoryView`, `TimelineView`, etc.). |
| State | `@State`, `@Observation` (via `@Model`) | Built-in. No Combine, no Redux-likes. |
| Persistence | **SwiftData** (iOS 17+) | Simpler than Core Data. `@Model` classes auto-conform to `PersistentModel` + `Observable`. |
| Navigation | `NavigationStack` + `.sheet` + `.fullScreenCover` | Library → Detail uses `NavigationLink(value:)` with `navigationDestination(for:)`. Editor is a sheet with its own nested stack. Cook Mode is a full-screen cover to match the old "full-screen modal" feel. |
| Haptics | `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` / `UISelectionFeedbackGenerator` | Wrapped in [`Haptics`](./ios-native/Sources/Lib/Haptics.swift). |
| Alarm vibration | `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)` looped every 1.2s via Task | Only path to repeating vibration on iOS from foreground. No bundled audio. |
| Keep-awake | `UIApplication.shared.isIdleTimerDisabled` (planned, not yet wired in Cook Mode) | One line. |
| Icons | SF Symbols | No 3rd-party icon package. |
| Project file | [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` → `.xcodeproj`) | Generated on every CI run; `.xcodeproj` is gitignored. Lets Windows devs avoid ever opening or editing the pbxproj. |
| Build CI | GitHub Actions on `macos-latest` | Archive → Export → upload to TestFlight via `xcrun altool`. Uses the same signing secrets Lorenzo set up for the RN TestFlight workflow. |
| Minimum iOS | 18.0 | Ceiling was `"cutting edge / small reach" vs. the reach of SwiftData + newest APIs; `18.0` wins because this is a personal app with one known user. |
| Target devices | iPhone only | iPad was dropped because (a) multitasking requires all four orientations and (b) we're not shipping a scaled-up iPad UI. Can add back by widening `TARGETED_DEVICE_FAMILY` once a proper iPad layout exists. |

### What the app does NOT use (and won't without a clear reason)

- No UIKit views (pure SwiftUI — use `UIViewRepresentable` only as a last resort).
- No Combine (`@Observable` + SwiftData replaces most publisher patterns).
- No CocoaPods / SPM packages yet — the project is vanilla.
- No Core Data — SwiftData only.

---

## 4. Project layout

```
The-Llamas-Cookbook/
├── PROJECT.md                  ← this file
├── README.md                   ← short onboarding hook
├── llamas-cookbook-plan.md     ← original product spec (vision / JTBD still authoritative)
├── .github/
│   └── workflows/
│       └── ios-native-ci.yml   ← Swift TestFlight workflow (manual dispatch)
├── ios-native/                 ← the Swift app
│   ├── project.yml             ← XcodeGen config (also declares no-encryption export compliance)
│   ├── README.md               ← port-specific notes
│   ├── Sources/
│   │   ├── App/                ← @main + RootView (sets UIView.appearance().tintColor = accent)
│   │   ├── Models/             ← Recipe, Ingredient, RecipeStep (SwiftData) + DraftRecipe
│   │   ├── Theme/              ← AppColor, AppFont, AppSpacing, AppRadius
│   │   ├── Lib/                ← Haptics, Quantity, Plural, KeyboardDismiss, Shake,
│   │   │                         RecipeExport, RecipeImporter, Conversions
│   │   └── Views/
│   │       ├── Components/     ← LlamaMascot, EmptyLibraryView, FlowRow layout
│   │       ├── Library/        ← LibraryView, RecipeCardView, ImportRecipeView
│   │       ├── Detail/         ← RecipeDetailView, ConversionsView
│   │       ├── Cook/           ← CookModeView (+ TimerReadyOverlay, RunningTimerSheet, MinutePicker)
│   │       └── Editor/         ← RecipeEditorView, IngredientQuickAdd, IngredientRowEditor,
│   │                             StepQuickAdd (+ TimerToggleButton), StepRowEditor, TagInputView, Chips/
│   └── Resources/
│       └── Assets.xcassets/    ← AppIcon (generated at CI time — see below)
├── outdated/
│   └── rn-expo/                ← archived React Native / Expo implementation
└── .gitignore / .gitattributes / .claude/ …
```

### Asset catalog

`Resources/Assets.xcassets/AppIcon.appiconset/` uses the iOS 14+ single-size universal format — one `1024×1024 AppIcon.png` is all that's committed. Xcode's asset compiler (`actool`) auto-downsizes at build time. The PNG itself is regenerated every CI run by an ImageMagick step (solid terracotta + cream circle + two dark dots as a minimal llama face). Swap the CI step out and commit real artwork when ready.

---

## 5. Data model

SwiftData `@Model` classes under [ios-native/Sources/Models/Recipe.swift](./ios-native/Sources/Models/Recipe.swift):

```swift
@Model final class Recipe {
    var id: UUID
    var title: String
    var summary: String?             // renamed from `description` (reserved name)
    var sourceUrl: String?           // optional reference link
    var imageUri: String?            // not yet wired to UI (no image picker port yet)
    var servings: Int?
    var cookTimeMinutes: Int?        // drives the per-step timer
    var notes: String
    var favorite: Bool
    var tags: [String]               // lowercase, sorted by user order, capitalized for display
    var lastCookedAt: Date?
    var cookCount: Int
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Ingredient.recipe) var ingredients: [Ingredient]
    @Relationship(deleteRule: .cascade, inverse: \RecipeStep.recipe) var steps: [RecipeStep]

    func markCooked() { … }
}

@Model final class Ingredient {
    var id: UUID
    var quantity: String?            // stored as string ("3 1/4") so we can preserve mixed fractions
    var unit: String?
    var name: String
    var order: Int
    var recipe: Recipe?
}

@Model final class RecipeStep {       // renamed from `Step` to avoid name collisions
    var id: UUID
    var order: Int
    var text: String
    var needsTimer: Bool = false      // user-set in editor; drives Cook Mode timer chip + auto-start
    var recipe: Recipe?
}
```

### Why `DraftRecipe`?

`Recipe` is a reference type managed by SwiftData. Editing it directly would live-save every keystroke. To keep Cancel non-destructive, the editor builds a plain-struct [`DraftRecipe`](./ios-native/Sources/Models/DraftRecipe.swift) on open and only calls `apply(_ draft:)` on Save.

---

## 6. UX principles (from the spec, still binding)

1. **One-thumb operable.** Everything reachable with the thumb on a 6.1" iPhone. Primary actions live in the bottom half of the screen OR in the top toolbar — never the middle.
2. **Input friction = death.** Adding a recipe cannot feel tedious. Quick-add rows with clear labels, visible add buttons, Return-submits-and-refocuses, no "Next" keys (all inputs show "Done" — a tap on an empty field or the field border dismisses the keyboard).
3. **Cook Mode is its own world.** Warmer background, larger type, calm pacing. The user always knows "I'm cooking now, rules are different."
4. **Gestures have visible fallbacks.** Long-press to delete on a card *also* has a context-menu Delete item. Every gesture is discoverable.
5. **Generous whitespace.** Recipes are already dense — the UI must not add to that.
6. **Silent save.** No "unsaved changes" warnings except when Cancel would lose real work.
7. **Forgiving.** Deletions are confirmed. Nothing is "accidentally" gone.

### Quantity chip rules (hard-won)

- Two rows: whole numbers (1, 2, 3, 4, 5, 6, 8, 10, 12) on top — slightly bigger, bolder — and fractions (1/8, 1/4, 1/3, 1/2, 2/3, 3/4) below.
- **Only measurable fractions.** Intentionally omit 3/8, 5/8, 7/8, 1/16 — a home cook has no way to measure them.
- Tap a whole and a fraction to get the combined value.
- Tapping the active chip deselects it.
- When Cook Mode scales ingredients, `Quantity.format` snaps the result to the nearest tangible fraction — never surfaces `0.42 tsp`.

### Display: ampersand fractions and pluralization

- Stored quantities use `&` between the whole and fractional parts: `2 & 1/2 cups`. Both parser and chips accept the older space-only `2 1/2` form for backward compatibility.
- Units pluralize on display via `Plural.unit(_, for:)` — `1 cup` / `2 cups` / `1/2 cup` (fraction stays singular). Common abbreviations (`tbsp`, `tsp`, `oz`, `g`, `kg`, `ml`, `l`, …) never pluralize. Full words (`cup`, `clove`, `pinch`) follow English -s/-es rules.
- Detail-view ingredient row layout: `•  2 & 1/2 cups  —  flour`. Quantity+unit in accent semibold monospaced, em-dash divider in muted divider color, name in primary text. Falls back gracefully when there's no measure (`•  salt`).

### Per-step timer flag

Each step has a `needsTimer: Bool`. The editor renders a `TimerToggleButton` (clock icon) on the right side of the step input — both in `StepQuickAdd` (new step) and `StepRowEditor` (existing step). Tapping toggles the flag.

In Cook Mode, only steps where `needsTimer == true` show a timer affordance. The keyword extractor (`oven`, `bake`, `grill`, `skillet`, `stove`, `pan`, `pot`, `simmer`, `boil`) still runs — but only as a label fallback (defaults to "cook"). Tapping a `needsTimer` step to check it off auto-starts the timer (bound to `recipe.cookTimeMinutes`). Only one timer runs at a time.

While the timer is running, a **floating timer banner** is pinned between the phase header and the scroll view — so the countdown stays visible no matter where the user scrolls. Tapping the banner opens a `RunningTimerSheet` with a wheel `MinutePicker` (1–60 min) to extend, plus a destructive Cancel.

On expiry: full-screen terracotta cover with bell icon + `"{Label} timer ready!"`. The cover includes its own embedded `MinutePicker` + filled "Extend by N min" button — extending starts a fresh countdown of just those minutes (`timerStepId` is preserved through expiry so the floating banner keeps its step context after extension). Stop is the secondary outlined action that clears the step context and dismisses. Phone vibrates + warns via haptic every 1.2s until Stop or Extend. Task is cancelled on disappear so vibration never leaks out of the screen.

### Conversions reference

Static kitchen-conversion data lives in `Lib/Conversions.swift` (Volume US, US→Metric, Weight, Butter, Common Ingredients, Oven Temps). Surfaced via a `Conversions` capsule chip on the right side of the Ingredients section header in `RecipeDetailView` — opens `ConversionsView` as a `.large` sheet with drag indicator. Each section is a card; each row is `lhs → rhs` with an optional muted secondary note.

### Export / Import

- **Export** — `recipe.exportText` (in `Lib/RecipeExport.swift`) generates plain text with title, meta, bulleted ingredients (pluralized + ampersand), numbered steps, notes, source URL. Detail-view toolbar `ShareLink` hands it to the iOS share sheet — Notes, Messages, Mail, AirDrop all work.
- **Import** — `RecipeImporter.parse(_:)` (in `Lib/RecipeImporter.swift`) is a best-effort parser for pasted text. Recognized section headers: `Ingredients`, `Steps` / `Instructions` / `Directions` / `Method`, `Notes`. Bullet styles: `• - * – —`. Numbered or unnumbered steps. Meta extraction: `Serves N`, `Cook: N min`, `Source: url`. Output is a `DraftRecipe` — never directly inserted into SwiftData; the `ImportRecipeView` pushes the editor pre-filled so the user reviews and saves.
- **Import format checklist** — `ImportRecipeView` shows a small "Format" card above the paste area with three pills: `[✓ Title] · [○ Ingredients] · [○ Steps]`. The checks update live as the parser actually picks them up — so misspelled section headers stay unticked, alerting the user to fix them before saving.

### Keyboard dismiss strategy

The editor previously stacked one keyboard-toolbar Done per numeric TextField (3+ visible at once). Consolidated to a single conditional Done:

- Single `@FocusState private var isNumericFocused: Bool` lives in `RecipeEditorView`.
- Threaded into `IngredientQuickAdd` and `IngredientRowEditor` as a `FocusState<Bool>.Binding` parameter.
- The `focusedNumeric(_, when:)` extension on `View` (in `Lib/KeyboardDismiss.swift`) attaches the binding only when the keyboard type is `.decimalPad` or `.numberPad`. Text-keyboard fields ignore it.
- One `ToolbarItemGroup(placement: .keyboard)` at the editor root renders the Done button only when `isNumericFocused == true`.
- Text fields use `.submitLabel(.done)` + `.onSubmit { … }` — Return acts as Done, no toolbar required.
- Editor scroll view has `.scrollDismissesKeyboard(.immediately)` (any scroll dismisses) plus a background `.onTapGesture` (tapping the whitespace between cards dismisses). Buttons and TextFields take their own taps first.
- App init sets `UIView.appearance().tintColor = UIColor(AppColor.accent)` so the keyboard Return key (and text caret) match the theme.

### Animations

Subtle, not showy:

- `Lib/Shake.swift` — counter-driven `ShakeEffect` GeometryEffect. Bump `count += 1` to play one ~0.4s horizontal shake. Used on `IngredientQuickAdd` validation errors alongside the existing red-border flash and warning haptic.
- `RecipeEditorView` ingredient + step lists use `.transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity.combined(with: .scale(scale: 0.9))))` driven by spring `.animation(value: list.count)` — rows slide in from the leading edge and shrink-fade out on delete.
- Cook Mode floating timer banner uses `.transition(.move(edge: .top).combined(with: .opacity))` with a spring `.animation(value: timerEndsAt)` driver.
- Import format checklist pills use `.contentTransition(.symbolEffect(.replace))` so the check icon swap is smooth.

---

## 7. Signing & distribution

**Bundle id:** `com.llamascookbook.app`. Same as the (archived) RN app — a single App Store Connect record, no parallel install.

**Apple Developer Team:** `GYFN949Q5E`.

**ASC app id:** `6762527184`.

**Signing secrets (GitHub Actions repo secrets):**

| Name | What |
|---|---|
| `IOS_DIST_CERT_P12_BASE64` | base64 of the distribution `.p12` |
| `IOS_DIST_CERT_P12_PASSWORD` | password for that `.p12` |
| `IOS_PROVISIONING_PROFILE_BASE64` | base64 of the App Store `.mobileprovision` |
| `APPSTORE_API_KEY_P8_BASE64` | base64 of `AuthKey_<KEYID>.p8` |
| `APPSTORE_API_KEY_ID` | 10-char key id |
| `APPSTORE_API_ISSUER_ID` | issuer UUID |

The RN workflow and the Swift workflow share these secrets. Don't run both TestFlight workflows at the same time — the most recent upload wins on TestFlight.

### Build number strategy

Swift `CFBundleVersion` = `github.run_number + 10000`. The offset keeps Swift builds in a different number range than the old RN workflow ever used (RN was at single digits when we pivoted), so App Store Connect's build history stays coherent across the cutover.

`MARKETING_VERSION` is `0.1.0` in [project.yml](./ios-native/project.yml) — bump manually when promoting to a new user-facing version.

---

## 8. CI / development workflow

The developer (Lorenzo) is on **Windows**. Swift can't build iOS apps on Windows — every build runs on `macos-latest` in GitHub Actions. There is no local Xcode iteration loop.

**Dev cycle:**

1. Edit Swift in VS Code / Windsurf / whatever.
2. `git add` / `git commit` / `git push`.
3. Trigger [`ios-native-ci.yml`](./.github/workflows/ios-native-ci.yml) manually (`workflow_dispatch`). Wait ~15–25 min.
4. TestFlight gets the new build automatically (uncheck "Upload to TestFlight" in the dispatch form if you just want to produce an `.ipa` artifact).
5. iPhone pulls the build via TestFlight. Open, test, report.

**What this means in practice:**

- Every SwiftUI question costs one CI cycle (~20 min). Be thoughtful.
- No Xcode Previews. Visual iteration requires real device testing.
- Preview code in the Swift source files runs in CI-only — they help catch compile errors, not layout issues.
- Compile errors will always come back in the `CompileSwift normal arm64` log section of a failed run. Scroll UP from "The following build commands failed" to find the actual `File.swift:line:col: error:` message.

---

## 9. Known limitations / "not done yet"

Live as of the last commit on `main`:

- Settings screen is not ported (still a stub).
- App icon is a placeholder geometry generated at CI time. Real artwork needs a 1024×1024 PNG dropped at `ios-native/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` + the CI "Generate placeholder app icon" step removed.
- No image picker / recipe hero image (Recipe.imageUri exists on the model, not yet surfaced in UI).
- No `expo-keep-awake` equivalent wired yet. `UIApplication.shared.isIdleTimerDisabled = true` during Cook Mode is the one-liner fix.
- iPad layout is not supported (target family is iPhone only for now).
- No recipe import from URL (text-paste import covers the manual case).
- Conversions are read-only reference data — no inline "convert this ingredient" action yet.
- Custom font files (Fraunces, Inter) are not bundled — `AppFont` uses `.system(.serif)` as a placeholder. A real type system is a likely target of the next aesthetic pass.
- No iCloud sync (SwiftData can be configured with CloudKit for a future version).

See [llamas-cookbook-plan.md §12](./llamas-cookbook-plan.md) for the original Phase 4 stretch list.

---

## 10. Memory / Claude collaboration notes

Working memory for future Claude sessions lives under `~/.claude/projects/C--Users-fines-Documents-2026-Repository-The-Llamas-Cookbook/memory/` on Lorenzo's machine. Files there cover: user profile, stack decisions, the Swift-port pivot, and the CRUD-first feedback rule. Those files are point-in-time — verify before asserting.

When in doubt, this document wins over outdated memory.
