# Llamas Cookbook — Multi-Recipe Cook Mode Plan

> **Goal:** let the user cook two-or-more recipes in parallel under one
> Cook Mode session — same cooking flow, just plural — without
> trampling the existing single-recipe behavior.
>
> **Companion to:** [STATE.md](./STATE.md) §9.2,
> [Photo-Capability.md](./Photo-Capability.md), [PROJECT.md](./PROJECT.md),
> [ROADMAP.md](./ROADMAP.md).
>
> **Audience:** Claude Code session, picking up to implement.

---

## 0. The 60-second summary

Cook Mode today assumes exactly one active recipe. `CookingSession`
holds one `activeRecipe: Recipe?`, `CookModeView` holds one set of
`@State` for phase / strikes / timer, `TimerLiveActivityController`
holds one `Activity`, `TimerNotifications` schedules under one
identifier, `AlarmPlayer` owns one `AVAudioPlayer`,
`CookingSessionStore` saves one JSON blob to UserDefaults. Every one
of those is a singleton-shaped assumption; multi-recipe makes them
all per-cook.

The user-visible shape:

- **Switcher tab strip** at the top of Cook Mode showing each active
  cook's title + timer state. Tap to switch.
- **Resume pill** below Library expands when more than one cook is
  active — shows a horizontal list of "what's running" + the
  earliest-firing timer.
- **Add to session** from Recipe Detail's "Start Cooking" button,
  which gains a secondary action when a session is already running:
  *"Cook in parallel"* (adds) vs *"End current & start new"*
  (replaces).
- **Mark-as-cooked on one** removes it from the session; Cook Mode
  stays open if others remain.
- **Cap at 4 concurrent cooks** — matches iOS's practical Live
  Activity limit per app and keeps the switcher legible.

**Effort:** ~1 dev-day for the state-model refactor, ~0.5 day for
the timer-registry fan-out, ~0.5 day for the switcher UI, ~0.5 day
for the Library / Detail entry-point changes, ~0.5 day for tests +
polish. Three CI cycles minimum, with the state refactor landing
behind feature gating in the first push so a regression doesn't
brick the existing single-recipe flow.

---

## 1. What "multi-recipe Cook Mode" means in practice

The reality this is solving: pasta + sauce, main + side, a sourdough
proofing on the counter while a soup simmers. Cooks routinely run
two recipes in parallel; the app treating that as "either one or
the other" forces them out of the cooking flow to switch.

After this lands, the user can:

1. Start Cook Mode for Recipe A as today.
2. Open Recipe B's Detail without exiting Cook Mode (the resume
   pill is already there).
3. Tap "Start Cooking" on B. A confirmation surfaces:
   - **Cook in parallel** → B is added to the session.
   - **End A and start B** → A is dismissed, B replaces it.
4. Inside Cook Mode, a switcher strip across the top lets them flip
   between A and B's prep/cook checklists. Each remembers its own
   strikes, scale, and phase.
5. Each running timer shows on each recipe's screen *and* in the
   tuck-down pill *and* (where supported) as its own Live Activity.
6. Marking A as cooked drops A from the session; Cook Mode stays
   open with B active.
7. Marking the last recipe as cooked dismisses Cook Mode (today's
   single-cook behavior).

Out-of-scope for the first cut: no per-recipe sound preferences, no
per-recipe servings overrides synced across cooks, no automatic
"these two recipes look like they pair" suggestions. Just plural
mechanics.

---

## 2. State model — pluralizing `CookingSession`

Today's [`CookingSession`](./ios-native/Sources/App/CookingSession.swift)
is a single-recipe holder:

```swift
@Observable
final class CookingSession {
    var activeRecipe: Recipe?
    var isCookModeVisible: Bool = false
    var pendingRestoration: CookingSessionState?

    func start(_ recipe: Recipe) { ... }
    func end() { ... }
    func minimize() { ... }
    func resume() { ... }
    func restore(using lookup: (UUID) -> Recipe?) { ... }
}
```

The new shape:

