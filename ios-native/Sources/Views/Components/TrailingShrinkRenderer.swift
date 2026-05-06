import SwiftUI

/// Renders a description that either fits cleanly on one line (no
/// shrinking, no taper) or, when it would overflow, keeps line 0 at
/// full size and paints just the next word — the one that triggered
/// the wrap — onto the trailing edge of line 0 with a per-glyph taper
/// from 1.0 down to `minScale`. The taper replaces ellipsis
/// truncation: anything past that single tapered word is dropped.
///
/// Driven by a `lineLimit(2, reservesSpace: true)` `Text` clipped to
/// one line of visible height: SwiftUI lays the text out across two
/// lines, the renderer reads the wrap from line 1's first word, and
/// the outer `.frame(height:) + .clipped()` hides the unused second
/// line. `reservesSpace` is required so the renderer reliably sees a
/// two-line layout when wrapping; relying on `.fixedSize(vertical:
/// true)` instead silently collapses to a single mid-word-truncated
/// line on iOS 26.
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

        // First pass: find the end of the first word on line 1 and
        // sum its glyphs' natural widths. Glyph rects in a typeset
        // line are flush against each other — the space character is
        // itself a zero-ink glyph slot, not a gap between neighbors —
        // so we detect the boundary by ink width: a glyph with
        // rect.width near zero, following a real letter, is the
        // inter-word space. The first word is glyphs [0, that space's
        // index).
        var totalGlyphs = 0
        var wordEndIndex = Int.max
        var sawNonSpace = false
        var naturalTaperedAdvance: CGFloat = 0
        for run in secondLine {
            for glyph in run {
                let rect = glyph.typographicBounds.rect
                let isInk = rect.width > 0.5
                if totalGlyphs == 0 {
                    sawNonSpace = isInk
                } else if wordEndIndex == Int.max {
                    if sawNonSpace && !isInk {
                        wordEndIndex = totalGlyphs
                    } else if isInk {
                        sawNonSpace = true
                    }
                }
                totalGlyphs += 1
            }
        }
        guard totalGlyphs > 0 else { return }
        if wordEndIndex == Int.max { wordEndIndex = totalGlyphs }
        guard wordEndIndex > 0 else { return }

        let line0Bounds = firstLine.typographicBounds.rect
        let line1Bounds = secondLine.typographicBounds.rect
        let dy = line0Bounds.midY - line1Bounds.midY

        // The taper has to fit inside the gap between line 0's used
        // ink and the laid-out frame's right edge. Per-line
        // `typographicBounds` only tells us how wide each line's ink
        // is — neither line is guaranteed to reach the proposed width
        // (if the wrap word is itself shorter than line 0 minus its
        // last word, line 1 will be the shorter line). The
        // GraphicsContext's clip bounds reflect the Text view's
        // resolved frame, which IS the laid-out width.
        let frameRight = context.clipBoundingRect.maxX
        let widestLine = max(line0Bounds.maxX, line1Bounds.maxX)
        let availableRight = max(frameRight, widestLine)
        let taperStart = line0Bounds.maxX
        let gap = availableRight - taperStart
        guard gap > 0.5 else { return }

        // Second pass: lay out the wrap word's glyphs into
        // [taperStart, taperStart + gap]. The per-glyph scale follows
        // a linear ramp from 1.0 to `minScale` indexed by glyph
        // position in the word, so the visible taper is uniform
        // regardless of glyph widths. The natural tapered word can be
        // wider than the available gap (the word's the reason line 0
        // wrapped in the first place) — in that case the whole word's
        // advances get a single uniform compression so all of it fits
        // and the user sees the full ramp from large to tiny instead
        // of a hard cutoff.
        let denom = CGFloat(max(1, wordEndIndex - 1))
        // Walk the wrap word's glyphs once to sum their natural
        // tapered advances.
        var idx = 0
        for run in secondLine {
            if idx >= wordEndIndex { break }
            for glyph in run {
                if idx >= wordEndIndex { break }
                let t = CGFloat(idx) / denom
                let scale = 1 - (1 - minScale) * t
                naturalTaperedAdvance += glyph.typographicBounds.rect.width * scale
                idx += 1
            }
        }
        let compression = naturalTaperedAdvance > gap
            ? gap / naturalTaperedAdvance
            : 1.0
        var drawn = 0

        var cursorX = taperStart
        for run in secondLine {
            for glyph in run {
                if drawn >= wordEndIndex { return }
                let rect = glyph.typographicBounds.rect
                let t = CGFloat(drawn) / denom
                let scale = (1 - (1 - minScale) * t) * compression
                let scaledAdvance = rect.width * scale

                let targetCenterX = cursorX + scaledAdvance / 2
                let extraDx = targetCenterX - rect.midX

                var glyphContext = context
                glyphContext.translateBy(x: extraDx, y: dy)
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
