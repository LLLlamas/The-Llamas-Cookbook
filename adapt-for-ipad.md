# Adapt for iPad

Plan for bringing **the same look and functionality** to iPad as the iPhone app currently delivers, without freezing iPhone iteration.

Last refreshed: 2026-04-30. Author: scoping pass — code citations were inspected, not built.

---

## TL;DR

- App is currently **iPhone-only** (`TARGETED_DEVICE_FAMILY: "1"` on all three targets in `ios-native/project.yml`). iPad runs it in a letterboxed iPhone-compatibility window.
- Code uses zero size-class adaptation (no `NavigationSplitView`, no `horizontalSizeClass` checks, no `userInterfaceIdiom` checks).
- Two-track plan: Phase 0 (flip the device-family flag, ship a stretched-iPhone iPad build) can land in a single PR. Phases 1–6 (real iPad polish) are **additive size-class branches** so iPhone work continues uninterrupted.
- Things only **you** can do are flagged **[USER ACTION]** throughout.

---

## What I need from you (read this first)

These are the items I cannot do from the codebase. The plan below assumes them.

| # | Item | Why | When |
|---|------|-----|------|
| 1 | **Decide: ship interim "stretched iPhone" build to iPad users now, or hold until polish lands?** | Phase 0 produces a working but ugly iPad app. Indie norm is ship-and-iterate. | Before Phase 0 lands |
| 2 | **Decide: sidebar style — 2-column (Mail-like, sidebar = Library) or 3-column (Notes-like, sidebar = Categories → Library → Detail)?** | Drives the `NavigationSplitView` shape in Phase 1. Recommendation below. | Before Phase 1 |
| 3 | **Decide: Cook Mode on iPad — same fullscreen behavior as iPhone, or use the canvas (e.g. side-by-side multi-cook lanes instead of pills)?** | Multi-cook is way better with the iPad canvas. Recommendation below. | Before Phase 4 |
| 4 | **Decide: should the widget and share extension support iPad too?** | They're independently iPhone-only today. Both should probably go universal but the widget gallery on iPad has different layout norms. | Before Phase 0 |
| 5 | **App Store Connect — add iPad screenshots** | Apple requires iPad screenshots (12.9" / 13" / 11" sizes) before a Universal build can ship to App Store. Multiple screenshot sizes per locale. | Before any App Store submission of a Universal build |
| 6 | **Apple Developer Portal — verify distribution provisioning profiles cover iPad** | Most distribution profiles are device-class agnostic, but if any were created with explicit iPhone-only entitlements, they must be regenerated. Same for the widget + share-ext profiles. | Before Phase 0 archives |
| 7 | **Physical iPad testing access** | Simulator does not cover Stage Manager, external display, Apple Pencil, hardware keyboards realistically. CI builds + simulator run will catch most regressions, but a real device pass is required before App Store submission. | Phase 6 |
| 8 | **App Store privacy labels — confirm no changes** | iPad doesn't change CloudKit/Cloudflare data flows, so labels stay the same. Just confirm. | Before App Store submission |

If any of those decisions change, ping me and I'll update this doc.

---

## My recommendations on the open decisions

- **(1)** Ship Phase 0 as soon as it's tested — even "stretched iPhone" is better than letterboxed-iPhone-with-2x-button. Most iPad users already understand the visual disconnect for early apps.
- **(2)** Start with **2-column (Mail-style)**: sidebar = Library list, detail pane = Recipe Detail. Categories already live as filter chips inside Library and that pattern survives the move; jumping to 3-column is a much bigger restructure for marginal gain.
- **(3)** On iPad in regular width, **replace the `CookingPillsBar` overlay with side-by-side cook lanes** when 2+ cooks are active. Single-cook stays fullscreen. That's the one place where the iPad canvas changes the product, not just the layout.
- **(4)** Make widget Universal (Lock Screen widgets are identical; Home Screen widgets just get more grid slots on iPad). Make share extension Universal — required, since users will share into the app from iPad Safari/Photos.

---

## Current state (verified)

| Target | Device family | File |
|--------|---------------|------|
| Main app | `"1"` (iPhone only) | `ios-native/project.yml:46` |
| Widget | `"1"` (iPhone only) | `ios-native/project.yml:81` |
| Share extension | `"1"` (iPhone only) | `ios-native/project.yml:106` |

Code searches across `ios-native/Sources/`:

- `NavigationSplitView` → **0 matches**
- `horizontalSizeClass` → **0 matches**
- `userInterfaceIdiom` → **0 matches**
- `regularSizeClass` → **0 matches**
- `popoverPresentationController` / `presentationCompactAdaptation` → **0 matches**

So: the app does not adapt to size class anywhere today. Every layout decision was made for a phone, and most will scale up but not gracefully.

---

## Phasing

Each phase has a **scope**, **risk**, and **parallelism rules** (which iPhone-side work touches the same files).

### Phase 0 — Make it run fullscreen on iPad

**Scope:**
- Flip `TARGETED_DEVICE_FAMILY` to `"1,2"` in `ios-native/project.yml` for all three targets.
- Verify `INFOPLIST_KEY_UISupportedInterfaceOrientations~ipad` allows portrait + landscape (probably needs to be added to `Resources/AppInfo.plist`).
- Confirm `UIRequiresFullScreen` is **not** set to true (it would break Stage Manager / Slide Over).
- CI smoke build only; no code changes.

**Risk:** Low. The app will look like a giant phone, but every gesture and flow still works.

**User actions blocking this phase:** Decisions (1) and (4) above; portal check (6).

**Parallelism:** Safe to land alongside any iPhone work. `project.yml` is the only file touched.

---

### Phase 1 — `NavigationSplitView` for the Library shell

**Scope:**
- New file `Sources/App/RootSplitView.swift` that mirrors `RootView.swift` but uses `NavigationSplitView { LibraryView() } detail: { ... }`.
- Wrap `RootView`'s body with a size-class branch:
  ```swift
  @Environment(\.horizontalSizeClass) var hSizeClass
  // body:
  if hSizeClass == .regular { RootSplitView(...) } else { existingNavStack }
  ```
- `LibraryView` stays as-is — it's already a list. Tapping a row selects into the detail pane on iPad, pushes on iPhone.
- **Selection state lives in a new `@State private var selectedRecipe: Recipe.ID?`** so deep-links from share imports can hydrate it.
- Update `share-url` and `.llamarecipe` deep-link handlers in `RootView` to set `selectedRecipe` on iPad / push on iPhone.

**Risk:** Medium. Touches `RootView.swift` (deep-link routing) and `LibraryView.swift` (row selection model). The `libraryPath: NavigationPath` binding needs an iPad equivalent that drives detail-pane selection.

**Critical files:**
- `ios-native/Sources/App/RootView.swift`
- `ios-native/Sources/Views/Library/LibraryView.swift`
- `ios-native/Sources/Views/Detail/RecipeDetailView.swift`

**Parallelism:** Conflicts heavily with iPhone-side Library/Detail edits. Either land this on a feature branch and rebase periodically, or coordinate which days RootView/LibraryView get touched. I'd recommend a feature branch here.

**Open question I'll need you to answer mid-implementation:** when the user has no recipe selected on iPad, what fills the detail pane? Recommendation: a "Welcome / Llama waving / pick a recipe" placeholder that re-uses `EmptyLibraryView`-style art.

---

### Phase 2 — Sheet & modal audit

**Scope:** every `.sheet`, `.fullScreenCover`, and `.alert` site needs an explicit iPad-vs-iPhone presentation decision. Default sheet behavior on iPad is a centered `formSheet` — fine for short forms, bad for editor-style flows.

**Sites to audit (from `Grep popoverPresentationController|UIPopover` + manual audit of sheet usage):**

| Surface | File | iPhone behavior | Recommended iPad behavior |
|---------|------|-----------------|---------------------------|
| Recipe editor | `Views/Editor/RecipeEditorView.swift` | `.fullScreenCover` from FAB | Keep `.fullScreenCover` — the editor is a focus task |
| Cook Mode | `Views/Cook/CookModeView.swift` | `.fullScreenCover` | Keep fullscreen for single-cook; see Phase 4 for multi-cook |
| Photo carousel | `Views/Components/PhotoCarouselView.swift` | Inline + tap-to-fullscreen | Constrain max width (~600pt), center in available space; keep tap-to-fullscreen |
| Photo reorder | `Views/Components/PhotoReorderView.swift` | `.sheet` | `.sheet` formSheet on iPad — already fine |
| Photo import preview | `Views/Library/PhotoImportPreviewView.swift` | `.sheet` | Larger formSheet or pageSheet — review-heavy, needs space |
| Recipe import preview | `Views/Library/RecipeImportPreviewView.swift` | `.sheet` | pageSheet on iPad — same reasoning |
| Import help | `Views/Library/ImportHelpView.swift` | `.sheet` | formSheet — short content |
| Import sheets (text/link/photo) | `Views/Library/ImportFrom*View.swift` | `.fullScreenCover` from FAB | Keep `.fullScreenCover` |
| Profile | `Views/Profile/ProfileView.swift` | `.sheet` | formSheet — ok |
| Add friend | `Views/Profile/AddFriendSheet.swift` | `.sheet` | formSheet — ok |
| Friend library | `Views/Friends/FriendLibraryView.swift` | push | On iPad, push within detail pane (or open as a pageSheet — TBD) |
| Friend recipe detail | `Views/Friends/FriendRecipeDetailView.swift` | push | Same as above |
| Conversions | `Views/Detail/ConversionsView.swift` | `.sheet` | formSheet — ok |
| Sourdough calculator | `Views/Detail/SourdoughCalculatorView.swift` | `.sheet` | formSheet — ok |
| Importers list | `Views/Detail/ImportersListSheet.swift` | `.sheet` | formSheet — ok |
| Attribution | `Views/Detail/AttributionSheet.swift` | `.sheet` | formSheet — ok |
| Share sheet | `Views/Components/ShareSheet.swift` | UIActivityViewController | **Must** set `popoverPresentationController.sourceView` on iPad — otherwise it crashes. Verify this is wired before Phase 0 ships. |
| Camera capture | `Views/Components/CameraCaptureView.swift` | `.fullScreenCover` | `.fullScreenCover` — fine |
| Accent picker | `Views/Components/AccentColorPicker.swift` | inline / popover-ish | Becomes a popover on iPad regular width — add explicit `.presentationCompactAdaptation(.popover)` |

**Risk:** Medium. The share-sheet site is **the one that can actually crash on iPad** if `sourceView` isn't set on `UIActivityViewController`. Treat that as a Phase 0 blocker, not Phase 2.

**Parallelism:** Each sheet-site change is local and additive. Safe to land alongside iPhone work — they can land one PR per surface.

---

### Phase 3 — Llama coach-mark overlay iPad pass

**Scope:** `Views/Components/LlamaIntro/LlamaIntroOverlay.swift` computes positions in screen-space with constants tuned for iPhone (`bubbleMaxWidth: max(160, min(240, ...))`, `llamaSize: 84`). On a 12.9" iPad, the bubble is comically small.

- Add a size-class branch: regular width → `bubbleMaxWidth` cap to ~360pt, `llamaSize` to ~120pt.
- Re-test the layout planner — on iPad the `canSplit` heuristic (room above + room below) almost always passes, which is fine, but the bubble-cluster horizontal clamp may drift the bubble too far from the target. Worth a manual pass.
- Onboarding cold-start: confirm the tour fires the first time on iPad too. Should "just work" since the `@AppStorage` keys (`hasSeenNewRecipeTour`, etc.) are device-local but iCloud-synced via NSUbiquitousKeyValueStore? Check if `@AppStorage` defaults to KV-store sync or local — if local, an iPhone+iPad user will see each tour twice. **Likely acceptable**, but worth flagging.

**Risk:** Low. Visual-only changes.

**Parallelism:** Safe. The tour data (`Tours/*Tour.swift`) doesn't change; only the overlay's layout math.

---

### Phase 4 — Cook Mode on iPad (multi-cook lanes)

**Scope (assuming Decision (3) = "use the canvas"):**
- When `hSizeClass == .regular && session.activeCooks.count >= 2`, replace the bottom `CookingPillsBar` overlay with a `HStack` of cook lanes inside `RootSplitView`'s detail pane. Or a separate split-view tier.
- Single-cook stays fullscreen, same as iPhone.
- `CookingSession` doesn't need changes — it's already plural-aware.

**Risk:** Medium-high. This is a new layout, not a port. Easy to ship a buggy first version.

**Critical files:**
- `ios-native/Sources/Views/Cook/CookModeView.swift`
- `ios-native/Sources/App/CookingSession.swift` (only if state needs to expose lane order)
- `ios-native/Sources/App/RootView.swift` / new `RootSplitView.swift`

**Parallelism:** Conflicts with any in-flight Cook Mode iPhone work. Land on a feature branch. If a per-cook `TimerLiveActivityRegistry` lands first (it's on the iPhone roadmap per `CLAUDE.md`), this builds on top.

---

### Phase 5 — Hardware keyboard + Apple Pencil + multitasking

**Scope:**
- Hardware keyboard shortcuts for the editor: `⌘S` save, `⌘W` cancel, `⌘N` new recipe from Library, `⌘F` focus the search field, arrow-key navigation in ingredient/step lists. Implement via `.keyboardShortcut(_:modifiers:)` on the relevant buttons.
- Apple Pencil for `SpecialNotesEditor.swift` and step notes — SwiftUI `TextEditor` accepts Pencil scribble for free; just verify it works and doesn't conflict with the keyboard toolbar.
- Stage Manager / Slide Over: confirm `UIRequiresFullScreen=false` and that the layout reflows when the window becomes compact-width on a large display.

**Risk:** Low–medium. Keyboard shortcuts are additive; the multitasking pass is mostly verification.

**Parallelism:** Fully additive. Can land any time after Phase 0.

---

### Phase 6 — Verification + App Store

**Scope:**
- Real-device pass on iPad (you do this — see USER ACTION 7).
- Capture iPad screenshots for App Store Connect (USER ACTION 5). Sizes Apple requires today: 13" (iPad Pro M4), 12.9" (iPad Pro 6th gen), 11" (iPad Pro / Air). 6.7" / 6.9" iPhone screenshots remain for iPhone listing.
- Update App Store description / keywords to mention iPad if relevant.
- Submit Universal build.

**Risk:** Low.

**Parallelism:** Final phase — by definition not parallel with implementation.

---

## Per-screen audit (what changes, what doesn't)

| Screen | iPhone behavior | iPad change |
|--------|-----------------|-------------|
| Library | Full-width list, NavigationStack push to detail | Sidebar list in `NavigationSplitView`; selection drives detail pane |
| Letter index | Right-side scrub, currently tuned to iPhone width (`Views/Components/LetterIndex.swift`) | Re-test with sidebar width; may need tighter tap targets |
| Recipe card | Full-width photo + meta | Cap photo height; consider 2-up grid when sidebar is wide and detail is empty |
| Recipe detail | Full-width photo carousel, vertical scroll | Cap carousel max width (~600pt) centered; consider 2-column layout for ingredients/steps when detail pane is wide |
| Editor | Vertical scroll, single column | Single column is fine; consider 2-column at iPad-Pro widths (left: header/photos/categories; right: ingredients/steps/notes). Lower priority. |
| Cook Mode (single) | Fullscreen | Fullscreen, larger type |
| Cook Mode (multi) | Bottom pills bar | Side-by-side lanes (Phase 4) |
| Photo carousel | Full-width inline + tap-to-fullscreen | Cap width centered |
| Profile | Sheet | formSheet |
| Friends list | Push within nav stack | Pushes within detail pane on iPad; or persistent sub-tab in sidebar — TBD |
| Friend library | Push | Same |
| Import (Text/Link/Photo) | `.fullScreenCover` from FAB | Same |
| Import preview | `.sheet` | `.sheet` formSheet (default) — ok |
| Llama tours | Coach-mark overlay tuned for iPhone | Larger bubble + llama, retested layout (Phase 3) |
| Sourdough calc / Conversions | `.sheet` | formSheet — ok |
| Share sheet (`UIActivityViewController`) | Bottom sheet | Popover — **must** set `sourceView`/`sourceRect` |
| Onboarding (Sign in with Apple) | Single screen | Same; verify `SignInWithAppleButton` lays out correctly at iPad widths |

---

## Risks / known traps

- **`UIActivityViewController` without `sourceView` crashes on iPad.** Audit `Views/Components/ShareSheet.swift` and any direct UIKit invocation. Phase 0 blocker.
- **`@AppStorage` keys are NOT iCloud-synced by default**, so an iPhone+iPad user re-runs each tour. Acceptable but a UX paper-cut. Migration to `NSUbiquitousKeyValueStore` is a separate decision.
- **CloudKit subscription pushes** depend on Push Notifications capability (still pending per `CLAUDE.md` priorities). iPad inherits the same gap — not new.
- **Universal Link verification** on iPad is independent: Apple checks AASA on each device. Test the share-import flow on iPad after Phase 0.
- **Keyboard toolbar memory** (`feedback_keyboard_toolbar_swiftui.md` — `placement: .keyboard` unreliable inside TabView-in-sheet): retest on iPad. The iPad keyboard is shorter/floatable, so the same quirk may manifest differently.
- **Custom Info.plist paths** (`Resources/AppInfo.plist`) — confirm `UISupportedInterfaceOrientations~ipad` is present and includes both portrait + both landscape orientations. Without that key, the app may behave unexpectedly when rotated on iPad.
- **`UIDesignRequiresCompatibility = true`** (Liquid Glass opt-out per `CLAUDE.md`) is unaffected by device family.

---

## Parallelism — what to land where

**Safe to land on `main` alongside iPhone work:**
- Phase 0 (project.yml flag flip + AppInfo.plist orientation key)
- Phase 2 sheet-site fixes (one PR per surface, all additive)
- Phase 3 (Llama overlay size-class branch, additive)
- Phase 5 (keyboard shortcuts, additive)

**Should land on a feature branch and rebase regularly:**
- Phase 1 (`NavigationSplitView` shell) — touches `RootView.swift` and `LibraryView.swift` heavily
- Phase 4 (Cook Mode lanes) — touches Cook Mode and RootView heavily

**The ground rule:** every adaptation goes behind `@Environment(\.horizontalSizeClass)` so the iPhone branch is never broken. There is no flag day.

---

## Build / CI considerations (Windows-only constraint)

Per `CLAUDE.md`, you can't run `xcodegen` / `xcodebuild` locally. CI is the only place builds happen.

- The device-family flip will not be visible on Windows — only the simulator on a CI Mac runner can show the iPad layout.
- Recommend adding an iPad simulator screenshot to the existing CI workflow (`.github/workflows/ios-native-ci.yml`) so each PR shows iPad + iPhone side-by-side. Optional but useful.
- For visual regressions, consider snapshot tests (e.g. `swift-snapshot-testing`) against the simulator — tracked separately, not part of this plan.

---

## Open questions to resolve before each phase

| Phase | Open question | Default if unanswered |
|-------|---------------|----------------------|
| 0 | Should the widget and share extension flip device family at the same time? | **Yes** — flip together |
| 1 | What does the empty detail pane show? | Llama-waving "Pick a recipe" placeholder |
| 1 | 2-column vs 3-column NavigationSplitView? | 2-column |
| 2 | Does the editor's keyboard toolbar (`safeAreaInset` workaround) work as-is on iPad? | Assume yes; verify in Phase 6 |
| 4 | Multi-cook lanes vs keep-pills-bar on iPad? | Lanes (using the canvas) |
| 5 | Cmd-shortcut set — what's the canonical list? | ⌘S save, ⌘W close, ⌘N new, ⌘F find. Refine after iPad testing. |

---

## Done / Not Done

This document covers **iPad layout adaptation**. It does **not** cover:

- macOS Catalyst / native macOS port (separate effort)
- visionOS (out of scope)
- Apple Watch companion (out of scope)
- iPad-specific marketing / pricing (your call, not engineering)

Update this file as phases complete and as decisions firm up. When this doc disagrees with code, code wins.
