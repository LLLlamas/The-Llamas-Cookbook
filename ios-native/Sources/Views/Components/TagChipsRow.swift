import SwiftUI

/// Horizontal row of small accent-tinted tag pills used on recipe cards
/// (own library + friend library). Shows the first two tags and an
/// "+N" overflow glyph when there are more.
///
/// Originally inlined inside `RecipeCardView`. Lifted here so the
/// friend-library card can render the same chip rhythm using the
/// friend's accent color, keeping the two surfaces visually aligned.
struct TagChipsRow: View {
    let tags: [String]
    /// Foreground color for the tag text. The chip background is
    /// derived from the same color at low opacity so the tint scales
    /// across both the home library (warm brown accent) and a friend's
    /// cookbook (their chosen accent).
    let accent: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(2), id: \.self) { tag in
                Text(StringCase.titleCase(tag))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(accent.opacity(0.18))
                    )
            }
            if tags.count > 2 {
                Text("+\(tags.count - 2)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
    }
}