```swift
@Observable
final class CookingSession {
    /// All recipes currently being cooked. Order is "addition order"
    /// — newest cook is appended; switcher renders left-to-right in
    /// that order. Empty array means no session is active.
    private(set) var activeCooks: [ActiveCook] = []

    /// Which cook is currently foregrounded inside Cook Mode. Nil
    /// when `activeCooks` is empty. The switcher writes this; the
    /// view reads it to pick which cook's state to render.
    var foregroundedCookID: UUID?

    var isCookModeVisible: Bool = false

    /// Convenience for callers that don't care about the plural
    /// shape — returns the foregrounded cook's recipe, or nil.
    var foregroundedRecipe: Recipe? {
        activeCooks.first(where: { $0.id == foregroundedCookID })?.recipe
    }

    /// True when adding another cook would exceed the iOS Live
    /// Activity ceiling (which is the binding constraint, not screen
    /// real estate — the switcher itself can scroll).
    var canAddCook: Bool { activeCooks.count < Self.maxConcurrentCooks }
    static let maxConcurrentCooks = 4

    func start(_ recipe: Recipe) { ... }            // first cook OR replacing
    func addParallel(_ recipe: Recipe) { ... }      // new
    func remove(cookID: UUID) { ... }               // mark-cooked path; closes Cook Mode if last
    func endAll() { ... }                           // explicit X / kill-everything
    func switchTo(cookID: UUID) { ... }             // switcher tap
    func minimize() { ... }                         // unchanged
    func resume() { ... }                           // unchanged
    func restore(using lookup: (UUID) -> Recipe?) { ... }
}
```

`activeCooks` is `private(set)` to force routing through the
mutating methods — they're the only places we update the persisted
snapshot (§9). RootView reads `activeCooks.isEmpty` instead of
`activeRecipe == nil` to decide whether to show the resume pill /
present the cover.

### 2.1 Why an array, not a dictionary keyed by recipe ID

Two reasons:

1. **Order matters for the switcher.** "Newest on the right" gives
   stable UX; a dictionary doesn't carry order without a parallel
   structure.
2. **Same recipe twice is a real case.** Cooking two batches of
   cookies in series, the user might add the same recipe twice with
   different scales. A `[Recipe.ID: …]` dictionary would collide;
   an array of `ActiveCook` (each with its own UUID) doesn't.

The cap on duplicate-same-recipe is "let it through" in v1. Worst
case the user gets two switcher tabs labeled "Brownies" with
distinct timers. That's correct; they asked for it.

---

## 3. Per-cook state — single struct, lifted into the session

Today's per-recipe state is split across two files:

- The `@State`s inside [`CookModeView`](./ios-native/Sources/Views/Cook/CookModeView.swift)
  (`phase`, `struckIngredients`, `struckSteps`, `timerEndsAt`,
  `timerStepId`, `timerLabel`, `timerExpired`, `currentServings`,
  `timerOriginalMinutes`).
- [`CookingSessionState`](./ios-native/Sources/App/CookingSessionState.swift),
  the persisted snapshot.

Multi-recipe forces these to consolidate. The view can no longer be
the source of truth — when the user switches tabs, the previous
cook's state needs to survive even though the previous instance of
`CookModeView` is gone (or, more likely, never existed if we render
one view per foregrounded cook).

### 3.1 `ActiveCook` — one struct, lives in the session

```swift
/// One in-progress cook. Holds the same fields the persisted
/// `CookingSessionState` already tracks, plus the live `Recipe`
/// reference. The view binds to this struct via `CookingSession`;
/// every mutation goes through the session so persistence stays in
/// sync.
struct ActiveCook: Identifiable, Equatable {
    let id: UUID                       // distinct from recipe.id — see §2.1
    var recipe: Recipe                 // SwiftData reference
    var phase: Phase
    var currentServings: Int
    var struckIngredientIDs: Set<UUID>
    var struckStepIDs: Set<UUID>
    var timerEndsAt: Date?
    var timerStepID: UUID?
    var timerLabel: String
    var timerOriginalMinutes: Int
    var timerExpired: Bool             // ready-overlay visibility

    enum Phase: String, Codable { case prep, cook }
}
```

`CookingSessionState` (the persisted version) drops to a thin
`Codable` mirror — it's the same fields minus the live `Recipe`
reference (replaced by `recipeID: UUID`), so the on-disk layout is
straightforward to define from `ActiveCook`.

### 3.2 The view binds, doesn't own

`CookModeView` becomes a "render this cook's state" view. The
`@State`s above turn into computed bindings that read+write through
`CookingSession.activeCooks` by index/ID:

```swift
private var cook: Binding<ActiveCook> {
    // Force-unwrap is safe by construction — RootView only presents
    // CookModeView when foregroundedCookID points at a real cook.
    Binding(
        get: { session.activeCooks.first(where: { $0.id == cookID })! },
        set: { newValue in
            guard let i = session.activeCooks.firstIndex(where: { $0.id == cookID })
            else { return }
            session.activeCooks[i] = newValue
            CookingSessionStore.save(session.activeCooks)
        }
    )
}
```

