# Llamas Cookbook — Llama Intro Walkthrough Plan

> **Goal:** the first time a user opens **Import recipe** or **New recipe**,
> the helper llama walks them through the screen one field at a time —
> highlighting each input, pointing at it, and explaining what it does.
> Re-runnable from a question-mark icon (precedent: `ImportHelpView`).
>
> **Companion to:** [CLAUDE.md](./CLAUDE.md), [llamas-cookbook-plan.md](./llamas-cookbook-plan.md).
>
> **Audience:** Claude Code session, picking up to implement.

---

## 0. The 60-second summary

Two coach-mark tours, one shared framework:

| Tour | Trigger | Steps | Re-entry |
|---|---|---|---|
| **Import tour** | First open of `ImportRecipeView` (replaces existing `hasSeenImportHelp` auto-show) | 7 | `?` icon already in the toolbar |
| **New-recipe tour** | First open of `RecipeEditorView` with `recipe == nil` | 11 | New `?` icon added to editor toolbar |

A single overlay (`LlamaIntroOverlay`) drives both. It dims the screen,
punches a soft cutout around the highlighted field, parks the llama
character beside the cutout, and shows a speech bubble with **Skip /
Next**. The llama bobs, mirrors to face the field, and hops on each
step change.

**Effort:** ~1 dev-day for the framework (overlay + anchors + character
+ bubble), ~0.5 day to wire each tour, ~0.5 day for the polish pass
(scroll-into-view, Reduce Motion, dynamic type). **Three CI cycles
minimum** since first-run UX has to be tested on a real install.

**Why-this-shape:**
- Pure SwiftUI overlay (matches "no UIKit beyond two appearance proxies"
  rule in CLAUDE.md). One `UIViewRepresentable` exception is allowed
  but not needed here.
- Reuses `LlamaLogo` — no new artwork. Body is baked in, only the
  shadow halo is tintable, so "facing direction" is `.scaleEffect(x: -1)`.
- Anchor-based highlight (`.anchorPreference` → `Anchor<CGRect>`) is the
  same pattern SwiftUI uses internally for popovers; survives Dynamic
  Type, rotation, scroll, and Liquid-Glass adoption.
- Precedents: `ImportRecipeView.hasSeenImportHelp` first-time gating, the
  hero-row helper-llama in both `ImportRecipeView.heroRow` and
  `RecipeEditorView.heroRow`, `ImportHelpView`'s "Got it" pill style.

**Non-goals (v1):**
- No tour for Cook Mode / Detail / Sharing / Profile. Same framework
  can be reused later — out of scope for this PR pair.
- No "walking llama traversing the screen". Teleport-with-spring +
  facing-mirror is enough for the metaphor.
- No localization (app is English-only).
- No editing / deleting / triggering input from inside the tour. The
  overlay is purely explanatory; the user always reads, then dismisses.

---

## 1. UX walkthrough

### 1.1 Visual anatomy of one step

```
 ┌────────────────── ScrollView content (dimmed @ 0.55) ──────────────────┐
 │                                                                        │
 │                                                                        │
 │     ┌──────────────────────────────────────────────────────┐           │
 │     │                                                      │  ← cutout │
 │     │  [highlighted field — full crispness, 12pt halo]     │  spotlight│
 │     │                                                      │           │
 │     └──────────────────────────────────────────────────────┘           │
 │                          ↑                                             │
 │                          │  (bubble tail points here)                  │
 │       ┌──────────────────┴──────────────────┐                          │
 │  🦙   │  Recipe name                        │                          │
 │ (idle │  This is the only field you NEED.   │                          │
 │ bob)  │  Everything else is optional.       │                          │
 │       └──────────────────────────────────────┘                         │
 │                                                                        │
 │  Skip                                            ●●○○○○○   Next →     │
 └────────────────────────────────────────────────────────────────────────┘
```

- **Dim layer**: `Color.black.opacity(0.55)` covering the whole screen
  except the cutout.
- **Cutout**: rounded-rect path subtracted from the dim layer using
  `.fill(style: FillStyle(eoFill: true))`. Corner radius matches the
  field's radius (`AppRadius.md`). Inflated by 8pt so the field doesn't
  feel cramped against the edge.
- **Halo**: 2pt accent stroke around the cutout, scale-pulsing 1.0 →
  1.04 → 1.0 over 1.6s. Draws the eye.
