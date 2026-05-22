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
        // Header + categories are a "page pre-roll" — both go live at
        // t=0 so the visible chrome above the recipe list lights up as
        // a single beat. The strictly-ordered sequence then runs
        // through the recipe list (one card at a time, staggered locally
        // inside `RecipeCardView`), then the plus button, then the
        // bottom tab bar.
        case header = 0
        case categories = 1
        case recipeList = 2
        case plusButton = 3
        case bottomNav = 4
    }

    /// Nine-zone cascade for RecipeDetailView. Fires in parallel with
    /// the library cascade — separate state so rawValue ordering doesn't
    /// cross-contaminate between the two ripples.
    enum DetailTransitionStage: Int, Equatable {
        case nav = 0
        case title = 1
        case provenance = 2
        case ingredientsHeading = 3
        case chips = 4
        case ingredients = 5
        case stepsHeading = 6
        case steps = 7
        case cookBar = 8
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
    var detailTransitionStage: DetailTransitionStage?

    /// Monotonically incremented every time a new accent cascade begins.
    /// `RecipeCardView` observes this to schedule its own per-index glow
    /// (top card glows first, each subsequent row delayed by
    /// `recipeCardGlowStagger`). Using a token (rather than the
    /// `.recipeList` flag directly) means each new cascade re-fires the
    /// per-card stagger even if the recipe-list flag would otherwise
    /// look unchanged from the card's local perspective.
    var recipeCardCascadeToken: Int = 0

    /// Per-card stagger for the recipe-list portion of the cascade.
    /// Tuned so a typical visible run of 5–7 cards completes in ~0.30s.
    static let recipeCardGlowStagger: TimeInterval = 0.05

    /// How long each card's glow stays "on" before fading. Matches the
    /// short pulse used by header / categories / plus / bottom-nav so
    /// every surface in the sequence has the same visual weight.
    static let recipeCardGlowHoldDuration: TimeInterval = 0.18

    /// Live, uncommitted accent shown while `AccentColorPicker` is open.
    /// Set continuously from the picker's local `pickerColor` so accent-
    /// tinted chrome (the cookbook title in particular) retints in real
    /// time AND is already correct the instant the sheet begins to
    /// dismiss — without the visible lag of waiting for the picker's
    /// `.onDisappear` commit.
    ///
    /// This is deliberately a SEPARATE property from `accentColor`:
    /// writing `accentColor` mid-picker-session re-snapshots
    /// `UIColorPickerViewController` and drops picks (see `accentColor`
    /// didSet). `previewAccentColor` has no `didSet` side-effects — no
    /// persist, no UIKit sync, no CloudKit mirror — so the picker
    /// invariant stays intact. `AccentColorPicker.body` must NEVER read
    /// this property, or `@Observable` would rebuild the picker subtree.
    /// Cleared by `commitSelection` once the real accent is committed.
    var previewAccentColor: Color?

    // MARK: - Library cascade colors

    var cookbookTitleAccentColor: Color {
        previewAccentColor ?? transitionColor(for: .header)
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

    // MARK: - Detail cascade colors

    var detailNavAccentColor: Color            { transitionColorForDetail(.nav) }
    var detailTitleAccentColor: Color          { transitionColorForDetail(.title) }
    var detailProvenanceAccentColor: Color     { transitionColorForDetail(.provenance) }
    var detailIngredientsHeadingAccentColor: Color { transitionColorForDetail(.ingredientsHeading) }
    var detailChipsAccentColor: Color          { transitionColorForDetail(.chips) }
    var detailIngredientsAccentColor: Color    { transitionColorForDetail(.ingredients) }
    var detailStepsHeadingAccentColor: Color   { transitionColorForDetail(.stepsHeading) }
    var detailStepsAccentColor: Color          { transitionColorForDetail(.steps) }
    var detailCookBarAccentColor: Color        { transitionColorForDetail(.cookBar) }

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

    func isDetailGlowActive(_ stage: DetailTransitionStage) -> Bool {
        detailTransitionStage == stage
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

    private func transitionColorForDetail(_ stage: DetailTransitionStage) -> Color {
        guard let previousAccentColor,
              let detailTransitionStage,
              detailTransitionStage.rawValue < stage.rawValue
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

        // Library cascade — strictly ordered, tightened for snap.
        //
        //   t=0.00   header + categories tint as the "page pre-roll"
        //   t=0.05   recipeList stage activates → bumps
        //            `recipeCardCascadeToken` so each visible
        //            `RecipeCardView` schedules its own glow with an
        //            index-based stagger (top card first). For ~6
        //            visible cards at 0.05s stagger + 0.18s hold the
        //            card cascade finishes around t=0.53.
        //   t=0.55   plus button fires
        //   t=0.72   bottom tab bar fires
        //   t=0.95   clear all transition state
        //
        // The header / categories pre-roll is intentionally fast so the
        // user perceives the strictly-ordered sequence as: cards (one
        // by one) → plus → tab bar — matching Lorenzo's mental model.
        accentTransitionStage = .header
        scheduleAccentStage(.categories,  generation: generation, after: 0.04)
        scheduleAccentStage(.recipeList,  generation: generation, after: 0.10)
        recipeCardCascadeToken &+= 1
        scheduleAccentStage(.plusButton,  generation: generation, after: 0.55)
        scheduleAccentStage(.bottomNav,   generation: generation, after: 0.72)

        // Detail cascade — fires top-to-bottom through RecipeDetailView,
        // interleaved with the library cascade but driven by separate state
        // so rawValue ordering can't cross-contaminate between the two ripples.
        // Tightened to match the snappier library cascade.
        detailTransitionStage = .nav
        scheduleDetailStage(.title,              generation: generation, after: 0.06)
        scheduleDetailStage(.provenance,         generation: generation, after: 0.13)
        scheduleDetailStage(.ingredientsHeading, generation: generation, after: 0.21)
        scheduleDetailStage(.chips,              generation: generation, after: 0.28)
        scheduleDetailStage(.ingredients,        generation: generation, after: 0.35)
        scheduleDetailStage(.stepsHeading,       generation: generation, after: 0.42)
        scheduleDetailStage(.steps,              generation: generation, after: 0.49)
        scheduleDetailStage(.cookBar,            generation: generation, after: 0.55)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in
            guard let self, self.accentTransitionGeneration == generation else { return }
            self.previousAccentColor = nil
            self.accentTransitionStage = nil
            self.detailTransitionStage = nil
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

    private func scheduleDetailStage(
        _ stage: DetailTransitionStage,
        generation: Int,
        after delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.accentTransitionGeneration == generation else { return }
            self.detailTransitionStage = stage
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
