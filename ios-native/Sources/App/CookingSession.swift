import Foundation
import SwiftUI

/// One in-progress cook. Holds a live `Recipe` reference plus the state
/// that defines "where the user is" inside that recipe — phase toggle,
/// servings scale, strike-throughs, timer slot. **PR 1 holds at most
/// one of these**; PR 2's switcher will admit up to
/// `CookingSession.maxConcurrentCooks` for parallel cooking.
///
/// `id` is distinct from `recipe.id` because the same recipe may be
/// cooked twice in parallel (e.g. two batches of cookies, different
/// servings scales) — see [Multi-Recipe-Cook-Mode.md §2.1](../../../Multi-Recipe-Cook-Mode.md).
struct ActiveCook: Identifiable {
    let id: UUID
    var recipe: Recipe
    var phase: Phase
    var currentServings: Int
    var struckIngredientIDs: Set<UUID>
    var struckStepIDs: Set<UUID>
    var timerEndsAt: Date?
    var timerStepID: UUID?
    var timerLabel: String
    var timerOriginalMinutes: Int

    enum Phase: String, Codable {
        case prep, cook
    }

    init(
        id: UUID = UUID(),
        recipe: Recipe,
        phase: Phase,
        currentServings: Int,
        struckIngredientIDs: Set<UUID>,
        struckStepIDs: Set<UUID>,
        timerEndsAt: Date?,
        timerStepID: UUID?,
        timerLabel: String,
        timerOriginalMinutes: Int
    ) {
        self.id = id
        self.recipe = recipe
        self.phase = phase
        self.currentServings = currentServings
        self.struckIngredientIDs = struckIngredientIDs
        self.struckStepIDs = struckStepIDs
        self.timerEndsAt = timerEndsAt
        self.timerStepID = timerStepID
        self.timerLabel = timerLabel
        self.timerOriginalMinutes = timerOriginalMinutes
    }

    /// Build a fresh cook for a recipe — used by `CookingSession.start`.
    /// Phase opens to Prep when there's an ingredient list to work
    /// through, otherwise straight to Cook (matches the single-recipe
    /// behavior pre-multi).
    static func fresh(for recipe: Recipe) -> ActiveCook {
        ActiveCook(
            recipe: recipe,
            phase: recipe.ingredients.isEmpty ? .cook : .prep,
            currentServings: recipe.servings ?? 0,
            struckIngredientIDs: [],
            struckStepIDs: [],
            timerEndsAt: nil,
            timerStepID: nil,
            timerLabel: "cook",
            timerOriginalMinutes: 0
        )
    }

    /// Restore from the persisted snapshot, attaching a freshly-fetched
    /// live `Recipe`. Called from `CookingSession.restore` after the
    /// model context fetches the recipe by ID.
    init(from state: CookingSessionState, recipe: Recipe) {
        self.init(
            id: state.cookID,
            recipe: recipe,
            phase: state.phase == .cook ? .cook : .prep,
            currentServings: state.currentServings,
            struckIngredientIDs: Set(state.struckIngredientIDs),
            struckStepIDs: Set(state.struckStepIDs),
            timerEndsAt: state.timerEndsAt,
            timerStepID: state.timerStepID,
            timerLabel: state.timerLabel,
            timerOriginalMinutes: state.timerOriginalMinutes
        )
    }

    /// Convert to the on-disk Codable mirror. Called whenever the
    /// session writes state back to UserDefaults.
    func toState() -> CookingSessionState {
        CookingSessionState(
            cookID: id,
            recipeID: recipe.id,
            phase: phase == .cook ? .cook : .prep,
            currentServings: currentServings,
            struckIngredientIDs: Array(struckIngredientIDs),
            struckStepIDs: Array(struckStepIDs),
            timerEndsAt: timerEndsAt,
            timerStepID: timerStepID,
            timerLabel: timerLabel,
            timerOriginalMinutes: timerOriginalMinutes
        )
    }

