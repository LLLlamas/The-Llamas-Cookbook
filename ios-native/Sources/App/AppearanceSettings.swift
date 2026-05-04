import SwiftUI
import UIKit

/// User-customizable accent color. Source of truth for the recipe-title
/// hue and the prominent button fills (FAB +, heart, Save, OK, Start
/// Cooking). Persisted as a hex string in UserDefaults so the choice
/// survives across launches.
///
/// Sibling pattern to `CookingSession` and `EditorCoordinator` — instantiated
/// in `LlamasCookbookApp` and injected via `.environment(...)` at RootView.
@Observable
final class AppearanceSettings {
    private static let storageKey = "userAccentHex"

    /// Suppress mirror pushes during rehydrate-from-UserDefaults so a
    /// cold launch doesn't fire a redundant CloudKit write republishing
    /// the same accent hex that's already there. Flipped false at the
    /// end of `init`; subsequent user-driven didSets push to the
    /// `UserProfileMirror` (debounced).
    private var isInitializing: Bool = true

    var accentColor: Color = AppColor.accent {
        didSet {
            persist()
            // Defer the UIView.appearance() write off the synchronous
            // setter. While the system UIColorPickerViewController is
            // presented, mutating the global appearance proxy in-line
            // re-snapshots the live picker's selectedColor against the
            // binding's pre-write value and detaches subsequent picks
            // from the SwiftUI writeback — the user's first pick lands,
            // then every later pick in the same session is silently
            // dropped. Async-hopping to the next runloop tick lets the
            // binding write settle before UIKit reaches into appearance.
            DispatchQueue.main.async { [weak self] in
                self?.applyToUIKit()
            }
            if !isInitializing, let hex = accentColor.toHex {
                UserProfileMirror.updateAccent(hex)
            }
        }
    }

    init() {
        if let hex = UserDefaults.standard.string(forKey: Self.storageKey),
           let color = Color(hex: hex) {
            // Triggers didSet → applies to UIKit + persists. Mirror push
            // is gated by `isInitializing` so this rehydrate doesn't
            // republish to CloudKit on every cold launch.
            self.accentColor = color
        } else {
            // Default-value init doesn't fire didSet, so apply manually
            // so the first frame's UIKit chrome (keyboard Return key,
            // navigation back chevron, text-edit selection handles) is
            // already on the baseline accent before any view appears.
            applyToUIKit()
        }
        isInitializing = false
    }

    func resetToDefault() {
        accentColor = AppColor.accent
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    private func persist() {
        if let hex = accentColor.toHex {
            UserDefaults.standard.set(hex, forKey: Self.storageKey)
        }
    }

    /// Push the current accent into `UIView.appearance().tintColor` so
    /// UIKit-rendered chrome (keyboard Return key, navigation back
    /// chevron's underlying UIBarButtonItem, selection handles) follows
    /// the user's pick. SwiftUI's own `.tint()` modifier handles the
    /// SwiftUI hierarchy; this covers the UIKit fallthrough.
    ///
    /// Note: `UIView.appearance()` only affects views instantiated
    /// after the change. Views already on screen — like the navigation
    /// bar in a currently-pushed Detail — pick up the change on next
    /// re-render or when the user navigates away and back. SwiftUI's
    /// `.tint()` covers the live-update case for the SwiftUI hierarchy.
    private func applyToUIKit() {
        UIView.appearance().tintColor = UIColor(accentColor)
    }
}
