import SwiftUI

/// Friend-import success affordance. Two coordinated pieces:
///
///   1. `ImportFlyGhost` — a small accent-tinted token that springs
///      from a top-trailing source (where `FriendRecipeDetailView`'s
///      Import toolbar button lives) toward a bottom-leading anchor
///      (where the Home tab sits in the bottom bar). Lands after
///      ~600ms.
///   2. `SavedToast` — a circular dark badge with a thin white border
///      and a `bookmark.fill` glyph (the same icon used for the friend
///      "Saves" count on friend cards, so the eye reads them as the
///      same semantic). Mounts at screen center and pulses in/out.
///
/// Both are scoped to the friend-import path; they're driven by a
/// single `FriendImportToast` payload on `NavigationContext`.

// MARK: - Saved toast

/// Centered badge in the iOS "delivered" idiom — icon-only so it reads
/// at a glance, with the surrounding fly animation supplying the semantic
/// context. The fill mirrors the *tonal secondary* "Add to grocery list"
/// bar in `RecipeDetailView` (accent at 0.12 opacity + a 1.5pt accent
/// border + accent-tinted glyph) so the toast reads as the same family of
/// translucent affordance rather than an opaque badge — the accent is
/// passed in so a friend's accent (friend-import) or the user's accent
/// (recipe → list) both carry through.
struct SavedToast: View {
    /// SF Symbol shown in the badge. Defaults to the friend-import
    /// bookmark; the add-to-grocery-list toast passes a basket.
    var glyph: String = "bookmark.fill"
    /// Accessibility label describing what was saved/added.
    var label: String = "Saved to your cookbook"
    /// Tint for the tonal fill / border / glyph — matches the
    /// `addToListBar` tonal secondary style.
    var accent: Color = AppColor.accent
    /// Flips true on completion: the badge cutely shrinks toward ~0 and
    /// fades as it's absorbed into the destination tab (see
    /// `RootView.runFriendImportToast`, which also offsets it toward the
    /// tab so the shrink reads as a pop *into* the bar).
    var shrinking: Bool = false

    var body: some View {
        ZStack {
            Circle()
                // Same 0.12 tonal fill the "Add to grocery list" bar uses,
                // layered over the system material so it stays translucent
                // against whatever sits behind the overlay.
                .fill(.ultraThinMaterial)
            Circle()
                .fill(accent.opacity(0.12))
            Circle()
                .strokeBorder(accent.opacity(0.7), lineWidth: 1.5)
            Image(systemName: glyph)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(accent)
                .accentTextOutline()
        }
        .frame(width: 92, height: 92)
        // Cute shrink-and-pop: a soft spring carries scale toward a tiny
        // remnant (not fully 0, so the fade does the final vanish) while
        // the badge fades out — the parent simultaneously offsets it onto
        // the Lists tab so the shrink lands *at* the icon.
        .scaleEffect(shrinking ? 0.05 : 1.0)
        .opacity(shrinking ? 0.0 : 1.0)
        .shadow(color: AppColor.shadow, radius: 14, x: 0, y: 6)
        .accessibilityLabel(label)
    }
}

// MARK: - Fly ghost

/// Animatable token that flies from `source` to `destination` in
/// screen coordinates over `duration`. Renders a small accent-tinted
/// circle wrapping a `bookmark.fill` glyph — same icon used on friend
/// cards' "Saves" count and on the centered toast, so the affordance
/// reads as one continuous gesture.
///
/// Source/destination are passed in screen coords; the parent overlay
/// owns hardcoded anchors (top-trailing for the FriendRecipeDetail
/// import button, bottom-leading for the Home tab) since resolving
/// the actual button frame across the Profile-sheet → NavigationStack
/// hierarchy would mean threading PreferenceKeys through several
/// layers for a 600ms transient.
struct ImportFlyGhost: View {
    let source: CGPoint
    let destination: CGPoint
    let accent: Color
    /// Drives the spring once on appear. Parent flips this from `false`
    /// to `true` immediately after mount; the symmetry pair (source vs.
    /// destination) is selected via `progress`.
    let isFlying: Bool
    /// SF Symbol carried by the token — defaults to the friend-import
    /// bookmark; the add-to-grocery-list toast passes a basket.
    var glyph: String = "bookmark.fill"

    private var position: CGPoint {
        isFlying ? destination : source
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.92))
                .frame(width: 32, height: 32)
                .shadow(color: AppColor.shadow, radius: 6, x: 0, y: 2)
            Image(systemName: glyph)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppColor.onAccent)
        }
        .scaleEffect(isFlying ? 0.55 : 1.0)
        .opacity(isFlying ? 0.0 : 1.0)
        .animation(.easeOut(duration: 0.32), value: isFlying)
        .position(position)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