    /// Patch fields from a freshly-built snapshot. **PR-1 shim**:
    /// CookModeView still owns its @State and constructs snapshots on
    /// every change; the session calls this method to mirror those
    /// snapshots into the array element. PR 2 will lift the @State
    /// into ActiveCook directly and remove this method.
    mutating func apply(_ snapshot: CookingSessionState) {
        self.phase = snapshot.phase == .cook ? .cook : .prep
        self.currentServings = snapshot.currentServings
        self.struckIngredientIDs = Set(snapshot.struckIngredientIDs)
        self.struckStepIDs = Set(snapshot.struckStepIDs)
        self.timerEndsAt = snapshot.timerEndsAt
        self.timerStepID = snapshot.timerStepID
        self.timerLabel = snapshot.timerLabel
        self.timerOriginalMinutes = snapshot.timerOriginalMinutes
    }
}

/// App-level cooking-session state. Plural-shaped (`activeCooks: [ActiveCook]`)
/// even though PR 1 only ever holds one — this lets PR 2 add parallel
/// cooks without rewriting the persistence layer or RootView's gating
/// again. Hoisted to RootView so the Cook Mode sheet lives outside the
/// NavigationStack: the user can minimize the sheet, navigate freely
/// through Library/Detail/other recipes, and drag/tap the resume pill
/// to resume cooking without losing their place.
///
/// **`@MainActor`-isolated.** Every caller is already on the main actor
/// in practice (SwiftUI button actions, `RootView.onOpenURL`, `.task`,
/// `.onAppear`), and the session calls into `@MainActor`-isolated
/// `TimerLiveActivityController.endActivities` from `remove(cookID:)`
/// and `endAll()`. Without the explicit isolation, Xcode 26's strict-
/// concurrency check fails the synchronous call to that static method.
@MainActor
@Observable
final class CookingSession {
    /// All cooks currently in flight. PR 1 holds 0 or 1; PR 2's
    /// `addParallel(_:)` admits up to `maxConcurrentCooks`. Order
    /// preserved (newest appended on the right) — the upcoming
    /// switcher renders left-to-right in this order.
    private(set) var activeCooks: [ActiveCook] = []

    /// Which cook is foregrounded inside Cook Mode. Nil iff
    /// `activeCooks` is empty. PR 2's switcher writes this; PR 1
    /// always points at the only cook.
    var foregroundedCookID: UUID?

    /// Whether the Cook Mode cover is currently presented. Decoupled
    /// from `activeCooks` so the user can minimize Cook Mode (cover
    /// dismisses, session keeps running, timers keep ticking, Live
    /// Activity stays up) and resume later via the Library's resume
    /// pill or the Live Activity tap.
    var isCookModeVisible: Bool = false

    /// Snapshot from disk waiting to be applied to a freshly-presented
    /// CookModeView. Set by `restore(...)` and `resume()`, consumed by
    /// CookModeView's init. Stays nil for normal "user tapped Start
    /// Cooking" entries — those go through `start(_:)` and seed a
    /// fresh snapshot directly.
    var pendingRestoration: CookingSessionState?

    /// Convenience for callers that don't care about the plural shape.
    /// Returns the foregrounded cook's recipe, or nil. The resume pill,
    /// RootView's cover binding, and `onOpenURL` deep-link handling
    /// all read this.
    var foregroundedRecipe: Recipe? {
        activeCooks.first(where: { $0.id == foregroundedCookID })?.recipe
    }

    /// True when adding another cook would stay inside the iOS Live
    /// Activity ceiling. Read by PR 2's "Cook in parallel" gating;
    /// PR 1 doesn't surface a parallel-add path.
    var canAddCook: Bool { activeCooks.count < Self.maxConcurrentCooks }

    /// 1-based ordinal of `cookID` among active cooks of the same
    /// recipe — `(1)`, `(2)`, `(3)` so the user can tell which
    /// duplicate-recipe pill they started first. Returns nil when the
    /// recipe is only running once (no suffix needed). Order matches
    /// `activeCooks` (newest appended on the right), so the earliest
    /// cook is `(1)`.
    func duplicateIndex(for cookID: UUID) -> Int? {
        guard let target = activeCooks.first(where: { $0.id == cookID }) else { return nil }
        let sameRecipe = activeCooks.filter { $0.recipe.id == target.recipe.id }
        guard sameRecipe.count > 1 else { return nil }
        guard let pos = sameRecipe.firstIndex(where: { $0.id == cookID }) else { return nil }
        return pos + 1
    }