- **Llama**: `LlamaLogo(size: 84, shadowColor: appearance.accentColor)`
  sits adjacent to the cutout, on the opposite side of the bubble (so
  the bubble is between llama and field — llama looks like it's
  *delivering* the message about the field).
- **Speech bubble**: cream fill, accent stroke, 16pt corner radius, tail
  pointing at the cutout. Headline (`AppFont.sectionHeading`) +
  body (`AppFont.body`).
- **Bottom bar**: "Skip" (low-emphasis text button, `textSecondary`) +
  step dots (1 per step) + "Next" pill (accent fill, `onAccent`
  text). Last step's pill says **"Got it!"** and tears down.

### 1.2 Llama animation states

| State | When | How |
|---|---|---|
| **Idle bob** | Always | y-offset oscillates ±4pt, `easeInOut(duration: 1.4).repeatForever(autoreverses: true)` |
| **Halo pulse** | Always | `shadowOpacity` 0.45 → 0.70 → 0.45, 1.6s cycle (matches highlight pulse) |
| **Hop** | Step change | scale 1.0 → 1.08 → 1.0 + extra y-bounce, spring `response: 0.45, dampingFraction: 0.55`. Triggered by `.id(currentStep)` |
| **Face left** | Field is to the **right** of llama | `.scaleEffect(x: -1, y: 1)` (mirror). Animated with spring so the flip reads as a head-turn |
| **Face right** | Field is to the **left** of llama | identity scale |
| **Wave** | First step of each tour | rotation oscillates ±6° three times over 0.9s, then settles |

**Reduce Motion**: bob/halo pulse/hop/wave disabled; cross-fade only on
step change. Mirroring still happens (it's a layout cue, not a motion
flourish).

### 1.3 Bubble placement algorithm

Read the cutout `CGRect` in screen space. Pick a quadrant for llama +
bubble:

```
target.midY < safeArea.midY:   bubble + llama BELOW the cutout
                               tail points UP

target.midY ≥ safeArea.midY:   bubble + llama ABOVE the cutout
                               tail points DOWN

within that:
  target.midX < safeArea.midX: llama on the LEFT, bubble on the RIGHT
                               of llama, llama faces RIGHT (toward field)
  target.midX ≥ safeArea.midX: llama on the RIGHT, bubble on the LEFT,
                               llama faces LEFT
```

Edge cases:
- If the cutout fills more than 60% of the safe-area height (rare —
  TextEditor at 280pt comes close), pin the bubble to the **bottom**
  inset and don't try to place it adjacent. Tail points up at the
  cutout's midpoint.
- The bubble's max width is `min(280, safeArea.width - 32)` so it
  never overflows on small phones.

### 1.4 Scroll-into-view

Tours touch fields below the fold (Categories, Ingredients, Steps in
the editor). Each step optionally carries a `scrollAnchor: ScrollAnchor?`.
When the step changes:

1. Overlay tells the host to call `proxy.scrollTo(scrollAnchor, anchor: .center)` inside `withAnimation(.spring(...))`.
2. Wait one run loop (`Task { try? await Task.sleep(.milliseconds(80)) }`)
   for the anchor preferences to update post-scroll.
3. Reposition the cutout + bubble + llama against the new anchor.

Implementation note: the host (`ImportRecipeView` / `RecipeEditorView`)
already wraps its `ScrollView` in a `ScrollViewReader` (Import does;
Editor does not — adding it is part of PR 2). The overlay accepts a
`ScrollViewProxy` via environment.

---

## 2. The two tours, step-by-step

### 2.1 Import tour (7 steps)

| # | Target | Headline | Body |
|---|---|---|---|
| 1 | `heroRow` (whole hero) | "Hi, I'm here to help!" | "Two ways to import a recipe — let me show you." (waves) |
| 2 | `urlField` | "Paste a recipe link" | "Blog URLs, Pinterest pins, TikTok captions — I'll pull what I can. IG and FB block previews; for those, paste the caption below." |
| 3 | `fetchButton` | "Tap Fetch" | "I'll grab the title, ingredients, steps, and times. You can edit anything I get wrong before saving." |
| 4 | `formatHint` (the 3-line check panel) | "Watch the checklist" | "Title, first ingredient, first step — these light up when I find them. If something's missing, tweak the text below." |
| 5 | `pasteEditor` (the TextEditor) | "Or paste plain text" | "Three blocks separated by blank lines: title, ingredients, steps. Bullets and fractions parse automatically." |
| 6 | `previewButton` | "Hit Preview" | "I'll show you exactly what I parsed. You can fix anything before saving to your library." |
| 7 | `helpIcon` (the `?` in the nav bar) | "Need a refresher?" | "Tap the question mark anytime to see this tour again." (last step — pill says "Got it!") |

