import Foundation
import Observation

/// Sender display name for app-to-app recipe sharing — surfaced to
/// recipients as "Originally shared by {name}" on imported recipes.
/// Persisted to UserDefaults (parallel pattern to `AppearanceSettings`).
///
/// Captured via the one-time first-share prompt in Recipe Detail
/// (Recipe-Sharing.md §7.4). Never auto-populated from the iOS contact
/// card or device name — the user always opts in by typing. Empty
/// string == not set; share envelopes ship with `sharedBy: nil` and
/// the receiver's Detail hides the provenance line entirely.
@Observable
final class OwnerProfile {
    private static let nameKey = "ownerUserName"
    private static let hasPromptedKey = "ownerUserNamePrompted"

    var userName: String = "" {
        didSet { persist() }
    }

    /// True once the user has seen the first-share prompt — whether
    /// they typed a name or skipped. Subsequent shares skip the prompt
    /// and just emit whatever's stored. A future Settings screen can
    /// reset this to re-prompt on next share.
    var hasPromptedForName: Bool = false {
        didSet { persist() }
    }

    init() {
        userName = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
        hasPromptedForName = UserDefaults.standard.bool(forKey: Self.hasPromptedKey)
    }

    private func persist() {
        UserDefaults.standard.set(userName, forKey: Self.nameKey)
        UserDefaults.standard.set(hasPromptedForName, forKey: Self.hasPromptedKey)
    }
}
