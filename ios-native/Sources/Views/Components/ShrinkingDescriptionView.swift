import SwiftUI
import UIKit

/// Single-line description renderer that replaces hard truncation with a
/// trailing taper. When `text` fits its proposed width, it draws once at
/// full scale. When it doesn't, the prefix that does fit draws normally
/// and the next word — the one that would have triggered the wrap — is
/// drawn at the trailing edge with a per-character linear scale ramp
/// from 1.0 down to `minScale`. Anything past that single tapered word
/// is dropped.
///
/// Replaces the prior `Text/TextRenderer` approach, which was unreliable
/// under combined `.lineLimit(...)` + `.frame(height:)` + `.textRenderer`
/// constraints — `Text.Layout` introspection sometimes only saw a
/// single-line layout and the multi-line branch never engaged, leaving a
/// hard horizontal cutoff with no taper. Driving layout off explicit
/// `NSString` measurement removes that fragility.
struct ShrinkingDescriptionView: View {
    let text: String
    let font: UIFont
    let color: Color
    var minScale: CGFloat = 0.08
    var trailingInset: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            Canvas(rendersAsynchronously: false) { context, size in
                draw(availableWidth: max(0, geo.size.width - trailingInset), in: &context, size: size)
            }
        }
        .frame(height: ceil(font.lineHeight))
    }

    private func draw(
        availableWidth: CGFloat,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard !text.isEmpty, availableWidth > 0 else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(color)
        ]

        let nsText = text as NSString
        let fullWidth = nsText.size(withAttributes: attrs).width
        let centerY = size.height / 2
        // Bottom of the typographic line — used as the anchor for
        // tapered characters so they share a common bottom edge
        // (approximates baseline alignment under uniform scaling).
        let bottomY = (size.height + font.lineHeight) / 2

        if fullWidth <= availableWidth {
            drawString(text, at: CGPoint(x: 0, y: centerY), anchor: .leading, in: &context)
            return
        }

        // Walk word-by-word using whitespace as the boundary. Find the
        // last word whose end fits within `availableWidth`; the next
        // word is the wrap word that gets tapered.
        let words = splitWords(text)
        guard !words.isEmpty else { return }

        var accumulated: CGFloat = 0
        var lastFittingIndex: Int = -1
        for (i, word) in words.enumerated() {
            let segment = (i == 0 ? word : " " + word) as NSString
            let segWidth = segment.size(withAttributes: attrs).width
            if accumulated + segWidth > availableWidth {
                break
            }
            accumulated += segWidth
            lastFittingIndex = i
        }

        // Single word that doesn't fit on its own → entire word is the
        // tapered run, no prefix.
        if lastFittingIndex < 0 {
            drawTaperedWord(
                word: words[0],
                leadingSpace: false,
                startX: 0,
                availableWidth: availableWidth,
                bottomY: bottomY,
                attrs: attrs,
                in: &context
            )
            return
        }

        // Draw the prefix that fits. Anchor at `.bottomLeading` so the
        // prefix shares the same bottom edge the tapered characters
        // will use, keeping the visual baseline consistent.
        let prefix = words[0...lastFittingIndex].joined(separator: " ")
        let prefixWidth = (prefix as NSString).size(withAttributes: attrs).width
        drawString(prefix, at: CGPoint(x: 0, y: bottomY), anchor: .bottomLeading, in: &context)

        guard lastFittingIndex + 1 < words.count else { return }

        // Taper the next word into whatever horizontal space remains.
        // The leading space mirrors the natural inter-word gap.
        let wrapWord = words[lastFittingIndex + 1]
        let remaining = max(0, availableWidth - prefixWidth)
        drawTaperedWord(
            word: wrapWord,
            leadingSpace: true,
            startX: prefixWidth,
            availableWidth: remaining,
            bottomY: bottomY,
            attrs: attrs,
            in: &context
        )
    }

    /// Lay out `word` (optionally preceded by a leading space) as a
    /// sequence of per-character draws inside `[startX, startX +
    /// availableWidth]`. Each character gets a linear scale from 1.0 at
    /// the word start down to `minScale` at the word end. If the
    /// natural tapered width still exceeds `availableWidth`, a uniform
    /// compression factor scales every character so the full ramp is
    /// preserved instead of degrading into a hard cutoff.
    private func drawTaperedWord(
        word: String,
        leadingSpace: Bool,
        startX: CGFloat,
        availableWidth: CGFloat,
        bottomY: CGFloat,
        attrs: [NSAttributedString.Key: Any],
        in context: inout GraphicsContext
    ) {
        guard availableWidth > 0 else { return }
        let composed = leadingSpace ? " " + word : word
        let chars = Array(composed)
        guard !chars.isEmpty else { return }

        let glyphCount = chars.count
        var naturalWidths: [CGFloat] = []
        naturalWidths.reserveCapacity(glyphCount)
        var naturalTaperedTotal: CGFloat = 0
        for (i, ch) in chars.enumerated() {
            let w = (String(ch) as NSString).size(withAttributes: attrs).width
            naturalWidths.append(w)
            let t = glyphCount <= 1 ? 0 : CGFloat(i) / CGFloat(glyphCount - 1)
            let scale = 1 - (1 - minScale) * t
            naturalTaperedTotal += w * scale
        }

        let compression: CGFloat = naturalTaperedTotal > availableWidth && naturalTaperedTotal > 0
            ? availableWidth / naturalTaperedTotal
            : 1.0

        var cursorX = startX
        for (i, ch) in chars.enumerated() {
            let t = glyphCount <= 1 ? 0 : CGFloat(i) / CGFloat(glyphCount - 1)
            let rampScale = 1 - (1 - minScale) * t
            let scale = rampScale * compression

            // Anchor each character at `.bottomLeading` of (cursorX,
            // bottomY) so all glyphs sit on the same bottom edge — the
            // line's typographic bottom — regardless of their scale.
            // No transform/scale juggling: drawing through `Text` at a
            // smaller font size is what produces the per-character
            // shrink. We re-resolve the run with a scaled-down
            // `UIFont` to get genuine smaller glyphs (vs. a transform
            // scale, which can introduce hairline artifacts at low
            // scales).
            let scaledFontSize = max(1, font.pointSize * scale)
            let scaledFont = font.withSize(scaledFontSize)
            var container = AttributeContainer()
            container.font = Font(scaledFont)
            container.foregroundColor = color
            let attributed = AttributedString(String(ch), attributes: container)
            let resolved = context.resolve(Text(attributed))
            context.draw(
                resolved,
                at: CGPoint(x: cursorX, y: bottomY),
                anchor: .bottomLeading
            )

            cursorX += naturalWidths[i] * scale
        }
    }

    /// Resolve a string through `Text` (via `AttributedString`) and
    /// draw it at `point` using the given `anchor`. Bridging through
    /// `AttributedString` preserves the `UIFont` we measured against.
    private func drawString(
        _ string: String,
        at point: CGPoint,
        anchor: UnitPoint,
        in context: inout GraphicsContext
    ) {
        var container = AttributeContainer()
        container.font = Font(font)
        container.foregroundColor = color
        let attributed = AttributedString(string, attributes: container)
        let resolved = context.resolve(Text(attributed))
        context.draw(resolved, at: point, anchor: anchor)
    }

    /// Split on Unicode whitespace, dropping empty segments so runs of
    /// whitespace don't produce zero-width "words" that would break the
    /// fit math.
    private func splitWords(_ string: String) -> [String] {
        string
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
    }
}
