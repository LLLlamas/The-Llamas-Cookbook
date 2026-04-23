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
| Library / home | ✅ | ✅ — list + empty state + tag/favorite filter + long-press delete + FAB |
| Recipe Detail | ✅ | ✅ — title, summary, times, tags, ingredients, steps, notes, reference link, signature, delete |
| Recipe Editor | ✅ | ✅ — hero row, required title, ingredient quick-add (with qty/unit/name validation + error glow), step quick-add, tag input, notes, reference link, optional details (servings + cook time), toolbar Save |
| Cook Mode | ✅ | ✅ — two-phase (prep → cook), servings scaler, per-step timer with keyword detection, full-screen alarm modal with vibration |
| Settings | ✅ (minimal) | ⬜ not started |
| Llama mascot | ✅ (SVG) | ✅ (SwiftUI Canvas port) |

Build pipeline: Swift archive + TestFlight upload via GitHub Actions on `macos-latest`. Fully functional — placeholder app icon, single 1024×1024 in the asset catalog, auto-downsized by actool at build time.

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
│   ├── project.yml             ← XcodeGen config
│   ├── README.md               ← port-specific notes
│   ├── Sources/
│   │   ├── App/                ← @main + RootView
│   │   ├── Models/             ← Recipe, Ingredient, RecipeStep (SwiftData) + DraftRecipe
│   │   ├── Theme/              ← AppColor, AppFont, AppSpacing, AppRadius
│   │   ├── Lib/                ← Haptics, Quantity
│   │   └── Views/
│   │       ├── Components/     ← LlamaMascot, EmptyLibraryView, FlowRow layout
│   │       ├── Library/        ← LibraryView, RecipeCardView
│   │       ├── Detail/         ← RecipeDetailView
│   │       ├── Cook/           ← CookModeView (+ TimerReadyOverlay)
│   │       └── Editor/         ← RecipeEditorView, IngredientQuickAdd, IngredientRowEditor,
│   │                             StepQuickAdd, StepRowEditor, TagInputView, Chips/
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
- Tap a whole and a fraction to get "3 1/4".
- Tapping the active chip deselects it.
- When Cook Mode scales ingredients, `formatQuantity` snaps the result to the nearest tangible fraction — never surfaces `0.42 tsp`.

### Timer keyword detection

A step is "timeable" if its text contains one of: `oven`, `bake`, `grill`, `skillet`, `stove`, `pan`, `pot`, `simmer`, `boil`. First match wins and becomes the timer label ("Oven timer", "Pot timer"). Tapping the step to check it off *also* auto-starts the timer (bound to `recipe.cookTimeMinutes`). Only one timer runs at a time.

On expiry: full-screen terracotta cover with bell icon + "{Keyword} timer ready!" + big Stop button. Phone vibrates + warns via haptic every 1.2s until Stop. Task is cancelled on disappear so vibration never leaks out of the screen.

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

- Settings screen is not ported (still a stub; no data export yet).
- App icon is a placeholder geometry generated at CI time. Real artwork needs a 1024×1024 PNG dropped at `ios-native/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` + the CI "Generate placeholder app icon" step removed.
- No image picker / recipe hero image (Recipe.imageUri exists on the model, not yet surfaced in UI).
- No `expo-keep-awake` equivalent wired yet. `UIApplication.shared.isIdleTimerDisabled = true` during Cook Mode is the one-liner fix.
- iPad layout is not supported (target family is iPhone only for now).
- No recipe import from URL.
- No unit conversion.
- No iCloud sync (SwiftData can be configured with CloudKit for a future version).

See [llamas-cookbook-plan.md §12](./llamas-cookbook-plan.md) for the original Phase 4 stretch list.

---

## 10. Memory / Claude collaboration notes

Working memory for future Claude sessions lives under `~/.claude/projects/C--Users-fines-Documents-2026-Repository-The-Llamas-Cookbook/memory/` on Lorenzo's machine. Files there cover: user profile, stack decisions, the Swift-port pivot, and the CRUD-first feedback rule. Those files are point-in-time — verify before asserting.

When in doubt, this document wins over outdated memory.
