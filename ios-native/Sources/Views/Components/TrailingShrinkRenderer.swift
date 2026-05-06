import SwiftUI

/// Renders a description that either fits cleanly on one line (no
/// shrinking, no taper) or, when it would overflow, keeps line 1 at
/// full size and paints just the next word — the one that triggered
/// the wrap — onto the trailing edge of line 1 with a per-glyph taper
/// from 1.0 down to `minScale`. The taper replaces ellipsis
/// truncation: anything past that single tapered word is dropped.
///
/// Driven by a `lineLimit(2)` `Text`, so SwiftUI's layout tells us
/// whether the string fits and, if not, where the wrap landed.
///
/// Originally lived inside `RecipeCardView`; lifted here so the
/// friend-library card (`FriendLibraryView`) can reuse the exact same
/// shrink behavior on a denormalized `summary` description.
struct TrailingShrinkRenderer: TextRenderer {
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

        // First pass: find the index of the first whitespace glyph on
        // line 1 (after we've seen at least one non-whitespace). Glyph
        // rects in a typeset line are flush against each other — the
        // space character is itself a zero-ink glyph slot, not a gap
        // between neighbors — so we detect the boundary by ink width:
        // a glyph with rect.width near zero, following a real letter,
        // is the inter-word space. The first word is glyphs [0, that
        // space's index).
        var wordEndIndex = Int.max
        var totalGlyphs = 0
        var sawNonSpace = false
        var firstGlyphMinX: CGFloat = 0
        var lastWordGlyphMaxX: CGFloat = 0
        for run in secondLine {
            for glyph in run {
                let rect = glyph.typographicBounds.rect
                let isInk = rect.width > 0.5
                if totalGlyphs == 0 {
                    firstGlyphMinX = rect.minX
                    sawNonSpace = isInk
                } else if wordEndIndex == Int.max {
                    if sawNonSpace && !isInk {
                        wordEndIndex = totalGlyphs
                    } else if isInk {
                        sawNonSpace = true
                    }
                }
                if wordEndIndex == Int.max && isInk {
                    lastWordGlyphMaxX = rect.maxX
                }
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
