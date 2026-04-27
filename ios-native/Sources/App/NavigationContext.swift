import Foundation

/// Lightweight signal of "which recipe is the user currently viewing
/// in Detail?" Lives at the app root and gets read by the cooking
/// pills bar in `RootView` to decide whether to surface the green
/// "Add to Cook Mode" button next to the existing cook pill(s).
///
/// Detail writes `detailedRecipeID` on appear, clears it on disappear.
/// Other surfaces (Library, Editor, sheets) leave it nil. The pills
/// bar only shows the add affordance when:
///   - a session is minimized (`activeCooks.isEmpty == false`,
///     `isCookModeVisible == false`),
///   - a recipe is being viewed (`detailedRecipeID != nil`),
///   - that recipe isn't already in the active cooks,
///   - the cap (`maxConcurrentCooks`) hasn't been reached.
///
/// Kept as a separate type so it doesn't bloat `CookingSession` with
/// "what screen am I on" concerns — the session shouldn't know about
/// Detail's existence.
@Observable
final class NavigationContext {
    var detailedRecipeID: UUID?
}