### 2.2 New-recipe tour (11 steps)

| # | Target | Headline | Body |
|---|---|---|---|
| 1 | `heroRow` | "Let's build a recipe" | "I'll walk you through the fields. Only one is required — the rest are up to you." (waves) |
| 2 | `titleField` | "Recipe name" | "This is the only required field. Type whatever you'll recognize it by — I'll title-case it for you." |
| 3 | `summaryField` | "Short description (optional)" | "A line or two that shows up under the title in your library. Skip if you don't have one." |
| 4 | `servingsField` | "Servings" | "Set this and Cook Mode lets you scale the whole recipe up or down on the fly." |
| 5 | `prepTimeField` | "Prep time" | "Minutes of work before cooking starts. Surfaces alongside cook time when you open the recipe." |
| 6 | `photosButton` | "Add photos" | "Tap to open the gallery. Pick up to a dozen, reorder them, add captions. Each step can also have its own photos (up to 3)." |
| 7 | `categoriesHeader` (incl. TagInputView) | "Tag it" | "Tags drive your library filters. Add 'Sourdough' to unlock the calculator chip in Detail." |
| 8 | `ingredientQuickAdd` | "Add ingredients" | "Quantity, unit, name. Tap chips for common values, hit + to add. Only the name is required — leave qty/unit blank if there isn't one." |
| 9 | `stepQuickAdd` | "Add steps" | "One step at a time. Tap the clock if the step needs a timer in Cook Mode. Long-press a step later to drag and reorder." |
| 10 | `specialNotesEditor` | "Notes (optional)" | "Recipe-level intro, sign-off, or general note — plus per-step notes if a step needs context." |
| 11 | `saveButton` (toolbar) | "Hit Save when ready" | "You can come back and edit anytime. Photos, tags, steps — nothing's locked in." (last step — pill says "Got it!") |

---

## 3. Architecture

### 3.1 New files

```
ios-native/Sources/Views/Components/LlamaIntro/
├── LlamaIntroOverlay.swift         (the overlay view)
├── LlamaTourTarget.swift           (PreferenceKey + .tourTarget(...) modifier)
├── LlamaCharacter.swift            (animation wrapper around LlamaLogo)
├── LlamaSpeechBubble.swift         (bubble shape + tail + content)
├── LlamaIntroStep.swift            (step model + ScrollAnchor enum)
└── Tours/
    ├── ImportTour.swift            (the 7-step array)
    └── NewRecipeTour.swift         (the 11-step array)
```

Folder is fine because XcodeGen flattens by default; no `project.yml`
edit needed beyond ensuring the new directory is under
`Sources/Views/Components/`. Verify after PR 1 lands.

### 3.2 Modified files