Where `cookID` is the foregrounded cook's UUID, plumbed in via the
view's init. Switching cooks dismisses-and-re-presents the view by
keying it on `cookID` — `id(cookID)` on the relevant subtree forces
SwiftUI to rebuild rather than animate state across recipes (which
would be a visual mess and a logic landmine).

---

## 4. The dismiss-when-last-finishes gotcha

In the single-recipe world, "Mark as cooked" calls `onClose` →
`session.end()` → `activeRecipe = nil` → RootView dismisses the
cover. Three things conflate into one path: *finish this recipe*,
*end the session*, *dismiss the cover*.

Going multi, those three are independent:

- **Finishing a recipe**: drop one `ActiveCook` from `activeCooks`.
- **Ending the session**: drop *all* `ActiveCook`s. Only happens on
  explicit "Exit Cook Mode" from the toolbar X, or when the last
  cook finishes and dismissing is the right move.
- **Dismissing the cover**: only happens when `activeCooks` is
  empty, OR the user taps the minimize gesture.

The fix is to centralize in `CookingSession.remove(cookID:)`:

```swift
func remove(cookID: UUID) {
    activeCooks.removeAll { $0.id == cookID }
    if activeCooks.isEmpty {
        endAll()                                // dismisses + clears persistence
    } else if foregroundedCookID == cookID {
        foregroundedCookID = activeCooks.first?.id
        CookingSessionStore.save(activeCooks)
    } else {
        CookingSessionStore.save(activeCooks)
    }
    cancelTimerSlot(cookID: cookID)             // §6
}
```

This is the multi-recipe equivalent of the §3 carry-bytes-through-
draft gotcha in [Photo-Capability.md](./Photo-Capability.md): a
silent regression mode that's easy to miss in testing if all cooks
finish in the same order they started.

> **🚨 Test #4 below catches this.** Skip the test, ship the bug.

---

## 5. `CookModeView` refactor — view-per-cook, switcher above

### 5.1 Where the switcher lives

A horizontal scroll of pill-shaped tabs sits between the existing
`topBar` (which has the X / settings icons) and the existing
`phaseHeader` (Prep ↔ Cook toggle). Pseudo-layout:

```
┌──────────────────────────────────────┐
│ [X]                          [≡]     │  topBar (existing)
├──────────────────────────────────────┤
│ ●Brownies   ○Pasta Sauce   ○Salad   │  ← new switcher
├──────────────────────────────────────┤
│        Prep | Cook                    │  phaseHeader (existing)
├──────────────────────────────────────┤
│ ... scrollable content ...            │
└──────────────────────────────────────┘
```

Each pill shows:

- The recipe title (truncated to ~16 chars, falls back to "Recipe").
- A small ⏱ glyph + countdown when that cook has a running timer.
- An "expired" red dot when the timer has fired but the user hasn't
  cleared the ready overlay.
- Filled with `AppColor.accent` for the foregrounded cook;
  `AppColor.surfaceRaised` for the rest.

Tap → `session.switchTo(cookID:)`. Long-press → context menu with
"Remove this cook" (skip-without-finishing escape hatch — useful
when the user accidentally added a recipe to the session).

When `activeCooks.count == 1`, hide the switcher entirely. No
visual chrome until the second cook arrives.

### 5.2 Render one cook at a time

The body below the switcher is the existing single-recipe
`CookModeView` content, with two changes:

1. State reads/writes route through the `cook` binding (§3.2)
   instead of local `@State`.
2. The whole content area is wrapped with `.id(cook.id)` so
   switching swaps the view tree cleanly. No half-animated state
   bleeding between recipes.

The existing animations (servings scaler, strike-through,
timer-banner appear/disappear) all stay scoped within one cook's
view tree and behave normally on switch — they re-apply from
"current" state, not from "previous cook's" state.

### 5.3 The mark-as-cooked button

Today's "Mark as cooked" exits Cook Mode entirely. New behavior:

- If `activeCooks.count == 1`: same as today — finishes, marks the
  recipe, dismisses Cook Mode.
- If `activeCooks.count >= 2`: finishes, marks the recipe,
  *removes this cook from the session*, switches to the next cook
  in `activeCooks` order. Cook Mode stays open. Brief banner: "[Recipe] is done. {N} cook{s} still going."

`Recipe.markCooked()` (existing model method) runs in both paths.

---

## 6. Timer registry — fan-out by recipe ID

Three singletons today need to become per-cook:

| Singleton today | Becomes | Keyed on |
| --- | --- | --- |
| `TimerLiveActivityController` (one `Activity`) | Registry of N controllers | `ActiveCook.id` |
| `TimerNotifications` (one identifier `cooking-timer`) | Per-cook notification IDs | `cooking-timer-<cookID>` |
| `AlarmPlayer` (one `AVAudioPlayer`) | One per cook OR shared queue | `ActiveCook.id` (see 6.3) |

### 6.1 `TimerLiveActivityController` → registry

```swift
@MainActor
final class TimerLiveActivityRegistry {
    private var controllers: [UUID: TimerLiveActivityController] = [:]

    func start(cookID: UUID, recipeID: UUID, recipeTitle: String,
               endDate: Date, label: String, stepNumber: Int) {
        let controller = controllers[cookID] ?? TimerLiveActivityController()
        controllers[cookID] = controller
        controller.start(recipeID: recipeID, recipeTitle: recipeTitle,
                         endDate: endDate, label: label, stepNumber: stepNumber)
    }

    func update(cookID: UUID, endDate: Date, label: String, stepNumber: Int) {
        controllers[cookID]?.update(endDate: endDate, label: label, stepNumber: stepNumber)
    }

    func end(cookID: UUID) {
        controllers[cookID]?.end()
        controllers.removeValue(forKey: cookID)
    }

    func endAll() {
        controllers.values.forEach { $0.end() }
        controllers.removeAll()
    }

    /// Re-attach to any Live Activities that survived an app kill.
    /// Keyed on `recipeID` baked into `TimerAttributes` — we round-trip
    /// it back to `cookID` via the session's mapping at restore time.
    func adoptOrphans(_ cookIDByRecipeID: [UUID: UUID]) { ... }
}
```

The registry lives at app level, hung off `RootView` like
`CookingSession` does. `CookModeView` calls it via the session
("the current cook's timer fired, fan it out").

iOS allows roughly 4 concurrent Live Activities per app in
practice. Capping cooks at 4 (§2) keeps us comfortably inside that
limit even if every cook has a running timer.

### 6.2 `TimerNotifications` — per-cook IDs

The current `cooking-timer` identifier is a single slot. Replace
with per-cook IDs:

```swift
enum TimerNotifications {
    private static func identifier(for cookID: UUID) -> String {
        "cooking-timer-\(cookID.uuidString)"
    }

    static func schedule(cookID: UUID, ...) { ... }
    static func cancel(cookID: UUID) { ... }
    static func cancelAll() { ... }
}
```

Two concurrent timers fire two distinct notifications, both
deep-linking to `llamascookbook://cook/<recipeID>?cook=<cookID>`
so the tap path knows which cook to foreground (not just which
recipe).

### 6.3 `AlarmPlayer` — per-cook OR shared, with a tie-break

Two valid designs; pick one:

**Option A — per-cook player.** Each cook owns an `AlarmPlayer`.
Two timers firing back-to-back can produce two overlapping audio
loops. Pro: faithful to "every timer is its own thing". Con:
overlapping loops sound like a fire alarm.

**Option B — shared player with FIFO queue.** One `AlarmPlayer`
instance lives on the registry; a "playing for cook X" tag tracks
the current owner. A second cook's timer firing replaces the
current loop with the second's; the first's ready overlay still
shows but isn't audibly nagging anymore. Pro: no audio chaos. Con:
the user might miss that two timers are demanding attention.

**Recommendation: Option B**, with a visible "second timer ready"
badge on the switcher tab + haptic re-fire on the switcher when
focus moves to the un-acknowledged cook. The audio is one-at-a-
time; the visual + haptic carry the "both demand attention" load.

This is the one open UX call in the doc — flag for review during
implementation.

---

## 7. Live Activity — N concurrent

`TimerAttributes` already carries `recipeID`, so the widget's deep
link works per-recipe today. We need to add `cookID` (or accept
that cookID == recipeID when same recipe isn't duplicated, but
§2.1 ruled that out). Cleanest: add `cookID` as a second field on
the immutable side of `TimerAttributes`.

```swift
struct TimerAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var endDate: Date
        public var label: String
        public var stepNumber: Int
    }
    public var recipeTitle: String
    public var recipeID: UUID
    public var cookID: UUID            // ← new
}
```

Migration concern: existing TestFlight users with a Live Activity
running across the upgrade would have a v1-shaped activity (no
`cookID`). `TimerLiveActivityController.init`'s adoption code
(`Activity<TimerAttributes>.activities.first`) decodes via the
**new** type, so the field's absence triggers a decode failure and
the orphan stays orphaned. Two ways to handle:

