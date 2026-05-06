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
                        // Subtle outline = four hard-edged shadows in
                        // cardinal directions, painted under the soft
                        // drop shadow. Low opacity + small offsets so
                        // it just lifts the glyph edge against the
                        // cream gradient without looking letterpressed.
                        .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: -0.4, y: 0)
                        .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0.4,  y: 0)
                        .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0,    y: -0.4)
                        .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0,    y: 0.4)
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

                if let summary = recipe.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(2)
                        .textRenderer(TrailingShrinkRenderer(source: summary))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(height: Self.summaryLineHeight, alignment: .top)
                        .clipped()
                }

                if !recipe.tags.isEmpty {
                    tagChips
                        .padding(.top, 2)
                }

                Spacer(minLength: AppSpacing.xs)
                dateStack
            }
            .frame(maxHeight: .infinity, alignment: .leading)

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
                    LlamaLogo(size: 56, shadowColor: accent)
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
        VStack(alignment: .leading, spacing: 1) {
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

    /// One-line height of the summary font (10.5pt medium). Used to
    /// clamp the description row so a wrapped layout doesn't reserve
    /// double-height space — the renderer paints the tapered first word
    /// of line 2 onto line 1, so visible content is always one line.
    private static let summaryLineHeight: CGFloat = {
        let font = UIFont.systemFont(ofSize: 10.5, weight: .medium)
        return ceil(font.lineHeight)
    }()
}

/// Renders a description that either fits cleanly on one line (no
/// shrinking, no taper) or, when it would overflow, keeps line 1 at
/// full size and paints just the next word — the one that triggered
/// the wrap — onto the trailing edge of line 1 with a per-glyph taper
/// from 1.0 down to `minScale`. The taper replaces ellipsis
/// truncation: anything past that single tapered word is dropped.
///
/// Driven by a `lineLimit(2)` `Text`, so SwiftUI's layout tells us
/// whether the string fits and, if not, where the wrap landed.
private struct TrailingShrinkRenderer: TextRenderer {
    /// The source string the `Text` was built from. Unused at render
    /// time — kept so the renderer is tied to a specific summary in
    /// the SwiftUI diffing graph (different descriptions get distinct
    /// renderer values, forcing redraws on change).
    var source: String
    /// Scale applied to the trailing edge of the tapered word.
    var minScale: CGFloat = 0.08

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let lines = Array(layout)
        guard let firstLine = lines.first else { return }

        // Single-line layout: text fits, render flat at full scale.
        guard lines.count >= 2 else {
            for run in firstLine {
                for glyph in run {
                    context.draw(glyph)
                }
            }
            return
        }

        // Two-line (or more) layout: line 1 wraps. Draw line 0 as-is,
        // then take just the first word of line 1, reposition it to
        // sit at the end of line 0, and taper its glyphs.
        for run in firstLine {
            for glyph in run {
                context.draw(glyph)
            }
        }

        let secondLine = lines[1]

        // First pass: find the index of the first inter-word gap on
        // line 1. The first wrapped word is everything from glyph 0 up
        // to (but not including) that index. Detect gaps via x-deltas
        // between consecutive glyph rects — intra-word gaps stay near
        // zero, inter-word gaps span an actual space character's width.
        var wordEndIndex = Int.max
        var totalGlyphs = 0
        var prevMaxX: CGFloat? = nil
        var prevHeight: CGFloat = 0
        var sawNonSpace = false
        var firstGlyphMinX: CGFloat = 0
        var lastWordGlyphMaxX: CGFloat = 0
        for run in secondLine {
            for glyph in run {
                let rect = glyph.typographicBounds.rect
                if totalGlyphs == 0 {
                    firstGlyphMinX = rect.minX
                    sawNonSpace = rect.width > 0.5
                } else if wordEndIndex == Int.max, let pmx = prevMaxX {
                    let gap = rect.minX - pmx
                    let threshold = max(1.5, prevHeight * 0.25)
                    if sawNonSpace && gap > threshold {
                        wordEndIndex = totalGlyphs
                    } else if rect.width > 0.5 {
                        sawNonSpace = true
                    }
                }
                if wordEndIndex == Int.max {
                    lastWordGlyphMaxX = rect.maxX
                }
                prevMaxX = rect.maxX
                prevHeight = rect.height
                totalGlyphs += 1
            }
        }
        guard totalGlyphs > 0 else { return }
        if wordEndIndex == Int.max { wordEndIndex = totalGlyphs }

        let line0Bounds = firstLine.typographicBounds.rect
        let line1Bounds = secondLine.typographicBounds.rect
        // Move the wrapped word's glyphs from line 1's start back to
        // line 0's trailing edge, and lift them vertically onto line 0.
        let dx = line0Bounds.maxX - firstGlyphMinX
        let dy = line0Bounds.midY - line1Bounds.midY
        let taperStart = firstGlyphMinX + dx
        let taperEnd = lastWordGlyphMaxX + dx
        let taperWidth = max(0.001, taperEnd - taperStart)

        // Second pass: draw the first `wordEndIndex` glyphs of line 1,
        // shifted onto line 0 and per-glyph scaled along the taper.
        // Each glyph's horizontal advance is also scaled, so the
        // tapered word visually compresses along x rather than
        // occupying its full original width.
        var drawn = 0
        var cursorX = taperStart
        for run in secondLine {
            for glyph in run {
                if drawn >= wordEndIndex { return }
                let rect = glyph.typographicBounds.rect
                let centerX = rect.midX + dx
                let t = min(1, max(0, (centerX - taperStart) / taperWidth))
                let scale = 1 - (1 - minScale) * t

                let scaledAdvance = rect.width * scale
                let targetCenterX = cursorX + scaledAdvance / 2
                let extraDx = targetCenterX - centerX

                var glyphContext = context
                glyphContext.translateBy(x: dx + extraDx, y: dy)
                let anchor = CGPoint(x: rect.midX, y: rect.maxY)
                glyphContext.translateBy(x: anchor.x, y: anchor.y)
                glyphContext.scaleBy(x: scale, y: scale)
                glyphContext.translateBy(x: -anchor.x, y: -anchor.y)
                glyphContext.draw(glyph)

                cursorX += scaledAdvance
                drawn += 1
            }
        }
    }
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
