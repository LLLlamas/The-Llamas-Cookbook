import SwiftUI

struct RecipeCardView: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                Text(recipe.title)
                    .font(AppFont.sectionHeading)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if recipe.favorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(AppColor.accent)
                }
            }

            if let summary = recipe.summary, !summary.isEmpty {
                Text(summary)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(2)
            }

            if !metaParts.isEmpty {
                Text(metaParts.joined(separator: " · "))
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(.top, AppSpacing.xs / 2)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .shadow(color: .black.opacity(0.05), radius: 16, y: 4)
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if let last = recipe.lastCookedAt {
            parts.append("Last cooked \(last.formatted(.dateTime.month(.twoDigits).day(.twoDigits).year()))")
        }
        if recipe.cookCount > 0 {
            parts.append("Cooked \(recipe.cookCount) time\(recipe.cookCount == 1 ? "" : "s")")
        }
        return parts
    }
}