1. **Make `cookID` optional** in `TimerAttributes`. Old activities
   decode with `cookID == nil`; the registry treats nil as "match
   the only cook in the session" and adopts.
2. **Force-end orphans on launch.** Iterate
   `Activity<TimerAttributes>.activities` and `.end()` each one
   that doesn't carry a cookID. Safe — the user sees their Dynamic
   Island go quiet on launch but no longer has a stale activity.

Recommendation: (1). It's lossless for the user and the optional
sticks around for one release before we drop it.

The widget UI itself doesn't change — it renders from
`recipeTitle` + `endDate` + `label` + `stepNumber`. The widget
stack on the lock screen / Dynamic Island handles N concurrent
activities natively (iOS rotates / stacks them).

---

## 8. Notifications + alarm fan-out

Already covered in §6.2 / §6.3 mechanically. Two policy decisions
worth landing in the doc:

### 8.1 Two notifications fire in the same minute

iOS coalesces these into a notification group automatically. The
banner stack on the lock screen reads:

```
Llamas Cookbook
  Brownies — Step 4 ready
  Bake at 350° for 25 min — tap to check it off.

Llamas Cookbook
  Pasta Sauce — Step 6 ready
  Simmer for 5 min — tap to check it off.
```

No engineering work required; the existing per-notification copy
already includes the recipe title. Just verify the grouping
behaves on a real device during the test pass.

### 8.2 Tap routing

Each notification's `userInfo` carries `recipeID` + `cookID`
(§6.2). The deep-link path in `RootView.onOpenURL`:

```swift
// llamascookbook://cook/<recipeID>?cook=<cookID>
guard let recipeID = parseCookDeepLink(url) else { return }
let cookID = parseCookID(url)
session.foreground(cookID: cookID, recipeID: recipeID, lookup: lookupRecipe)
```

`session.foreground` finds the matching cook in `activeCooks` and
sets `foregroundedCookID`. If the tap arrived while the app is
cold, `restore` rehydrates first; if neither the cook nor its
recipe still exists (rare race), the deep link no-ops gracefully.

---

## 9. Persistence — versioned array snapshot

[`CookingSessionStore`](./ios-native/Sources/App/CookingSessionState.swift)
moves from `CookingSessionState?` to `[CookingSessionState]`:

```swift
enum CookingSessionStore {
    private static let key = "cooking-session-states.v2"
    private static let legacyKeyV1 = "cooking-session-state.v1"

    static func load() -> [CookingSessionState] {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([CookingSessionState].self, from: data) {
            return decoded
        }
        // v1 migration: wrap the single-cook payload in an array.
        if let data = UserDefaults.standard.data(forKey: legacyKeyV1),
           let single = try? JSONDecoder().decode(CookingSessionState.self, from: data) {
            UserDefaults.standard.removeObject(forKey: legacyKeyV1)
            save([single])
            return [single]
        }
        return []
    }

    static func save(_ states: [CookingSessionState]) { ... }
    static func clear() { ... }
}
```

`CookingSessionState` itself gains the `cookID` field so
restoration round-trips the right cook → activity mapping.

The migration is a one-shot read on first launch with v2 code; a
user mid-cook during the upgrade keeps their session.

---

## 10. Add a cook — entry points

### 10.1 Recipe Detail "Start Cooking" button

Today's button starts a session unconditionally. New behavior
depends on `session.activeCooks.count`:

| State | Button text | On tap |
| --- | --- | --- |
| `activeCooks.isEmpty` | "Start Cooking" | `session.start(recipe)` (existing path) |
| `activeCooks.count >= 1` and recipe not already in session | "Start Cooking" + secondary action sheet | "Cook in parallel" → `addParallel(recipe)` ; "End current and start new" → `start(recipe)` (replaces) |
| Recipe already in session | "Resume Cooking" | `session.foreground(cookID:)` for that cook |
| `activeCooks.count == maxConcurrentCooks` | "Start Cooking" disabled w/ tooltip "End a cook to add another" | Long-press surfaces an explainer |

### 10.2 Library resume pill

Today shows one cook. Plural-ize:

```
┌─────────────────────────────────────────────────────────┐
│ 🍴 COOKING (2)                                          │
│   Brownies          Bake     2:14 ⏱                     │
│   Pasta Sauce       Simmer   0:45 ⏱                     │
└─────────────────────────────────────────────────────────┘
```

- One row per active cook. Tap a row → `session.foreground(cookID:)`
  + `session.resume()`.
