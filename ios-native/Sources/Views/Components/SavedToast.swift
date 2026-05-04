import SwiftUI

/// Friend-import success affordance. Two coordinated pieces:
///
///   1. `ImportFlyGhost` — a small accent-tinted token that springs
///      from a top-trailing source (where `FriendRecipeDetailView`'s
///      Import toolbar button lives) toward a bottom-leading anchor
///      (where the Home tab sits in the bottom bar). Lands after
///      ~600ms.
///   2. `SavedToast` — a "Saved" pill with a `tray.and.arrow.down.fill`
///      glyph, tinted in the friend's accent at slight transparency.
///      Springs in from the top, lingers ~900–1100ms, then springs
///      back out — slightly outlasting the ghost so the user reads
///      the confirmation after the ghost arrives.
///
/// Both are scoped to the friend-import path; they're driven by a
/// single `FriendImportToast` payload on `NavigationContext`.

// MARK: - Saved toast

struct SavedToast: View {
    /// Friend's resolved accent — falls back to the user's accent when
    /// the friend snapshot didn't carry a hex.
    let accent: Color

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 14, weight: .bold))
            Text("Saved")
                .font(.system(size: 15, weight: .semibold, design: .serif))
        }
        .foregroundStyle(AppColor.onAccent)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm + 2)
        .background(accent.opacity(0.88))
        .clipShape(Capsule())
        .shadow(color: AppColor.shadow, radius: 10, x: 0, y: 4)
        .accessibilityLabel("Saved to your cookbook")
    }
}

// MARK: - Fly ghost

/// Animatable token that flies from `source` to `destination` in
/// screen coordinates over `duration`. Renders a small accent-tinted
/// circle wrapping a `tray.and.arrow.down.fill` glyph — same icon as
/// the toast, so the eye reads them as the same affordance.
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
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppColor.onAccent)
        }
        .scaleEffect(isFlying ? 0.7 : 1.0)
        .opacity(isFlying ? 0.85 : 1.0)
        .position(position)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
