import Foundation
import SwiftUI

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

    /// Recipe ID that the Library should briefly highlight before the
    /// Detail push lands — RootView sets this after a save flow
    /// (editor sheet, share import) so the user sees the library scroll
    /// to that recipe's row and the A–Z magnify badge flash on the
    /// recipe's letter, then gets pushed through to Detail. Cleared
    /// once the Detail push completes. nil at all other times.
    var pendingHighlightRecipeID: UUID?

    /// Friend-import signal — set by `FriendRecipeDetailView`'s
    /// import handler after the imported recipe lands in SwiftData.
    /// Two observers react to a non-nil value:
    ///
    /// 1. `LibraryView` dismisses the Profile sheet (which is the
    ///    presentation root of the friend-browse flow), so the
    ///    friend's nav stack tears down without manual back-tap.
    /// 2. `RootView` runs its existing `runPostSaveHighlight`
    ///    sequence — wait for sheet dismiss, scroll Library to the
    ///    new recipe, then push its Detail. Reuses the same scroll
    ///    + magnify-badge choreography as the share-import path.
    ///
    /// `RootView` clears the field at the end of the highlight
    /// sequence so a subsequent import fires a fresh transition.
    var pendingImportedRecipeID: UUID?

    /// Bump-token signal for the Library "go home" reset. Writers:
    /// `LibraryView`'s All chip and `RootView`'s bottom-nav Home re-tap
    /// (tap on the active Home tab) — both fire a fresh `Date()`.
    /// Two observers react:
    ///
    /// 1. `RootView` clears `libraryPath` so a pushed Detail page pops
    ///    back to the list (the path lives there, not in LibraryView).
    /// 2. `LibraryView` runs the rest of the reset — filter → `.all`,
    ///    scroll list to top — and owns the no-op guard so a tap with
    ///    nothing to reset costs nothing.
    ///
    /// A timestamp (rather than a Bool) is used so consecutive go-home
    /// taps each fire a distinct value transition without a manual
    /// reset step. Sort is intentionally *not* part of the reset —
    /// `library.sort.v1` is a sticky user preference.
    var goHomeRequestedAt: Date?

    /// Friend-import "Saved" affordance signal. Set by
    /// `FriendRecipeDetailView.performImport` immediately after the
    /// local SwiftData save succeeds, alongside the existing
    /// `pendingImportedRecipeID` push. RootView's overlay observes a
    /// non-nil value, fires the fly-to-tab ghost + spring "Saved"
    /// toast tinted in the friend's accent, and bumps the home-tab
    /// shake marker when the ghost lands. Cleared at the end of the
    /// affordance sequence so a rapid second import re-triggers.
    ///
    /// Scoped to the friend-import path on purpose — share-link and
    /// scratch-entry saves keep their existing
    /// `runPostSaveHighlight`-only behavior.
    var pendingFriendImportToast: FriendImportToast?
}

/// Payload for a "fly to a tab" success toast: a small accent-tinted token
/// springs from the top-trailing corner toward a destination tab while a
/// centered badge pulses. Originally the friend-import "Saved" affordance
/// (bookmark → Home); now also drives the add-to-grocery-list toast
/// (basket → Lists). One overlay + one runner in `RootView` handle both —
/// the payload carries everything that differs.
struct FlyToast: Equatable {
    let id: UUID
    /// Accent that tints the flying token (a friend's accent, or the user's).
    let accentHex: String?
    /// SF Symbol on the flying token and the centered badge.
    let glyph: String
    /// Accessibility label for the centered badge.
    let label: String
    /// Tab the token flies toward in the bottom bar.
    let destinationTab: AppTab

    /// Friend-import "Saved" affordance — bookmark token flying to Home.
    init(accentHex: String?) {
        self.id = UUID()
        self.accentHex = accentHex
        self.glyph = "bookmark.fill"
        self.label = "Saved to your cookbook"
        self.destinationTab = .home
    }

    /// Generic fly toast — e.g. add-to-grocery-list (basket → Lists tab).
    init(accentHex: String?, glyph: String, label: String, destinationTab: AppTab) {
        self.id = UUID()
        self.accentHex = accentHex
        self.glyph = glyph
        self.label = label
        self.destinationTab = destinationTab
    }
}

/// Back-compat alias — the original name from the friend-import-only era.
/// Existing call sites (`FriendImportToast(accentHex:)`) keep working.
typealias FriendImportToast = FlyToast
