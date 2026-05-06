import SwiftUI

/// Possessive-title header used in the principal toolbar slot — the
/// "Lorenzo's Cookbook" treatment from the Library screen, lifted into
/// a reusable view so the Friends tab and `FriendLibraryView` render
/// the exact same font / weight / color / spacing without drift.
///
/// Visual contract (do not tweak without updating all three call sites):
/// - 22pt heavy serif, `tracking(0.2)`, single line with `minimumScaleFactor(0.6)`
///   so longer possessives ("Maximilian's Cookbook") survive on the
///   narrowest iPhone widths next to the 52pt logo and a trailing
///   toolbar glyph.
/// - Color tracks whatever accent the caller passes — local user's on
///   the home + Friends tab, the friend's own accent on
///   `FriendLibraryView` (per `CLAUDE.md` › Friend cookbook tinting).
///
/// `leading` is `@ViewBuilder` so the home call site can wrap the logo
/// in its accent-picker `Button` while the friend surfaces pass the
/// plain logo via the convenience init.
struct CookbookHeader<Leading: View>: View {
    let title: String
    let accent: Color
    let glowActive: Bool
    @ViewBuilder var leading: () -> Leading

    init(
        title: String,
        accent: Color,
        glowActive: Bool = false,
        @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.title = title
        self.accent = accent
        self.glowActive = glowActive
        self.leading = leading
    }

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            leading()
            Text(title)
                .font(.system(size: 22, weight: .heavy, design: .serif))
                .foregroundStyle(accent)
                .shadow(color: accent.opacity(glowActive ? 0.20 : 0), radius: glowActive ? 7 : 0)
                .shadow(color: accent.opacity(glowActive ? 0.08 : 0), radius: glowActive ? 14 : 0)
                .tracking(0.2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.tail)
                .animation(.easeInOut(duration: 0.14), value: glowActive)
        }
        // Trailing breathing room before any topBarTrailing glyph —
        // without this, long possessives run flush against the
        // adjacent toolbar button on iPhone widths.
        .padding(.trailing, AppSpacing.sm)
    }
}

extension CookbookHeader where Leading == LlamaLogo {
    /// Convenience for call sites that just want the brand logo on
    /// the leading edge (no extra tap target). The 52pt size matches
    /// the home toolbar's down-sized logo — large enough to register
    /// as the brand mark, small enough to coexist with the title text
    /// and a trailing toolbar glyph in the principal slot.
    init(title: String, accent: Color, glowActive: Bool = false) {
        self.init(title: title, accent: accent, glowActive: glowActive) {
            LlamaLogo(size: 52, shadowColor: accent)
        }
    }
}
