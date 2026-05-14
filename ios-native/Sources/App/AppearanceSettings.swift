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
    enum AccentTransitionStage: Int, Equatable {
        case header = 0
        case categories = 1
        case recipeList = 2
        case plusButton = 3
        case bottomNav = 4
    }

    private static let storageKey = "userAccentHex"

    /// Suppress mirror pushes during rehydrate-from-UserDefaults so a
    /// cold launch doesn't fire a redundant CloudKit write republishing
    /// the same accent hex that's already there. Flipped false at the
    /// end of `init`; subsequent user-driven didSets push to the
    /// `UserProfileMirror` (debounced).
    private var isInitializing: Bool = true
    /// Suppresses persist + mirror push when `applySignedOut` forces
    /// the visible accent to default without overwriting the user's
    /// stored preference in UserDefaults.
    @ObservationIgnored private var isForcingDefault: Bool = false
    private var previousAccentColor: Color?
    private var accentTransitionGeneration: Int = 0

    var accentTransitionStage: AccentTransitionStage?

    var cookbookTitleAccentColor: Color {
        transitionColor(for: .header)
    }

    var categoryAccentColor: Color {
        transitionColor(for: .categories)
    }

    var recipeListAccentColor: Color {
        transitionColor(for: .recipeList)
    }

    var plusButtonAccentColor: Color {
        transitionColor(for: .plusButton)
    }

    var bottomNavAccentColor: Color {
        transitionColor(for: .bottomNav)
    }

    var accentColor: Color = AppColor.accent {
        didSet {
            // `isForcingDefault` is set by `applySignedOut` — skip all
            // side-effects so we don't overwrite the user's stored preference
            // with terracotta just because they're not signed in right now.
            guard !isForcingDefault else { return }
            persist()
            // Do NOT call applyToUIKit() here. While UIColorPickerViewController
            // is presented, any UIView.appearance() mutation causes UIKit to
            // re-snapshot the picker's selectedColor back onto the SwiftUI binding,
            // dropping every pick after the first. SwiftUI's own .tint() modifier
            // handles live preview inside the SwiftUI hierarchy; UIKit chrome sync
            // is deferred to syncToUIKit(), called explicitly by AccentColorPicker
            // onDisappear so the global tint is updated exactly once after dismiss.
            if !isInitializing, let hex = accentColor.toHex {
                UserProfileMirror.updateAccent(hex)
            }
            if !isInitializing {
                startAccentTransition(from: oldValue)
            }
        }
    }

    /// Sync the current accent into UIKit's global appearance proxy.
    /// Call this after the color picker is dismissed — not during an
    /// active picker session (see accentColor didSet comment above).
    func syncToUIKit() {
        applyToUIKit()
    }

    func isAccentGlowActive(_ stage: AccentTransitionStage) -> Bool {
        accentTransitionStage == stage
    }

    init() {
        if let hex = UserDefaults.standard.string(forKey: Self.storageKey),
           let color = Color(hex: hex) {
            // Mirror push is gated by `isInitializing` so this rehydrate
            // doesn't republish to CloudKit on every cold launch.
            self.accentColor = color
        }
        // Apply to UIKit unconditionally after the stored color (or default)
        // is in place. didSet no longer calls applyToUIKit() to avoid
        // interfering with UIColorPickerViewController during picker sessions.
        applyToUIKit()
        isInitializing = false
    }

    func resetToDefault() {
        accentColor = AppColor.accent
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        applyToUIKit()
    }

    /// Called on sign-out. Reverts the visible accent to terracotta
    /// without overwriting the stored preference — signing back in
    /// restores the user's color via `restoreFromDefaults`.
    func applySignedOut() {
        isForcingDefault = true
        accentColor = AppColor.accent
        isForcingDefault = false
        applyToUIKit()
    }

    /// Called on sign-in. Re-reads the stored preference from UserDefaults
    /// so a sign-out → sign-in cycle within one session restores the color
    /// without requiring a relaunch.
    func restoreFromDefaults() {
        if let hex = UserDefaults.standard.string(forKey: Self.storageKey),
           let color = Color(hex: hex) {
            isInitializing = true
            accentColor = color
            isInitializing = false
        }
        applyToUIKit()
    }

    private func persist() {
        if let hex = accentColor.toHex {
            UserDefaults.standard.set(hex, forKey: Self.storageKey)
        }
    }

    private func transitionColor(for stage: AccentTransitionStage) -> Color {
        guard let previousAccentColor,
              let accentTransitionStage,
              accentTransitionStage.rawValue < stage.rawValue
        else {
            return accentColor
        }
        return previousAccentColor
    }

    private func startAccentTransition(from oldColor: Color) {
        guard oldColor.toHex != accentColor.toHex else { return }

        accentTransitionGeneration &+= 1
        let generation = accentTransitionGeneration
        previousAccentColor = oldColor
        accentTransitionStage = .header

        scheduleAccentStage(.categories, generation: generation, after: 0.22)
        scheduleAccentStage(.recipeList, generation: generation, after: 0.44)
        scheduleAccentStage(.plusButton, generation: generation, after: 0.66)
        scheduleAccentStage(.bottomNav, generation: generation, after: 0.88)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self] in
            guard let self, self.accentTransitionGeneration == generation else { return }
            self.previousAccentColor = nil
            self.accentTransitionStage = nil
        }
    }

    private func scheduleAccentStage(
        _ stage: AccentTransitionStage,
        generation: Int,
        after delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.accentTransitionGeneration == generation else { return }
            self.accentTransitionStage = stage
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
