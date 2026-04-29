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

    var accentColor: Color = AppColor.accent {
        didSet {
            persist()
            applyToUIKit()
        }
    }

    init() {
        if let hex = UserDefaults.standard.string(forKey: Self.storageKey),
           let color = Color(hex: hex) {
            // Triggers didSet → applies to UIKit + persists.
            self.accentColor = color
        } else {
            // Default-value init doesn't fire didSet, so apply manually
            // so the first frame's UIKit chrome (keyboard Return key,
            // navigation back chevron, text-edit selection handles) is
            // already on the baseline accent before any view appears.
            applyToUIKit()
        }
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
