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
        // Strictly-ordered ripple. The All chip leads (it's the most
        // visually prominent control and the user's "home base"), then
        // the page chrome (cookbook title / llama / profile), then the
        // other category chips, then the recipe list itself — which
        // ripples top → bottom one card at a time and drags the letter
        // index along with it — then the plus button, then the bottom
        // tab bar. Compressed total run ~0.7s.
        case allChip = 0
        case header = 1
        case categories = 2
        case recipeList = 3
        case plusButton = 4
        case bottomNav = 5
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

    /// Six-zone cascade for ProfileView. Fires top → bottom through the
    /// signed-in profile sheet in parallel with the library and detail
    /// cascades. Separate state so rawValue ordering is isolated.
    enum ProfileTransitionStage: Int, Equatable {
        case header = 0       // nav icons (⚙/Done) + llama ring/badge/logo
        case colorNudge = 1   // color-nudge palette icon + pick-color button
        case nameCard = 2     // pencil / checkmark edit icon
        case lastCooked = 3   // last-cooked recipe title text
        case requests = 4     // Approve buttons on incoming requests
        case friendsList = 5  // add-friend (+) button + LetterIndex (per-row stagger)
    }

    private static let storageKey = "userAccentHex"

    /// True once the user has explicitly committed a custom accent color.
    /// The hex key is persisted ONLY on a committed pick (never for the
    /// default terracotta — `init` rehydrates without writing, and
    /// `applySignedOut` skips persist via `isForcingDefault`), so the
    /// absence of this key is the canonical "still on default accent"
    /// signal. Read by `LaunchState` for first-run Profile routing and
    /// the one-time color nudge. Static so callers don't need an
    /// `AppearanceSettings` instance.
    static var hasUserPickedAccent: Bool {
        UserDefaults.standard.string(forKey: storageKey) != nil
    }

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
    var profileTransitionStage: ProfileTransitionStage?

    /// Monotonically incremented every time a new accent cascade begins.
    /// `RecipeCardView` observes this to schedule its own per-index glow
    /// (top card glows first, each subsequent row delayed by
    /// `recipeCardGlowStagger`). Using a token (rather than the
    /// `.recipeList` flag directly) means each new cascade re-fires the
    /// per-card stagger even if the recipe-list flag would otherwise
    /// look unchanged from the card's local perspective.
    var recipeCardCascadeToken: Int = 0

    /// Mirrors `recipeCardCascadeToken` for the `LetterIndex` strip —
    /// bumped at the same instant so the strip's per-letter color
    /// advance starts on the same beat as the recipe cards. Separate
    /// token (rather than reusing the card token) so a future change to
    /// either side's timing won't silently break the other.
    var letterIndexCascadeToken: Int = 0

    /// Per-letter stagger token for the `LetterIndex` in ProfileView's
    /// friends list. Bumped at the same instant as the other tokens but
    /// uses `profileFriendsListFlipDelay` (0.33) as its base delay so the
    /// strip fires inside the profile cascade's `.friendsList` beat rather
    /// than the library's `.recipeList` beat.
    var friendLetterCascadeToken: Int = 0

    /// Per-chip stagger token for the category filter strip in LibraryView.
    /// Bumped synchronously at cascade start; each `FilterChip` schedules
    /// its own reveal at `categoriesFlipDelay + index * categoryChipGlowStagger`
    /// so the chips advance left → right rather than all flipping at once.
    var categoryCascadeToken: Int = 0

    /// Read-only snapshot of the accent color in effect immediately
    /// BEFORE the current cascade. `nil` outside of an active cascade.
    /// Used by per-row stagger sites (recipe cards, letter index) that
    /// need to hold the old color locally until their own delay expires
    /// — so the global color flip at `.recipeList` activation doesn't
    /// instantly retint everything in unison.
    var cascadePreviousAccentColor: Color? { previousAccentColor }

    /// Per-card stagger for the recipe-list portion of the cascade.
    /// Tightened (0.05 → 0.035) so a typical visible run of 5–7 cards
    /// completes in ~0.22s and the whole cascade fits in ~0.7s.
    static let recipeCardGlowStagger: TimeInterval = 0.035

    /// How long each card's glow stays "on" before fading. Matches the
    /// short pulse used by header / categories / plus / bottom-nav so
    /// every surface in the sequence has the same visual weight.
    static let recipeCardGlowHoldDuration: TimeInterval = 0.16

    /// Per-letter stagger for the `LetterIndex` cascade — fires in the
    /// same beat as `.recipeList` so the strip retints top → bottom in
    /// lockstep with the recipe cards. Smaller than `recipeCardGlowStagger`
    /// because the strip has ~27 rows; at 0.012 the strip completes in
    /// ~0.32s, comfortably inside the recipe-list beat.
    static let letterIndexGlowStagger: TimeInterval = 0.012

    /// How long each letter's glow holds before fading.
    static let letterIndexGlowHoldDuration: TimeInterval = 0.12

    /// Wall-clock delay between an accent commit and the `.recipeList`
    /// stage firing. Per-row stagger sites (recipe cards + letter index)
    /// add `index * stagger` to this so each row's color advance lands
    /// after the global flip rather than before. Must stay in sync with
    /// the `.recipeList` schedule in `startAccentTransition`.
    static let recipeListFlipDelay: TimeInterval = 0.20

    /// Base delay before the `.friendsList` stage in the profile cascade.
    /// ProfileView's `LetterIndex` uses this instead of `recipeListFlipDelay`
    /// so its per-row stagger fires inside the profile beat (t=0.33), not
    /// the library beat (t=0.20). Must stay in sync with the
    /// `.friendsList` schedule in `startAccentTransition`.
    static let profileFriendsListFlipDelay: TimeInterval = 0.33

    /// Per-chip stagger for the category filter strip in LibraryView.
    /// Chips advance left → right; at 0.025 a 15-chip strip completes
    /// in ~0.375 s, inside the `.categories` → `.recipeList` window.
    static let categoryChipGlowStagger: TimeInterval = 0.025

    /// How long each category chip's glow holds before fading.
    static let categoryChipGlowHoldDuration: TimeInterval = 0.14

    /// Base delay before the first category chip advances. Matches the
    /// `.categories` schedule in `startAccentTransition` so chip 0
    /// reveals exactly when the global stage fires and subsequent chips
    /// trail it one by one.
    static let categoriesFlipDelay: TimeInterval = 0.14

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
        // The title is already showing the new color from `previewAccentColor`
        // by the time the user taps Done. After `commitSelection` clears
        // `previewAccentColor`, `accentColor` is already the new value — return
        // it directly so the cascade's "held previous" never briefly re-applies
        // the old hue to the title. The header stage still fires for the llama
        // glow and profile button; only the title color is excluded.
        previewAccentColor ?? accentColor
    }

    var allChipAccentColor: Color {
        transitionColor(for: .allChip)
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

    // MARK: - Profile cascade colors

    var profileHeaderAccentColor: Color        { transitionColorForProfile(.header) }
    var profileColorNudgeAccentColor: Color    { transitionColorForProfile(.colorNudge) }
    var profileNameCardAccentColor: Color      { transitionColorForProfile(.nameCard) }
    var profileLastCookedAccentColor: Color    { transitionColorForProfile(.lastCooked) }
    var profileRequestsAccentColor: Color      { transitionColorForProfile(.requests) }
    var profileFriendsListAccentColor: Color   { transitionColorForProfile(.friendsList) }

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

    func isProfileGlowActive(_ stage: ProfileTransitionStage) -> Bool {
        profileTransitionStage == stage
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

        // Library cascade — strictly ordered, compressed to ~0.7s total.
        //
        //   t=0.00   All chip — leads the sequence (most prominent
        //            control; the user's "home base"). Goes alone for
        //            ~80ms so the eye registers it before the rest of
        //            the chrome moves.
        //   t=0.08   header (cookbook title + llama + profile button)
        //   t=0.14   categories (Favorites + tag chips)
        //   t=0.20   recipeList — flips the shared `.recipeList` flag
        //            (used by `LetterIndex` glow + recipe-list color
        //            advance) AND bumps both per-row tokens:
        //              · `recipeCardCascadeToken` → each card schedules
        //                its own glow + color-advance with an index-based
        //                delay (stagger 0.035, ~6 cards → ends ~t=0.42).
        //              · `letterIndexCascadeToken` → each letter row
        //                inside `LetterIndex` does the same (stagger
        //                0.012, ~27 rows → ends ~t=0.53).
        //            Cards and letters retint top → bottom in lockstep.
        //   t=0.55   plus button
        //   t=0.66   bottom tab bar
        //   t=0.85   clear all transition state
        accentTransitionStage = .allChip
        scheduleAccentStage(.header,      generation: generation, after: 0.08)
        scheduleAccentStage(.categories,  generation: generation, after: 0.14)
        scheduleAccentStage(.recipeList,  generation: generation, after: 0.20)
        // Tokens bumped now (synchronously) so the per-row schedulers
        // already have their delays running by the time `.recipeList`
        // activates — they consume `cascadePreviousAccentColor` to hold
        // the old hue locally, then commit to the new accent at their
        // own index-based delay.
        recipeCardCascadeToken &+= 1
        letterIndexCascadeToken &+= 1
        // Category chips advance left → right inside the `.categories`
        // beat (base delay 0.14). `friendLetterCascadeToken` fires inside
        // the profile cascade's `.friendsList` beat (base delay 0.33).
        categoryCascadeToken &+= 1
        friendLetterCascadeToken &+= 1
        scheduleAccentStage(.plusButton,  generation: generation, after: 0.55)
        scheduleAccentStage(.bottomNav,   generation: generation, after: 0.66)

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

        // Profile cascade — fires top → bottom through ProfileView in
        // parallel with the library and detail cascades.
        //
        //   t=0.00   header   — nav icons (⚙/Done) + llama ring/badge/logo
        //   t=0.08   colorNudge — palette icon + pick-color button
        //   t=0.14   nameCard   — pencil / checkmark edit icon
        //   t=0.20   lastCooked — last-cooked recipe title text
        //   t=0.26   requests   — Approve buttons on incoming requests
        //   t=0.33   friendsList — (+) button + LetterIndex per-row stagger
        //            `friendLetterCascadeToken` was bumped above; each
        //            letter row wakes at profileFriendsListFlipDelay (0.33)
        //            + index * letterIndexGlowStagger (0.012) — A→Z top→bottom.
        profileTransitionStage = .header
        scheduleProfileStage(.colorNudge,  generation: generation, after: 0.08)
        scheduleProfileStage(.nameCard,    generation: generation, after: 0.14)
        scheduleProfileStage(.lastCooked,  generation: generation, after: 0.20)
        scheduleProfileStage(.requests,    generation: generation, after: 0.26)
        scheduleProfileStage(.friendsList, generation: generation, after: 0.33)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
            guard let self, self.accentTransitionGeneration == generation else { return }
            self.previousAccentColor = nil
            self.accentTransitionStage = nil
            self.detailTransitionStage = nil
            self.profileTransitionStage = nil
        }
    }

    private func transitionColorForProfile(_ stage: ProfileTransitionStage) -> Color {
        guard let previousAccentColor,
              let profileTransitionStage,
              profileTransitionStage.rawValue < stage.rawValue
        else {
            return accentColor
        }
        return previousAccentColor
    }

    private func scheduleProfileStage(
        _ stage: ProfileTransitionStage,
        generation: Int,
        after delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.accentTransitionGeneration == generation else { return }
            self.profileTransitionStage = stage
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
