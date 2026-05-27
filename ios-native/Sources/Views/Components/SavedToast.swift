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

/// Centered badge in the iOS screen-capture / "delivered" idiom: solid
/// dark fill, thin white ring, big white glyph. Deliberately icon-only
/// so it reads at a glance — the surrounding fly animation supplies
/// the semantic context.
struct SavedToast: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.78))
            Circle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
            Image(systemName: "bookmark.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 92, height: 92)
        .shadow(color: AppColor.shadow, radius: 14, x: 0, y: 6)
        .accessibilityLabel("Saved to your cookbook")
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

    private var position: CGPoint {
        isFlying ? destination : source
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.92))
                .frame(width: 32, height: 32)
                .shadow(color: AppColor.shadow, radius: 6, x: 0, y: 2)
            Image(systemName: "bookmark.fill")
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
