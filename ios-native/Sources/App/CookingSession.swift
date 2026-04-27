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
    }

    /// Tear down the entire session — equivalent to "end all cooks."
    /// Called from CookModeView's close button, Mark-as-cooked, and
    /// the exit confirm dialog.
    func end() {
        endAll()
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
    /// Refuses if the recipe is already an active cook (callers that
    /// want to truly duplicate should call this twice deliberately;
    /// for now the typical "Add another" flow is dedup-by-recipe).
    func addParallel(_ recipe: Recipe) {
        guard canAddCook else { return }
        if activeCooks.contains(where: { $0.recipe.id == recipe.id }) { return }
        let cook = ActiveCook.fresh(for: recipe)
        activeCooks.append(cook)
        foregroundedCookID = cook.id
        CookingSessionStore.save(activeCooks.map { $0.toState() })
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
        isCookModeVisible = true
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
        activeCooks = []
        foregroundedCookID = nil
        isCookModeVisible = false
        pendingRestoration = nil
        CookingSessionStore.clear()
    }
}
