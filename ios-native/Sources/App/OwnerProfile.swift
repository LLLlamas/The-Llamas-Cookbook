import Foundation
import Observation

/// **Pre-SIWA fallback** for the sender display name in app-to-app
/// recipe sharing. The canonical source post-sign-in is
/// `UserAccount.status.identity?.displayName`; envelope-build code
/// (`RecipeDetailView.resolvedSenderDisplayName`) prefers that and
/// falls back to `OwnerProfile.userName` only when the user hasn't
/// signed in yet (the app is usable signed-out for local-only flows).
///
/// Persisted to UserDefaults (parallel pattern to `AppearanceSettings`).
/// `UserAccount.completeSignIn` writes the resolved SIWA name back here
/// once on first sign-in so the value stays in sync; subsequent edits
/// happen through `ProfileView` which writes both surfaces.
///
/// Empty string == not set; share envelopes ship with `sharedBy: nil`
/// and the receiver's Detail hides the provenance line entirely.
@Observable
final class OwnerProfile {
    private static let nameKey = "ownerUserName"

    var userName: String = "" {
        didSet { persist() }
    }

    init() {
        userName = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
    }

    private func persist() {
        UserDefaults.standard.set(userName, forKey: Self.nameKey)
    }
}
