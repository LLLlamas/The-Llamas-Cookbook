import SwiftUI

struct RecipeCardView: View {
    @Environment(AppearanceSettings.self) private var appearance
    let recipe: Recipe

    var body: some View {
        // Two-column layout: textual content on the left, a square photo
        // thumbnail anchored top-right with the date stack pinned at the
        // bottom of the same column. This puts the picture in the user's
        // peripheral path while keeping the dates "right above" reading
        // as a cohesive right rail.
        HStack(alignment: .top, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
                HStack(alignment: .top, spacing: AppSpacing.sm) {
                    Text(StringCase.titleCase(recipe.title))
                        .font(AppFont.sectionHeading)
                        .foregroundStyle(appearance.accentColor)
                        .lineLimit(2)
                        // Subtle outline = four hard-edged shadows in
                        // cardinal directions, painted under the soft
                        // drop shadow. Low opacity + small offsets so
                        // it just lifts the glyph edge against the
                        // cream gradient without looking letterpressed.
                        .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: -0.4, y: 0)
                        .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0.4,  y: 0)
                        .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0,    y: -0.4)
                        .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0,    y: 0.4)
                        .shadow(color: AppColor.shadow, radius: 1.5, x: 0, y: 1)
                    Spacer(minLength: 0)
                    if recipe.favorite && !showsHeartThumbnail {
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

                if !recipe.tags.isEmpty {
                    tagChips
                        .padding(.top, 2)
                }
            }

            VStack(alignment: .trailing, spacing: AppSpacing.sm) {
                thumbnail
                Spacer(minLength: AppSpacing.xs)
                dateStack
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Slight translucency so the mascot watermark + cream background
        // bleed through — gives the row a layered "frosted card" feel
        // without losing legibility against the page.
        .background(
            LinearGradient(
                colors: [
                    AppColor.surfaceRaised.opacity(0.85),
                    AppColor.surface.opacity(0.85)
                ],
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

    // MARK: - Right rail thumbnail

    /// Small rounded square photo anchored at the top of the right
    /// column. Prefers the recipe's first gallery photo; falls back to
    /// a faint photo glyph when the gallery is empty so the card's
    /// right-side rhythm stays consistent across cards with and
    /// without pictures.
    private var thumbnail: some View {
        Group {
            if let photoData = recipe.sortedPhotos.first?.image {
                RecipeImageView(
                    data: photoData,
                    contentMode: .fill,
                    cornerRadius: showsHeartThumbnail ? 0 : AppRadius.md
                )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .fill(AppColor.accentSoft.opacity(0.5))
                    LlamaLogo(size: 56, shadowColor: appearance.accentColor)
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(thumbnailShape)
        .overlay(
            thumbnailShape
                .stroke(AppColor.divider.opacity(0.7), lineWidth: 0.5)
        )
    }

    /// True when the recipe is favorited *and* has a photo. Favorited
    /// recipes without a photo keep the rounded-square llama placeholder
    /// + the heart glyph next to the title, since the placeholder itself
    /// can't carry the heart-shape signal.
    private var showsHeartThumbnail: Bool {
        recipe.favorite && recipe.sortedPhotos.first?.image != nil
    }

    /// Outer clip + stroke shape. Heart for favorited recipes with a
    /// photo; otherwise the standard rounded square. `AnyShape` lets us
    /// reuse the same value for both `.clipShape` and the stroke
    /// overlay so they always agree.
    private var thumbnailShape: AnyShape {
        if showsHeartThumbnail {
            AnyShape(HeartShape())
        } else {
            AnyShape(RoundedRectangle(cornerRadius: AppRadius.md))
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
                Text("Last cooked on \(Self.shortDate.string(from: last))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppColor.textTertiary)
                    .monospacedDigit()
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

/// Heart silhouette for favorited-recipe thumbnails. Built from four
/// cubic Bezier segments — two top lobes whose control points pull
/// toward `y = 0` so the lobes nearly touch the top of the frame, and
/// two side curves tapering to a single bottom point at `y = height`.
/// Filling the full `rect` keeps the heart's footprint identical to
/// the rounded-square thumbnail it replaces.
private struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        path.move(to: CGPoint(x: w / 2, y: h / 4))
        path.addCurve(
            to: CGPoint(x: 0, y: h / 4),
            control1: CGPoint(x: w / 4, y: 0),
            control2: CGPoint(x: 0, y: h / 8)
        )
        path.addCurve(
            to: CGPoint(x: w / 2, y: h),
            control1: CGPoint(x: 0, y: h / 2),
            control2: CGPoint(x: w / 4, y: h * 3 / 4)
        )
        path.addCurve(
            to: CGPoint(x: w, y: h / 4),
            control1: CGPoint(x: w * 3 / 4, y: h * 3 / 4),
            control2: CGPoint(x: w, y: h / 2)
        )
        path.addCurve(
            to: CGPoint(x: w / 2, y: h / 4),
            control1: CGPoint(x: w, y: h / 8),
            control2: CGPoint(x: w * 3 / 4, y: 0)
        )
        return path
    }
}