| File | Change |
|---|---|
| `Views/Library/ImportRecipeView.swift` | Replace `hasSeenImportHelp` auto-`showHelp` with `showImportTour`. Tag fields via `.tourTarget(.urlField)` etc. Question-mark button presents tour, not `ImportHelpView`. |
| `Views/Library/ImportHelpView.swift` | **Delete.** Content folds into the tour's step bodies. (If you want to keep static help as a fallback, leave the file; nobody calls it after PR 1.) |
| `Views/Editor/RecipeEditorView.swift` | Add `?` toolbar button (mirrors Import's). First-open auto-trigger when `recipe == nil`. Wrap `ScrollView` in `ScrollViewReader` + tag fields. Add `scrollAnchor` `.id`s on each tour target. |
| `Views/Editor/IngredientQuickAdd.swift` | Add `.tourTarget(.ingredientQuickAdd)` on the outer VStack so the tour highlights the whole quick-add cluster (qty + unit + name + chips + Add button) — granular targeting per-field is unnecessary noise. |
| `Views/Editor/StepQuickAdd.swift` | Same — `.tourTarget(.stepQuickAdd)` on the cluster. |
| `Views/Editor/SpecialNotesEditor.swift` | `.tourTarget(.specialNotesEditor)` on the row container. |

No SwiftData / model changes. Persistence is two `@AppStorage` keys.

### 3.3 Persistence

```swift
// In LlamaIntroOverlay or its host views.
@AppStorage("hasSeenImportTour") private var hasSeenImportTour = false
@AppStorage("hasSeenNewRecipeTour") private var hasSeenNewRecipeTour = false
```

Migration from `hasSeenImportHelp` (existing key, set to `true` on
old installs):

```swift
@AppStorage("hasSeenImportHelp") private var hasSeenImportHelp = false

// On first appear of the new tour code, if the legacy key is true and
// the new key is still default, treat as seen:
if hasSeenImportHelp && !hasSeenImportTour {
    hasSeenImportTour = true
}
```

Don't drop the legacy key — UserDefaults entries are basically free
and removing it costs nothing on disk but a CI cycle to validate.

---

## 4. Implementation sketches

### 4.1 Tour target identifiers

```swift
// LlamaTourTarget.swift
enum LlamaTourTarget: Hashable {
    // Import tour
    case importHero
    case urlField
    case fetchButton
    case formatHint
    case pasteEditor
    case previewButton
    case helpIcon

    // New-recipe tour
    case editorHero
    case titleField
    case summaryField
    case servingsField
    case prepTimeField
    case photosButton
    case categoriesHeader
    case ingredientQuickAdd
    case stepQuickAdd
    case specialNotesEditor
    case saveButton
}

private struct LlamaTourTargetKey: PreferenceKey {
    static let defaultValue: [LlamaTourTarget: Anchor<CGRect>] = [:]
    static func reduce(
        value: inout [LlamaTourTarget: Anchor<CGRect>],
        nextValue: () -> [LlamaTourTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func tourTarget(_ id: LlamaTourTarget) -> some View {
        anchorPreference(key: LlamaTourTargetKey.self, value: .bounds) {
            [id: $0]
        }
    }
}
```

### 4.2 Step model

```swift
// LlamaIntroStep.swift
struct LlamaIntroStep: Identifiable, Equatable {
    let id: Int
    let target: LlamaTourTarget?     // nil = center the bubble, no cutout
    let headline: String
    let body: String
    let scrollAnchor: AnyHashable?   // proxy.scrollTo target, optional
    let waveOnEnter: Bool            // true for step 1 of each tour
}
```

`target == nil` is the escape hatch for steps that don't have a single
field to highlight (e.g. a closing summary). Not used in v1, but cheap
to leave in the model.

### 4.3 Overlay skeleton

```swift
// LlamaIntroOverlay.swift
struct LlamaIntroOverlay: View {
    let steps: [LlamaIntroStep]
    let onFinish: () -> Void

    @Environment(AppearanceSettings.self) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentIndex = 0

    var scrollProxy: ScrollViewProxy?  // injected by host

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Read every tour-target anchor in one shot so the
                // overlay can resolve the current step's CGRect from
                // the GeometryProxy.
                Color.clear
                    .overlayPreferenceValue(LlamaTourTargetKey.self) { anchors in
                        let step = steps[currentIndex]
                        let frame: CGRect? = step.target.flatMap { anchors[$0].map { proxy[$0] } }

                        ZStack {
                            dimLayer(cutout: frame)
                            if let frame {
                                haloPulse(around: frame)
                            }
                            bubbleAndLlama(frame: frame, in: proxy.size)
                            controls
                        }
                    }
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
        .task(id: currentIndex) {
            // Trigger the host's scroll-to once per step change.
            if let anchor = steps[currentIndex].scrollAnchor,
               let scrollProxy {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    scrollProxy.scrollTo(anchor, anchor: .center)
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    @ViewBuilder
    private func dimLayer(cutout: CGRect?) -> some View {
        // Full-screen Path with the cutout subtracted via even-odd fill.
        // If `cutout == nil`, just a flat dim layer.
        // Implementation detail in PR 1.
    }
}
```

### 4.4 Llama character

```swift
// LlamaCharacter.swift
struct LlamaCharacter: View {
    enum Facing { case left, right }
    let size: CGFloat
    let facing: Facing
    let isWaving: Bool
    let stepID: Int                    // changes each step → triggers .id() hop

    @Environment(AppearanceSettings.self) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var bobOffset: CGFloat = 0
    @State private var haloOpacity: Double = 0.45
    @State private var waveAngle: Double = 0

    var body: some View {
        LlamaLogo(size: size, shadowColor: appearance.accentColor, shadowOpacity: haloOpacity)
            .offset(y: bobOffset)
            .rotationEffect(.degrees(waveAngle))
            .scaleEffect(x: facing == .left ? -1 : 1, y: 1)
            .id(stepID)                                      // force fresh transition on hop
            .transition(.scale(scale: 0.92).combined(with: .opacity))
            .onAppear { startIdleAnimations() }
            .task(id: isWaving) { if isWaving { await playWave() } }
            .animation(.spring(response: 0.5, dampingFraction: 0.55), value: stepID)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: facing)
    }

    private func startIdleAnimations() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            bobOffset = -4
        }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            haloOpacity = 0.70
        }
    }

    private func playWave() async {
        guard !reduceMotion else { return }
        for _ in 0..<3 {
            withAnimation(.easeInOut(duration: 0.15)) { waveAngle = 6 }
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeInOut(duration: 0.15)) { waveAngle = -6 }
            try? await Task.sleep(for: .milliseconds(150))
        }
        withAnimation(.easeInOut(duration: 0.15)) { waveAngle = 0 }
    }
}
```

### 4.5 Wiring in `ImportRecipeView`

```swift
// In ImportRecipeView.swift

@AppStorage("hasSeenImportTour") private var hasSeenImportTour = false
@AppStorage("hasSeenImportHelp") private var hasSeenImportHelp = false  // legacy
@State private var showTour = false

// On the heroRow:
heroRow.tourTarget(.importHero)

// On urlField:
urlField.tourTarget(.urlField)

// On fetchButton:
fetchButton.tourTarget(.fetchButton)

// ... etc for each step's target.

// Question-mark toolbar button now triggers the tour:
ToolbarItem(placement: .primaryAction) {
    Button {
        Haptics.selection()
        showTour = true
    } label: {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(appearance.accentColor)
    }
    .accessibilityLabel("Replay walkthrough")
}

// Overlay attached to the ScrollView's ZStack root — keep a single
// `LlamaIntroOverlay` wrapped in `if showTour { ... }` so the dimmed
// state can be summoned at any time, not just first-launch.
.overlay {
    if showTour {
        LlamaIntroOverlay(
            steps: ImportTour.steps,
            scrollProxy: proxy,    // from the existing ScrollViewReader
            onFinish: {
                showTour = false
                hasSeenImportTour = true
            }
        )
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: showTour)
    }
}

// First-launch trigger inside .onAppear:
.onAppear {
    if hasSeenImportHelp && !hasSeenImportTour {
        hasSeenImportTour = true   // migration
    }
    if !hasSeenImportTour && prefilledURL == nil {
        // Skip auto-show when launched via share extension —
        // prefilled URLs already imply intent + comfort.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            showTour = true
        }
    }
    // ... rest of existing onAppear
}
```

### 4.6 Wiring in `RecipeEditorView`

```swift
// In RecipeEditorView.swift

@AppStorage("hasSeenNewRecipeTour") private var hasSeenNewRecipeTour = false
@State private var showTour = false

// Wrap the existing ScrollView in ScrollViewReader so the tour can
// scroll to anchors. Each tour-target field gets a `.id(...)` so
// `proxy.scrollTo` can land it in view.
ScrollViewReader { proxy in
    ScrollView { ... }
    .toolbar {
        // ... existing items ...
        ToolbarItem(placement: .primaryAction) {
            Button {
                Haptics.selection()
                showTour = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(appearance.accentColor)
            }
            .accessibilityLabel("Replay walkthrough")
        }
    }
    .overlay {
        if showTour {
            LlamaIntroOverlay(
                steps: NewRecipeTour.steps,
                scrollProxy: proxy,
                onFinish: {
                    showTour = false
                    hasSeenNewRecipeTour = true
                }
            )
        }
    }
}
.onAppear {
    if recipe == nil && !hasSeenNewRecipeTour {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            showTour = true
        }
    }
}
```

Trigger only when `recipe == nil` (creation flow). Editing an existing
recipe never triggers the tour — the user already knows what they're
looking at.

---

## 5. Gotchas + edge cases

### 5.1 Anchors aren't ready on first frame
SwiftUI needs one layout pass before anchor preferences flow up. The
500ms sleep in `.onAppear` covers cold-launch sheet presentation; the
overlay also tolerates `frame == nil` for the current step (renders
the bubble centered with no cutout) so a missed first-frame doesn't
crash, just degrades for ~16ms.

### 5.2 Keyboard occlusion
The Import tour highlights the `TextEditor` (paste box). When the
overlay summons it, the TextEditor is **not** focused (the tour scrolls
to it but doesn't tap it), so the keyboard stays down. Confirm by
explicitly blurring before each step transition:

```swift
.onChange(of: currentIndex) { _, _ in
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil, from: nil, for: nil
    )
}
```

### 5.3 ScrollView in nested presentation
`RecipeEditorView` lives inside `ImportRecipeView`'s
`navigationDestination` when the user comes from Import. The tour for
the editor starts when *that* editor view appears — the first-time
gating is per-screen, not per-app-launch. If the user imports a recipe
their first time using the app, they'll see the Import tour, then the
editor tour pops on the parsed-preview screen. That's intentional —
each screen teaches itself.

### 5.4 Long fields (TextEditor) and the cutout
The paste TextEditor is 280pt tall. At iPhone SE height (~568pt minus
toolbars + nav + safe-area insets ≈ 380pt usable), that's >60% of the
visible area. The placement algorithm pins the bubble to the **bottom
inset** when this triggers (see §1.3 edge case) — verify on SE-sized
preview before merging PR 1.

### 5.5 Toolbar items as tour targets
The "Help" question-mark icon (Import step 7) and the "Save" button
(New-recipe step 11) live in `ToolbarItem`. `.tourTarget(...)` works on
toolbar items — `ToolbarItem` content is a regular `View`, anchors
flow up through it. **But** the cutout will land in safe-area space
above the navigation bar background, which already has a `.bar`
material. That's fine — the cutout just punches the dim layer; the
navigation bar's own material stays untouched. If a halo pulse looks
clipped against the nav bar's bottom edge, reduce halo radius from 12pt
to 6pt for toolbar-item targets specifically.

### 5.6 Reduce Motion + first-launch
On Reduce-Motion devices, the overlay still fades in cross-faded
between steps (no scale/spring). The wave on step 1 is suppressed —
the headline copy alone has to carry the "hi there" beat. Acceptance
test: enable Reduce Motion in Settings → Accessibility → Motion, fresh
install, both tours read coherently with cross-fade only.

### 5.7 First-launch races the share extension
If the very first app launch comes from a share-extension handoff
(`prefilledURL != nil` in `ImportRecipeView`), suppress the tour —
that user has already seen iOS's share-sheet UX and is task-driven.
Skipping is a one-line guard inside the auto-trigger block. Mark the
tour as seen so a subsequent organic open doesn't pop it on top of
remembered context.

### 5.8 Dynamic Type
Bubble copy uses `AppFont.body` (sectionHeading for headline). At
`.accessibilityExtraExtraExtraLarge`, the bubble can grow tall enough
to cover the cutout. Enforce `.lineLimit(8)` on the body and let the
user `Next` past — the explanation copy is short enough to fit.

### 5.9 Don't auto-trigger inside the share-extension's Import flow
`ImportRecipeView`'s init takes `prefilledURL: String?`. The
share-extension passes a non-nil value via deep-link (`share-url/...`).
`onAppear` already special-cases prefill; the new tour gating just
checks the same flag (see §4.5).

### 5.10 No memory entry needed
This is implementation work — no preference / project state worth
saving to memory. Don't add an auto-memory entry just because the
feature is new.

---

## 6. PR breakdown

### PR 1 — Framework + Import tour
**Goal:** ship the overlay system and prove it with the Import flow.
**Scope:**
- New `Sources/Views/Components/LlamaIntro/` directory with all 6 framework files.
- `Tours/ImportTour.swift` with the 7 steps.
- `ImportRecipeView` modifications: tour-target tags, auto-trigger,
  question-mark behavior change, migration from `hasSeenImportHelp`.
- (Optional) delete `ImportHelpView.swift`.
**Out of scope:** any editor changes.
**Acceptance:**
- Fresh install, tap "Import from text" → tour pops in ~0.5s.
- Each Next advances + scrolls + repositions llama and bubble.
- Llama mirrors when target is to its right.
- Skip tears down without setting the seen flag (so reopening shows it
  again — this is fine; user actively skipped, they didn't dismiss-as-done).
- Wait — actually: Skip *should* set the seen flag, otherwise the
  user gets the same tour every time they open Import. Decision: **Skip
  sets the seen flag too**. Re-entry is via the question-mark icon.
- Question-mark icon presents the tour every time, regardless of seen
  flag.
- Reduce-Motion build: cross-fade only, no springs / bobs / waves.

### PR 2 — New-recipe tour + editor question-mark icon
**Goal:** wire the same overlay into the editor with its 11 steps.
**Scope:**
- `Tours/NewRecipeTour.swift` with the 11 steps.
- `RecipeEditorView` modifications: `ScrollViewReader` wrapper,
  `.id(...)` anchors on tour targets, tour-target tags, `?` toolbar
  button, auto-trigger when `recipe == nil`.
- Tour-target tags on `IngredientQuickAdd`, `StepQuickAdd`,
  `SpecialNotesEditor`.
**Out of scope:** any other tours (Cook Mode, Detail, etc.).
**Acceptance:**
- Fresh install, FAB → "New Recipe" → tour pops in ~0.5s.
- Tour scrolls all the way to Save (last step's target is in the
  toolbar — no scroll needed for it but earlier steps require it).
- Question-mark icon re-runs on demand.
- Editing an existing recipe: tour does NOT pop.
- Tour does NOT pop when the editor is reached via Import preview's
  "Save" → `RecipeImportPreviewView` route — that path doesn't push
  the editor; it materializes directly.

---

## 7. Acceptance checklist (cross-PR)

Visual:
- [ ] Llama bobs when idle, hops on step change.
- [ ] Llama mirrors to face the target field on every step.
- [ ] Halo pulses; cutout halo pulses in sync.
- [ ] Bubble tail points at the cutout (above or below).
- [ ] On long fields (TextEditor), bubble pins to bottom inset.
- [ ] Step dots reflect current position (filled = passed, hollow = ahead).
- [ ] "Next" pill becomes "Got it!" on the last step.

Behavior:
- [ ] First open of Import → tour auto-shows (after ~500ms).
- [ ] First open of New Recipe → tour auto-shows (after ~500ms).
- [ ] Editing an existing recipe → tour does NOT auto-show.
- [ ] Share-extension prefill → tour does NOT auto-show (still markable as seen).
- [ ] Question-mark icon re-runs the tour every time.
- [ ] Skip sets the seen flag.
- [ ] Got it! sets the seen flag.
- [ ] Migration: legacy `hasSeenImportHelp == true` users don't see Import tour on update.

Accessibility:
- [ ] Reduce Motion suppresses bob, halo pulse, hop, wave; cross-fade only on step change.
- [ ] VoiceOver announces headline + body on each step change.
- [ ] Skip and Next have `.accessibilityLabel` and minimum 44pt hit targets.
- [ ] At `.accessibilityXXL`, bubble doesn't overflow safe area; body wraps to ≤8 lines.

CI:
- [ ] Both tour Swift files compile against iOS 18.0 deployment target.
- [ ] Both tours rendered in Preview (`#Preview` blocks at the bottom of `LlamaIntroOverlay.swift`).

---

## 8. Future tours (deferred — not in scope)

Same framework can power:

- **Cook Mode tour** — phase toggle, servings scaler, timer banner, ready overlay, multi-cook pills.
- **Detail tour** — share menu, sourdough chip, "Add to Cook Mode" button, gallery, step photos.
- **Profile / sharing tour** — Sign-in-with-Apple, share-to-friend flow once cloud-permalinks land in TestFlight.

Each is a new `Tours/<Name>Tour.swift` step array + a new
`@AppStorage("hasSeen<Name>Tour")` key + a `?` icon on the host view.
No framework changes required.

---

## 9. Open questions

1. **Should "Skip" really mark the tour seen?** Argument for yes: don't
   nag. Argument for no: skip implies "later", not "never". **Default:
   yes** (matches §6 PR 1 acceptance). Easy to flip with a flag in the
   step model if user testing says otherwise.
2. **Speech bubble copy tone.** Drafts above are conversational + brief.
   If they feel too casual after first read on device, tighten to
   imperative ("Type the recipe name. It's the only required field.").
   Run by Lorenzo before merging PR 1.
3. **Should the FAB itself get a tour target on cold launch?** The
   library is empty, nothing else is on screen, and the FAB is the
   only path forward. v1 leaves it alone — `EmptyLibraryView` already
   nudges toward the FAB. Reconsider after a week of TestFlight if
   users still get stuck on the empty library.
