import Foundation

/// Wire-format byte caps shared between the main app and the share
/// extension. Lives in `Sources/Shared/` because the share extension
/// can't import `Sources/Lib/RecipeShare.swift` (SwiftData drag), and
/// having two literals drift apart is a real risk.
enum RecipeShareLimits {
    /// Hard cap on inbound `.llamarecipe` bytes — same value enforced
    /// at the share-extension App Group write and the main app's
    /// decode entry. 25 MB lines up with the photo-asset budget.
    static let maxInboundBytes = 25_000_000
}
