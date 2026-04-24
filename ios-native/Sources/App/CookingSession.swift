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
    /// non-nil Recipe causes RootView to present the Cook Mode sheet.
    /// Setting it back to nil dismisses.
    var activeRecipe: Recipe?

    func start(_ recipe: Recipe) {
        activeRecipe = recipe
    }

    func end() {
        activeRecipe = nil
    }
}
