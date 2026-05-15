import SwiftUI

/// Subtle four-direction outline used to lift accent-tinted titles
/// against the cream background. Four hard-edged shadows in the
/// cardinal directions, low opacity, painted under whatever soft drop
/// shadow the title itself carries. Originated on `RecipeCardView`'s
/// title; lifted into a reusable modifier so every prominent accent
/// surface (cookbook header, recipe detail title, friend names, etc.)
/// reads as the same kind of letterpressed glyph.
struct AccentTextOutline: ViewModifier {
    /// Per-shadow opacity. Tuned so the outline lifts the glyph edge
    /// without reading as a chunky stroke — bumping this past ~0.3
    /// starts to look like a printed comic-book border instead of a
    /// subtle bevel.
    private static let opacity: Double = 0.22
    /// Cardinal-direction offset. Sub-pixel value so the outline sits
    /// exactly one rendered pixel off the glyph on a 2x/3x screen
    /// without producing visible ghosting between offsets.
    private static let offset: CGFloat = 0.4

    func body(content: Content) -> some View {
        content
            .shadow(color: AppColor.textPrimary.opacity(Self.opacity), radius: 0, x: -Self.offset, y: 0)
            .shadow(color: AppColor.textPrimary.opacity(Self.opacity), radius: 0, x:  Self.offset, y: 0)
            .shadow(color: AppColor.textPrimary.opacity(Self.opacity), radius: 0, x: 0, y: -Self.offset)
            .shadow(color: AppColor.textPrimary.opacity(Self.opacity), radius: 0, x: 0, y:  Self.offset)
    }
}

extension View {
    /// Apply the four-cardinal letterpressed outline to a prominent
    /// accent-tinted text element. See `AccentTextOutline` for the
    /// when / why and the threshold (don't apply to glyphs smaller
    /// than ~13pt — the offset becomes a visible smudge).
    func accentTextOutline() -> some View {
        modifier(AccentTextOutline())
    }

    /// Momentary glow pulse for the accent-color-change ripple sequence.
    /// Pair `active` with `AppearanceSettings.isAccentGlowActive(_:)` and
    /// `color` with the corresponding staged accent color (e.g.
    /// `appearance.recipeListAccentColor`). Safe to stack on top of
    /// `.accentTextOutline()` — shadows are additive.
    func accentGlow(when active: Bool, color: Color) -> some View {
        self
            .shadow(color: color.opacity(active ? 0.16 : 0), radius: active ? 7  : 0)
            .shadow(color: color.opacity(active ? 0.07 : 0), radius: active ? 14 : 0)
            .animation(.easeInOut(duration: 0.14), value: active)
    }
}