    /// Practical iOS ceiling on concurrent Live Activities of the same
    /// app. Cap matches §2 of the multi-recipe plan.
    static let maxConcurrentCooks = 4

    // MARK: - Lifecycle

    /// Start a cook session. **PR 1 single-cook semantics**: any
    /// existing cook is ended first (matches today's "Start Cooking on
    /// Recipe B replaces Recipe A" behavior). PR 2's `addParallel(_:)`
    /// will be the non-replacing entry point.
    func start(_ recipe: Recipe) {
        endAll()
        let cook = ActiveCook.fresh(for: recipe)
        activeCooks = [cook]
        foregroundedCookID = cook.id
        isCookModeVisible = true
        pendingRestoration = nil
        // Seed the persisted state immediately so a crash before the
        // user does anything still leaves us with a recipe ID + cook
        // ID to recover from.
        CookingSessionStore.save([cook.toState()])
        // Cloud presence: announce that this user is cooking now so
        // friends' Friends list dots glow. Best-effort; the mirror
        // silently no-ops when iCloud is unavailable. Note: endAll
        // above does NOT fire the cloud "cooking ended" signal, so
        // this set isn't racing a clear from this code path —
        // intentional, see implement-social.md › "cooking lifecycle".
        Task { await UserProfileMirror.recordCookStarted() }
    }

    /// Tear down the entire session — equivalent to "end all cooks."
    /// Called from CookModeView's close button, Mark-as-cooked, and
    /// the exit confirm dialog.
    func end() {
        endAll()
        // Clear the cloud presence flag so friends' Friends-list dots
        // stop glowing for this user. Best-effort. The mirror call
        // lives here (not inside endAll) because the start(_:) → endAll
        // path explicitly does NOT want to fire a clear-then-set pair
        // that races on the cloud — see implement-social.md.
        Task { await UserProfileMirror.recordCookSessionEmpty() }
    }

    /// Add another recipe alongside the existing cooks, no replacement.
    /// Foregrounds the new cook so a follow-up "Resume" tap on its pill
    /// lands the user inside the new recipe. Does **not** flip
    /// `isCookModeVisible`: the user is typically browsing when they
    /// hit this entry point (from a Detail page while a session is
    /// minimized) and the new pill should appear at the bottom rather
    /// than yanking them into Cook Mode.
    ///
    /// Refuses past `maxConcurrentCooks` — the cap matches the iOS
    /// Live Activity ceiling and keeps the pills bar legible.
    /// Same recipe twice is allowed (two batches with different scales,
    /// or two independent runs of the same recipe). Each cook gets its
    /// own `ActiveCook.id`; pills + per-cook state key off that, not
    /// `recipe.id`.
    func addParallel(_ recipe: Recipe) {
        guard canAddCook else { return }
        let cook = ActiveCook.fresh(for: recipe)
        activeCooks.append(cook)
        foregroundedCookID = cook.id
        CookingSessionStore.save(activeCooks.map { $0.toState() })
        // Refresh the cooking-now flag. Each parallel-add resets the
        // cloud `cookingStartedAt` to `.now`, which is fine — the
        // 6-hour staleness window is purely for force-kill recovery
        // and the dot indicator only cares "is the user cooking now."
        Task { await UserProfileMirror.recordCookStarted() }
    }

    /// Foreground a specific cook by ID and re-present Cook Mode. Used
    /// by the multi-cook pills bar — tap pill → that cook becomes the
    /// active rendered cook in CookModeView.
    func foreground(cookID: UUID) {
        guard activeCooks.contains(where: { $0.id == cookID }) else { return }
        foregroundedCookID = cookID
        // Re-read disk for that cook's snapshot so a freshly-built
        // CookModeView seeds @State from the latest persisted values.
        let states = CookingSessionStore.load()
        pendingRestoration = states.first(where: { $0.cookID == cookID })
        isCookModeVisible = true
    }

