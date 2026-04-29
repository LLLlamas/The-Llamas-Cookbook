import Foundation
import Observation

/// Sender display name for app-to-app recipe sharing — surfaced to
/// recipients as "Originally shared by {name}" on imported recipes.
/// Persisted to UserDefaults (parallel pattern to `AppearanceSettings`).
///
/// Read directly at envelope-build time. Empty string == not set;
/// share envelopes ship with `sharedBy: nil` and the receiver's Detail
/// hides the provenance line entirely. There is no first-share prompt —
/// users who care about provenance set their name in Profile (or via
/// Sign-in-with-Apple, which auto-populates this field).
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