- Tap empty space at the top → resume to the most-recently-foregrounded cook.
- The earliest-firing timer's countdown is rendered with `Text(timerInterval:)`
  per row (no app-side ticking).

When `activeCooks.count == 1`, fall back to today's single-recipe
pill — the new layout is opt-in for the multi case.

### 10.3 Adding from inside Cook Mode

The switcher's right edge gets a "+" tab when
`activeCooks.count < maxConcurrentCooks`. Tapping pushes a sheet
that presents the Library list (filtered, scrollable, same as the
Library tab) — tapping a recipe adds it via `addParallel(_:)` and
foregrounds it.

Why bake this in rather than forcing the user back to Library:
once the session is running, Cook Mode is a `.fullScreenCover` —
escaping to Library means minimize + tap pill + scroll + tap
recipe + tap "Cook in parallel". A single in-Cook-Mode add path
collapses that to two taps.

---

## 11. Resume / minimize / tuck-down

The `.height(80)` minimize detent goes away in favor of "minimize
hides the cover, resume pill carries the load" — this is already
the behavior today (cooking detent was simplified in a prior pass).

The pill (§10.2) is the only minimized surface. Live Activities
handle the lock-screen / Dynamic Island side; both stack natively.

---

## 12. File inventory

### New files (1)

```
ios-native/Sources/Lib/TimerLiveActivityRegistry.swift   ← §6.1
```

Possibly a second:

```
ios-native/Sources/Views/Cook/CookModeSwitcherStrip.swift   ← §5.1 (optional split if CookModeView gets unwieldy)
```

### Modified files (10)

```
ios-native/Sources/App/CookingSession.swift                ← §2 — pluralize
ios-native/Sources/App/CookingSessionState.swift           ← §3, §9 — ActiveCook + array store + cookID + migration
ios-native/Sources/App/RootView.swift                      ← §4, §10.2 — pill plural-ize, deep-link routing, presentation gating
ios-native/Sources/Views/Cook/CookModeView.swift           ← §3.2, §5 — view binds to ActiveCook, switcher, mark-cooked routing
ios-native/Sources/Views/Detail/RecipeDetailView.swift     ← §10.1 — start-cooking button branches
ios-native/Sources/Lib/TimerLiveActivityController.swift   ← §6.1 — wrapped by registry; init's orphan-adopt logic shifts
ios-native/Sources/Lib/TimerNotifications.swift            ← §6.2 — per-cook identifiers
ios-native/Sources/Lib/AlarmPlayer.swift                   ← §6.3 — registry of players OR FIFO queue
ios-native/Sources/Shared/TimerAttributes.swift            ← §7 — optional cookID on the immutable side
ios-native/Sources/Views/Library/LibraryView.swift         ← §10.2 — pill rendering for N cooks
```

### Untouched (verify, don't edit)

- `Sources/Models/Recipe.swift` — no schema change. Cooking state is
  not on `Recipe`; it lives in `CookingSession` + UserDefaults.
- `Sources/Models/DraftRecipe.swift` — editor isn't aware of cooks.
- `WidgetExtension/*` — widget renders one Live Activity at a time
  from its own perspective. iOS handles stacking. No widget-side
  changes.
- `Sources/Lib/RecipeImporter*.swift` / `RecipeURLImporter.swift` /
  `RecipeAIParser.swift` — import path is independent.
- `Sources/Views/Editor/*` — editor is independent.

---

## 13. DRY checklist — what's shared, where

| Concern | Single source of truth | Used by |
| --- | --- | --- |
| Per-cook state (phase / strikes / timer / scaler) | `ActiveCook` struct in `CookingSession` | `CookModeView` (binding), `RootView` (resume pill), `CookingSessionStore` (mirror struct for persistence) |
| Live Activity lifecycle for N cooks | `TimerLiveActivityRegistry` | `CookModeView`'s timer paths, `RootView` cleanup |
| Notification fan-out + identifier convention | `TimerNotifications.identifier(for: cookID)` | `CookModeView` start/extend/cancel/stop |
| Persistence shape | `[CookingSessionState]` in `CookingSessionStore` | `CookingSession` (every mutation), restore-on-launch |
| Deep-link parsing | `parseCookDeepLink` + `parseCookID` in `RootView` | `onOpenURL`, notification tap path |
| Cook ID generation | `UUID()` at creation time inside `CookingSession.start` / `addParallel` | Everything keyed on cookID |

Three things deliberately **not** unified:

1. `Recipe.id` and `ActiveCook.id` stay distinct. Same recipe added
   twice is a real case (§2.1).
