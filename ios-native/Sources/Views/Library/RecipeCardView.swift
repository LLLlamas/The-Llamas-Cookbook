import SwiftUI

struct RecipeCardView: View {
    @Environment(AppearanceSettings.self) private var appearance
    let recipe: Recipe

    private var accent: Color {
        appearance.recipeListAccentColor
    }

    private var glowActive: Bool {
        appearance.isAccentGlowActive(.recipeList)
    }

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
                        .foregroundStyle(accent)
                        .lineLimit(2)
                        .accentTextOutline()
                        .shadow(color: accent.opacity(glowActive ? 0.16 : 0), radius: glowActive ? 7 : 0)
                        .shadow(color: accent.opacity(glowActive ? 0.07 : 0), radius: glowActive ? 14 : 0)
                        .shadow(color: AppColor.shadow, radius: 1.5, x: 0, y: 1)
                        .animation(.easeInOut(duration: 0.14), value: glowActive)
                    Spacer(minLength: 0)
                    if recipe.favorite && !showsHeartThumbnail {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(accent)
                            .shadow(color: accent.opacity(glowActive ? 0.14 : 0), radius: glowActive ? 6 : 0)
                            .animation(.easeInOut(duration: 0.14), value: glowActive)
                    }
                }

                if !recipe.tags.isEmpty {
                    TagChipsRow(tags: recipe.tags, accent: AppColor.accentDeep)
                        .padding(.top, 2)
                }

                if let summary = recipe.summary, !summary.isEmpty {
                    ShrinkingDescriptionView(
                        text: summary,
                        font: Self.summaryFont,
                        color: AppColor.textSecondary
                    )
                }

                Spacer(minLength: AppSpacing.xs)
                dateStack
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            thumbnail
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Slight translucency so the mascot watermark + cream background
        // bleed through — gives the row a layered "frosted card" feel
        // without losing legibility against the page.
        .background(
            LinearGradient(
                colors: [
                    AppColor.surfaceRaised.opacity(0.95),
                    AppColor.surface.opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            // Top-edge bevel — vertical white wash over the upper third.
            LinearGradient(
                colors: [Color.white.opacity(0.22), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .allowsHitTesting(false)
        )
        .overlay(
            // Diagonal glare — light catching the top-left corner,
            // fading toward the center-right. Reads as a physical card
            // surface rather than a flat UI panel.
            LinearGradient(
                colors: [Color.white.opacity(0.13), .clear],
                startPoint: .init(x: 0.0, y: 0.0),
                endPoint: .init(x: 0.65, y: 0.45)
            )
            .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            AppColor.divider.opacity(0.6),
                            AppColor.divider.opacity(0.85)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        // Flatten the card's composited interior (gradients, overlays,
        // glow shadows, image, text shadows) into a single Metal
        // texture before applying the outer shadow stack. During scroll
        // the `scrollTransition` scale/opacity and all three box
        // shadows operate on one flat texture rather than
        // re-compositing the full layer tree per drag frame — the
        // primary fix for scroll jank on cards with photos + glow.
        .drawingGroup()
        // Shared elevation shadow — applied after `.drawingGroup()` so
        // it composites against the card's single flat Metal texture.
        .liftedCard()
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
                ) {
                    // Loading placeholder while async decode runs — matches
                    // the no-photo fallback so the thumbnail slot stays filled.
                    RoundedRectangle(cornerRadius: showsHeartThumbnail ? 0 : AppRadius.md)
                        .fill(AppColor.accentSoft.opacity(0.5))
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .fill(AppColor.accentSoft.opacity(0.5))
                    LlamaLogo(size: 56, shadowColor: accent)
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(thumbnailShape)
        .overlay(
            thumbnailShape
                .stroke(accent.opacity(0.55), lineWidth: 0.8)
        )
        .accentTextOutline()
    }

    /// True when the recipe is favorited — both photo thumbnails and the
    /// llama placeholder are clipped to a heart. No separate heart glyph
    /// next to the title is needed; the shape is the signal.
    private var showsHeartThumbnail: Bool {
        recipe.favorite
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

    private var dateStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Added \(Formatters.date.string(from: recipe.createdAt))")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(AppColor.textSecondary)
                .monospacedDigit()
            if let last = recipe.lastCookedAt {
                Text("Last cooked on \(Formatters.date.string(from: last))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppColor.textTertiary)
                    .monospacedDigit()
            }
        }
    }

    /// Shared `UIFont` for the description row. Drives both the
    /// `ShrinkingDescriptionView` measurement pass and its rendered
    /// glyphs — keeping a single source of truth so measure-vs-draw
    /// can never disagree.
    private static let summaryFont: UIFont = .systemFont(ofSize: 10.5, weight: .medium)
}

/// Heart silhouette for favorited-recipe thumbnails. Built from four
/// cubic Bezier segments — two top lobes whose control points pull
/// toward `y = 0` so the lobes nearly touch the top of the frame, and
/// two side curves tapering to a single bottom point at `y = height`.
/// Filling the full `rect` keeps the heart's footprint identical to
/// the rounded-square thumbnail it replaces.
///
/// The mid-height side control points are pulled `sideBulge` past the
/// rect edges so the lobes bulge outward more at the heart's midline
/// — yielding a slightly wider, rounder silhouette without changing
/// the bottom-tip angle or pushing the visible curve outside `rect`
/// (a cubic Bézier only approaches its control points, never reaches
/// them, so a 7% overshoot here yields ~3-4% wider visible bulge).
private struct HeartShape: Shape {
    /// Horizontal overshoot for the side-most control points, as a
    /// fraction of `rect.width`. Larger values fatten the lobes at
    /// midline; ~0.07 reads as "tiny bit fatter at the sides" without
    /// blob-rounding the silhouette.
    private static let sideBulge: CGFloat = 0.07

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let bulge = w * Self.sideBulge

        path.move(to: CGPoint(x: w / 2, y: h / 4))
        path.addCurve(
            to: CGPoint(x: 0, y: h / 4),
            control1: CGPoint(x: w / 4, y: 0),
            control2: CGPoint(x: 0, y: h / 8)
        )
        path.addCurve(
            to: CGPoint(x: w / 2, y: h),
            control1: CGPoint(x: -bulge, y: h / 2),
            control2: CGPoint(x: w / 4, y: h * 3 / 4)
        )
        path.addCurve(
            to: CGPoint(x: w, y: h / 4),
            control1: CGPoint(x: w * 3 / 4, y: h * 3 / 4),
            control2: CGPoint(x: w + bulge, y: h / 2)
        )
        path.addCurve(
            to: CGPoint(x: w / 2, y: h / 4),
            control1: CGPoint(x: w, y: h / 8),
            control2: CGPoint(x: w * 3 / 4, y: 0)
        )
        return path
    }
}
