import Foundation
import SwiftUI

/// App-level state for "there is a cook session in progress right now."
/// Hoisted to RootView so the Cook Mode sheet lives outside the
/// NavigationStack — that way the user can minimize the sheet to a
/// small detent, navigate freely through Library/Detail/other recipes,
/// and then drag the sheet back up to resume cooking without losing
/// their place.
@Observable
final class CookingSession {
    /// The recipe currently being cooked, if any. Setting this to a
    /// non-nil Recipe causes RootView to present the Cook Mode sheet
    /// (when `isCookModeVisible` is also true). Setting it back to nil
    /// dismisses and tears down the session.
    var activeRecipe: Recipe?

    /// Whether the Cook Mode cover is currently presented. Decoupled from
    /// `activeRecipe` so the user can minimize Cook Mode (cover dismisses,
    /// session keeps running, timer keeps ticking, Live Activity stays up)
    /// and resume later via the Library's resume pill or the Live Activity
    /// tap. False whenever `activeRecipe` is nil.
    var isCookModeVisible: Bool = false

    /// Snapshot from disk waiting to be applied to a freshly-presented
    /// CookModeView. Set by `restore(...)`, consumed by CookModeView's
    /// init. Stays nil for normal "user tapped a recipe" entries — those
    /// go through `start(_:)` and get a fresh snapshot persisted.
    var pendingRestoration: CookingSessionState?

    func start(_ recipe: Recipe) {
        activeRecipe = recipe
        isCookModeVisible = true
        pendingRestoration = nil
        // Seed the persisted state immediately so a crash before the
        // user does anything still leaves us with a recipe ID to recover.
        let snapshot = CookingSessionState(
            recipeID: recipe.id,
            phase: recipe.ingredients.isEmpty ? .cook : .prep,
            currentServings: recipe.servings ?? 0,
            struckIngredientIDs: [],
            struckStepIDs: [],
            timerEndsAt: nil,
            timerStepID: nil,
            timerLabel: "cook",
            timerOriginalMinutes: 0
        )
        CookingSessionStore.save(snapshot)
    }

    func end() {
        activeRecipe = nil
        isCookModeVisible = false
        pendingRestoration = nil
        CookingSessionStore.clear()
    }

    /// Hide the Cook Mode cover but keep the session alive. The timer +
    /// Live Activity keep running; the user can resume from the Library
    /// resume pill or by tapping the Live Activity.
    func minimize() {
        isCookModeVisible = false
    }

    /// Re-present the Cook Mode cover for an already-active session.
    /// Called from the Library resume pill and from the Live Activity
    /// deep-link path when the session was minimized rather than killed.
    /// Pulls the latest snapshot off disk before flipping `isCookModeVisible`
    /// so a fresh CookModeView init reads the user's struck steps + timer
    /// state from `pendingRestoration` (the previous CookModeView instance
    /// was deallocated when the cover dismissed on minimize).
    func resume() {
        guard activeRecipe != nil else { return }
        pendingRestoration = CookingSessionStore.load()
        isCookModeVisible = true
    }

    /// Re-hydrate from disk on app launch. If there's a saved snapshot
    /// and the recipe still exists, sets `activeRecipe` (RootView will
    /// auto-present Cook Mode) and `pendingRestoration` (CookModeView
    /// reads it once during init to restore checkmarks + timer state).
    /// Stale snapshots whose recipe was deleted are cleared silently.
    func restore(using lookup: (UUID) -> Recipe?) {
        guard let state = CookingSessionStore.load() else { return }
        guard let recipe = lookup(state.recipeID) else {
            CookingSessionStore.clear()
            return
        }
        pendingRestoration = state
        activeRecipe = recipe
        isCookModeVisible = true
    }
}
