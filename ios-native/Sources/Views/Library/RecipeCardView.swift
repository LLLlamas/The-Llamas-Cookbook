import SwiftUI

struct RecipeCardView: View {
    @Environment(AppearanceSettings.self) private var appearance
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                // Outline = four hard-edged shadows in cardinal directions
                // (radius 0, ±0.6pt offsets) painted onto the text before
                // the soft drop shadow. SwiftUI composes shadows in order,
                // so the outline copies are tightest to the glyph and the
                // warm drop shadow lifts the whole thing off the card.
                Text(StringCase.titleCase(recipe.title))
                    .font(AppFont.sectionHeading)
                    .foregroundStyle(appearance.accentColor)
                    .lineLimit(2)
                    .shadow(color: AppColor.textPrimary.opacity(0.55), radius: 0, x: -0.6, y: 0)
                    .shadow(color: AppColor.textPrimary.opacity(0.55), radius: 0, x: 0.6,  y: 0)
                    .shadow(color: AppColor.textPrimary.opacity(0.55), radius: 0, x: 0,    y: -0.6)
                    .shadow(color: AppColor.textPrimary.opacity(0.55), radius: 0, x: 0,    y: 0.6)
                    .shadow(color: AppColor.shadow, radius: 1.5, x: 0, y: 1)
                Spacer(minLength: 0)
                if recipe.favorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(appearance.accentColor)
                }
            }

            if let summary = recipe.summary, !summary.isEmpty {
                Text(summary)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(2)
            }

            metaFooter
                .padding(.top, 2)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [AppColor.surfaceRaised, AppColor.surface],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(AppColor.divider.opacity(0.6), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .shadow(color: AppColor.shadow, radius: 14, x: 0, y: 4)
        .shadow(color: AppColor.shadowSoft, radius: 2, x: 0, y: 1)
    }

    // MARK: - Meta footer

    /// Tag chips on the leading side, dates on the trailing side. Collapses
    /// to single-line when it fits, wraps to a second line on narrower
    /// titles or long tag lists.
    private var metaFooter: some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            if !recipe.tags.isEmpty {
                tagChips
            }
            Spacer(minLength: AppSpacing.xs)
            dateStack
        }
    }

    private var tagChips: some View {
        HStack(spacing: 4) {
            ForEach(recipe.tags.prefix(2), id: \.self) { tag in
                Text(StringCase.titleCase(tag))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.accentDeep)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(AppColor.accentSoft.opacity(0.7))
                    )
            }
            if recipe.tags.count > 2 {
                Text("+\(recipe.tags.count - 2)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
    }

    private var dateStack: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("Added \(Self.shortDate.string(from: recipe.createdAt))")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppColor.textSecondary)
                .monospacedDigit()
            if let last = recipe.lastCookedAt {
                Text("Cooked \(Self.shortDate.string(from: last))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppColor.textTertiary)
                    .monospacedDigit()
            } else {
                Text("Not cooked yet")
                    .font(.system(size: 10.5))
                    .italic()
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
    }

    /// Shared formatter — M/d/yy keeps the card's right side compact.
    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy"
        return f
    }()
}