    /// Drop one cook from the session — used by Mark-as-cooked, the
    /// per-cook exit flow, and `cleanupCooks(forDeletedRecipeID:)`.
    /// Owns *all* per-cook teardown so callers don't have to:
    ///   • End the matching Live Activity (works even when the cook
    ///     was never foregrounded and so no view-level controller
    ///     ever adopted its activity).
    ///   • Cancel the per-cook scheduled notification.
    ///   • Trim `activeCooks`.
    ///   • If the removed cook was foregrounded, hand off to the next
    ///     cook and seed `pendingRestoration` so the rebuilt
    ///     `CookModeView` (via `.id(cookID)` in RootView) reads its
    ///     progress instead of falling into the fresh-start branch.
    ///   • If it was the last cook, fall through to `endAll()`
    ///     (dismisses the cover + clears persistence).
    ///   • Otherwise persist the trimmed array.
    ///
    /// **Critical for multi-cook:** without this method, the only path
    /// from CookModeView's close button was `session.end()` which
    /// wipes every cook regardless of how many are active.
    func remove(cookID: UUID) {
        guard activeCooks.contains(where: { $0.id == cookID }) else { return }
        activeCooks.removeAll { $0.id == cookID }

        // Per-cook cleanup. Lifted out of CookModeView.onDisappear so
        // the session is the single source of truth for cook lifecycle
        // — non-foregrounded cooks (which never had a view) get cleaned
        // up correctly too. Filter by cookID so two parallel cooks of
        // the same recipe don't tear each other's banners down.
        TimerLiveActivityController.endActivities(forCookID: cookID)
        TimerNotifications.cancel(cookID: cookID)

        if activeCooks.isEmpty {
            endAll()
            // Cloud presence: the last live cook just went away, so
            // signal to friends that this user is no longer cooking.
            // Same reason this lives outside `endAll` as in `end()` —
            // start(_:)'s endAll path mustn't race a clear against
            // the subsequent set.
            Task { await UserProfileMirror.recordCookSessionEmpty() }
            return
        }
        if foregroundedCookID == cookID {
            // Don't auto-present the next cook — closing one cook should
            // drop the user back to whatever screen sat behind Cook Mode
            // (Library, Detail, etc.), with the remaining cooks visible
            // as resume pills. Auto-foregrounding the next cook felt like
            // the app yanking the user into a recipe they didn't ask for.
            // Pick a successor for `foregroundedCookID` so the resume
            // pill / Live Activity tap have somewhere to land, but keep
            // the cover dismissed.
            let next = activeCooks.first
            foregroundedCookID = next?.id
            pendingRestoration = next?.toState()
            isCookModeVisible = false
        }
        CookingSessionStore.save(activeCooks.map { $0.toState() })
    }

    /// Drop every cook whose recipe has just been deleted from
    /// SwiftData. Called from the Library / Detail delete paths
    /// **before** `modelContext.delete(recipe)` runs so the session
    /// never holds a dangling reference to a deleted `@Model` object.
    /// Without this guard, tapping a stale pill or a Live Activity
    /// for a deleted recipe would access a SwiftData fault that no
    /// longer exists, producing either a crash or a "ghost" cook
    /// that wedges the resume pill open.
    ///
    /// Cleanup mirrors `remove(cookID:)` per cook removed: ends the
    /// matching Live Activity, cancels its scheduled notification,
    /// trims `activeCooks`, hands off foreground if needed, and
    /// dismisses the cover when the last cook goes away.
    func cleanupCooks(forDeletedRecipeID recipeID: UUID) {
        let doomed = activeCooks.filter { $0.recipe.id == recipeID }
        guard !doomed.isEmpty else { return }
        for cook in doomed {
            remove(cookID: cook.id)
        }
    }

    /// Hide the Cook Mode cover but keep the session alive. Timers +
    /// Live Activity keep running; the user can resume from the
    /// Library resume pill or by tapping the Live Activity.
    func minimize() {
        isCookModeVisible = false
    }