2. `TimerLiveActivityController` and the new registry stay separate
   types — the controller is the per-activity unit, the registry is
   the bookkeeping layer.
3. The single-cook resume pill and the multi-cook pill aren't a
   "smart pill that handles both"; they're two distinct render paths
   gated on `activeCooks.count`. Trying to unify them produced a
   pill that looked weird in both modes during prototyping.

---

## 14. Risks and mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| `remove(cookID:)` doesn't dismiss when the last cook finishes | **High** — Cook Mode stuck open with no recipes | §4 centralization. Test #4 catches it. |
| Two cooks reach timer-ready inside the same second; alarm logic races | Audio gibberish | §6.3 Option B (FIFO queue with visual badge). |
| User upgrades mid-cook; v1 persistence gets dropped | Lost mid-cook session | §9 v1 → v2 migration on first load. |
| Optional `cookID` on TimerAttributes confuses widget rendering | Lock-screen activity disappears | §7 optional handling; widget doesn't read `cookID` so the renderer is unaffected. |
| `Activity<TimerAttributes>.activities` orphan adoption picks wrong cook | Wrong recipe shows in Dynamic Island after kill+restore | §6.1 `adoptOrphans` keys on `recipeID` first; falls back to nil-cookID = "single-cook session" rule. |
| User adds same recipe twice and gets confused | Cosmetic | Switcher tab labels truncate at recipe title; long-press → "Remove this cook" surfaces the escape hatch. |
| Live Activity quota exceeded when the user runs four cooks each with active timers | Fourth Activity fails to start | `start()` already silently degrades to no-Activity (existing behavior); cooking still works without Dynamic Island. Cap at `maxConcurrentCooks = 4`. |
| Switcher strip overflows on small phones with 4 cooks | Truncated tabs | Horizontal scroll the strip, no fade-out. Phones small enough to truncate the third tab still scroll cleanly. |
| `CookingSessionStore.save` on every mutation hits UserDefaults too hard | Disk thrashing on quick check-off bursts | UserDefaults coalesces writes already, but if measured-bad, batch via `Task` that saves on the next runloop tick. |

---

## 15. Test plan — must-pass before merge

Walk on real device after each TestFlight install:

1. **Single cook unchanged.** Start one recipe. Cook through a step.
   Phase toggle, scaler, timer start/extend/cancel, mark-as-cooked
   all behave identically to today. No switcher visible.
2. **Add a second cook from Detail.** Recipe A active. Open Recipe
   B's Detail. "Start Cooking" surfaces parallel/replace sheet.
   "Cook in parallel" → switcher appears with two pills, B
   foregrounded.
3. **Switch between cooks.** Tap A's pill → A's strikes / scaler /
   phase appear. Tap B's pill → B's. Each cook's state is
   independent and persists across switches.
4. **🚨 Mark-as-cooked on the last cook dismisses Cook Mode.** Two
   cooks active. Mark A as cooked. Cook Mode stays, B foregrounded.
   Mark B as cooked. Cook Mode dismisses. (§4 regression catch.)
5. **🚨 Mark-as-cooked on the foregrounded cook auto-switches.**
   Two cooks active, A foregrounded. Mark A as cooked. Cook Mode
   stays open, B is now foregrounded automatically.
6. **Two timers run in parallel.** Both cooks have active timers
   simultaneously. Both Live Activities visible in Dynamic Island /
   lock screen. Both notifications fire on time, in their own
   notification group rows.
7. **Two timers expire close together.** Start A's 30-sec timer,
   then 5 seconds later start B's 30-sec timer. Both ready overlays
   eligible to surface. Audio plays the most-recent one (Option B
   per §6.3). Foregrounding the other shows its overlay; clearing
   one doesn't clear the other.
8. **Resume pill shows N cooks.** Minimize Cook Mode with two
   cooks. Library shows the multi-row pill. Tap a row → returns to
   that cook. Tap the other → returns to that one.
9. **Force-kill mid-cook restores all cooks.** Two cooks, A's timer
   running. Force-quit. Relaunch. Cook Mode auto-presents with the
   most-recently-foregrounded cook; switcher shows both; A's timer
   is still ticking (Live Activity adoption + persistence both
   work).
10. **v1 → v2 migration.** Install previous TestFlight build, start
    a single cook, upgrade to this build mid-cook. The migrated
    session opens in Cook Mode with the existing cook present and
    correct.
11. **Cap at four cooks.** Add four cooks. Try to add a fifth from
    Detail. Button is disabled with a tooltip. Long-press explains.
12. **Same recipe twice.** Start Brownies. Add Brownies again.
    Switcher shows two distinct tabs both labeled "Brownies".
    Strikes and timers don't bleed between them.
13. **Notification tap routes to the right cook.** Two cooks, A and
    B. Background the app. A's timer fires. Tap notification —
    Cook Mode opens with A foregrounded (not B, even if B was
    foregrounded before backgrounding).
14. **Remove-this-cook from switcher.** Two cooks. Long-press B's
    tab → "Remove". B is removed without Mark-as-Cooked side
    effects (no `markCooked()` call, no `lastCookedAt` update).

Hold the bar at **#1–9 + #13**. If #10–12 wobble slightly, log and
ship anyway. **Don't ship without #4 and #5 passing.**

---

## 16. Sequencing — recommended PR shape

Three pushes minimum, each one CI cycle:

**PR 1 — `feat(cook): pluralize CookingSession (no UI change)`**
- §2 + §3 + §9: `ActiveCook` struct, `CookingSession` array shape,
  `CookingSessionStore` array + v1 migration.
- `start()` keeps single-cook semantics (just wraps in a 1-element
  array under the hood). No new entry points yet.
- §6.1 `TimerLiveActivityRegistry`, §6.2 per-cook notification IDs,
  §6.3 alarm registry — all wired but with one cook in flight, the
  behavior is identical to today.
- §7 `cookID` (optional) on `TimerAttributes`.
- No new UI. Test plan #1 + #10 must pass.

**PR 2 — `feat(cook): switcher + add-parallel from Detail`**
- §5 switcher strip + §5.3 mark-as-cooked routing.
- §10.1 Detail button branches.
- §10.2 multi-row resume pill.
- §10.3 in-Cook-Mode "+" tab.
- Test plan #2–8 + #11–14.

**PR 3 — `feat(cook): kill paths + force-kill restoration`**
- §4 dismiss-when-last-finishes hardening.
- §8 deep-link routing for per-cook notifications.
- §6.1 orphan adoption on launch.
- Test plan #9 + #13 + the must-pass-pair (#4, #5) re-verified.

Why this order:

1. **PR 1 ships infrastructure without changing user-visible
   behavior.** Highest-risk piece (state model + persistence
   migration), best to land alone.
2. **PR 2 ships the user-visible win** with a single dismiss path
   (mark-as-cooked-on-last) still in place from PR 1.
3. **PR 3 hardens the kill / restore / deep-link edges** once the
   shape is settled.

---

## 17. Out of scope (deliberately deferred)

- **Per-recipe sound preferences.** Same alarm sound for all cooks.
- **Smart "these recipes pair well" suggestions.** No ML.
- **Sharing a single timer across recipes** ("simmer 5 min for both
  pots"). Each cook owns its own timers; the user starts two if
  they need two.
- **Servings sync.** Each cook's `currentServings` is independent.
  Doubling A doesn't double B.
- **In-Cook-Mode recipe creation.** The "+" tab adds existing
  recipes only. New recipes still go through the editor flow.
- **Cross-cook ingredient consolidation** ("oh you need flour for
  both"). Out of scope.
- **Background timer audio across cooks** when the app is killed.
  iOS handles per-notification sound; nothing to engineer.
- **Multi-device syncing of active cooks** via iCloud. Cooking is
  ephemeral; the persisted snapshot is local to the device.
- **iPad split-view rendering N cooks side by side.** iPhone first;
  iPad isn't a target family yet (STATE.md §8).

---

## 18. Update these docs after merge

- **STATE.md §1:** capabilities row — split today's "Cook Mode" row
  into "Cook Mode (single)" and "Cook Mode (parallel)" or replace
  with a single row that mentions parallel.
- **STATE.md §3:** mention `ActiveCook` lives in `CookingSession`
  and per-cook state is centralized there now.
- **STATE.md §5:** add `TimerLiveActivityRegistry` and the per-cook
  notification ID convention to shared-helpers list.
- **STATE.md §8:** drop "Multi-recipe Cook Mode" from active-push;
  add any newly-deferred items (per-recipe sound prefs, etc.) to
  Known Limitations.
- **STATE.md §9:** with multi-recipe done, photos becomes the only
  active feature push. Aesthetic pass moves up.
- **PROJECT.md §6 (UX principles):** add a multi-cook principle —
  "switching cooks is one tap, never destructive."
- **ROADMAP.md:** add follow-ups: "per-recipe alarm sound", "iPad
  side-by-side multi-cook layout", "shared-timer across cooks if
  that ever becomes useful in practice."