    /// Re-present the Cook Mode cover for an already-active session.
    /// Called from the Library resume pill and from the Live Activity
    /// deep-link path when the session was minimized rather than
    /// killed. Pulls the foregrounded cook's snapshot off disk before
    /// flipping `isCookModeVisible` so a fresh CookModeView init reads
    /// the user's struck steps + timer state from `pendingRestoration`
    /// (the previous CookModeView instance was deallocated when the
    /// cover dismissed on minimize).
    func resume() {
        guard !activeCooks.isEmpty else { return }
        let states = CookingSessionStore.load()
        if let foregroundedID = foregroundedCookID,
           let state = states.first(where: { $0.cookID == foregroundedID }) {
            pendingRestoration = state
        } else {
            pendingRestoration = states.first
        }
        isCookModeVisible = true
    }

    /// Re-hydrate from disk on app launch. Filters out cooks whose
    /// recipe was deleted while the app was away (rare, but a real
    /// case if the user deleted the recipe across the kill). If every
    /// stored cook is stale, the persisted state is cleared silently.
    ///
    /// **Doesn't auto-present Cook Mode.** The user always lands on
    /// Library; the cook pills at the bottom are the resume gesture.
    /// Notification / Live-Activity taps still flip the cover via
    /// `foreground(cookID:)` from `RootView.onOpenURL`, so deep-link
    /// resume continues to work.
    func restore(using lookup: (UUID) -> Recipe?) {
        let states = CookingSessionStore.load()
        guard !states.isEmpty else { return }

        var rehydrated: [ActiveCook] = []
        for state in states {
            guard let recipe = lookup(state.recipeID) else { continue }
            rehydrated.append(ActiveCook(from: state, recipe: recipe))
        }
        guard !rehydrated.isEmpty else {
            CookingSessionStore.clear()
            return
        }
        // Some cooks were filtered out — write back the cleaned set so
        // future loads don't re-do the lookup work.
        if rehydrated.count != states.count {
            CookingSessionStore.save(rehydrated.map { $0.toState() })
        }
        activeCooks = rehydrated
        foregroundedCookID = rehydrated.first?.id
        pendingRestoration = rehydrated.first?.toState()
        // Cover stays dismissed — Library renders, pills bar appears
        // at the bottom, user taps a pill to resume.
    }

    // MARK: - Per-cook updates

    /// **PR-1 shim**: CookModeView still owns its per-cook @State and
    /// constructs `CookingSessionState` snapshots after each mutation;
    /// it pushes them through this method so the session's
    /// `activeCooks` array and the on-disk store stay in sync. PR 2
    /// will lift the @State into `ActiveCook` directly and replace
    /// this call site with per-field bindings on the session.
    func persistForegroundedSnapshot(_ snapshot: CookingSessionState) {
        guard let foregroundedID = foregroundedCookID,
              let idx = activeCooks.firstIndex(where: { $0.id == foregroundedID })
        else { return }
        activeCooks[idx].apply(snapshot)
        CookingSessionStore.save(activeCooks.map { $0.toState() })
    }

    // MARK: - Private

    private func endAll() {
        // End each cook's Live Activity individually so the lock-screen
        // / Dynamic Island state matches the in-app teardown. Note: by
        // the time `remove(cookID:)` falls through to `endAll`, that
        // cook's activity is already ended — the loop covers the
        // "explicit close X / multi-cook tear down everything" path.
        for cook in activeCooks {
            TimerLiveActivityController.endActivities(forCookID: cook.id)
        }
        activeCooks = []
        foregroundedCookID = nil
        isCookModeVisible = false
        pendingRestoration = nil
        CookingSessionStore.clear()
        // Wipe any pending/delivered timer notifications across all
        // cooks (and the legacy single-id from pre-multi installs).
        // remove(cookID:) handles the per-cook case during graceful
        // teardown; this call covers the "kill everything" path and
        // any leftover notifications scheduled before the multi-cook
        // ID convention landed.
        TimerNotifications.cancelAll()
    }
}
