import SwiftUI

/// Cream speech-bubble with an accent stroke and a small triangular
/// tail pointing at the highlighted field. The tail direction is
/// driven by the overlay's quadrant placement; when the bubble sits
/// below the cutout the tail points up, and vice versa.
struct LlamaSpeechBubble: View {
    enum TailEdge { case top, bottom }

    let headline: String
    /// Body copy under the headline. Named `message` rather than the
    /// natural `body` to avoid colliding with SwiftUI's `View.body`
    /// requirement — Swift treats a stored property and the protocol
    /// requirement with the same name as a redeclaration.
    let message: String
    let tailEdge: TailEdge
    /// Horizontal position of the tail along the bubble's edge,
    /// measured 0…1 from the leading edge. The overlay computes this
    /// from the field's centerX relative to the bubble's frame so
    /// the tail stays anchored to the field even when the bubble is
    /// pinned to a side.
    let tailLeading: CGFloat
    /// When false, the bubble draws as a plain rounded-rect with no
    /// tail — used by the centered-fallback path on the first frame
    /// when no target rect has been resolved yet, so a triangular
    /// tail doesn't dangle into empty space.
    var showTail: Bool = true
    let maxWidth: CGFloat

    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
            Text(headline)
                .font(AppFont.sectionHeading)
                .foregroundStyle(appearance.accentColor)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppSpacing.md)
        // A touch more padding on top so the headline isn't kissing
        // the bubble's edge; bottom shaves a notch off the previous
        // 20pt to balance the bump and tighten the bubble overall.
        .padding(.top, AppSpacing.md + AppSpacing.xs)
        .padding(.bottom, AppSpacing.md + AppSpacing.xs)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(
            BubbleShape(tailEdge: tailEdge, tailLeading: tailLeading, showTail: showTail)
                .fill(AppColor.surface)
        )
        .overlay(
            BubbleShape(tailEdge: tailEdge, tailLeading: tailLeading, showTail: showTail)
                .stroke(appearance.accentColor, lineWidth: 1.5)
        )
        .shadow(color: AppColor.shadow, radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Rounded-rect with a small triangular tail on one edge. Tail height
/// and width are intentionally modest (10x16) so the bubble still
/// reads as a primary surface rather than a comic-strip balloon.
private struct BubbleShape: Shape {
    let tailEdge: LlamaSpeechBubble.TailEdge
    let tailLeading: CGFloat
    let showTail: Bool

    private let cornerRadius: CGFloat = AppRadius.lg
    private let tailHeight: CGFloat = 10
    private let tailHalfWidth: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // When the tail is suppressed the bubble's full rect is the
        // body rect — no inset for tail height. Keeps the rounded
        // corners matched to the bubble's own bounds.
        let bodyRect: CGRect
        if !showTail {
            bodyRect = rect
        } else {
            switch tailEdge {
            case .top:
                bodyRect = CGRect(
                    x: rect.minX,
                    y: rect.minY + tailHeight,
                    width: rect.width,
                    height: rect.height - tailHeight
                )
            case .bottom:
                bodyRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: rect.height - tailHeight
                )
            }
        }

        path.addRoundedRect(
            in: bodyRect,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
        )

        guard showTail else { return path }

        // Clamp tail X to keep its base inside the rounded-corner safe
        // zone — otherwise the triangle base sticks out past the curve.
        let minX = bodyRect.minX + cornerRadius + tailHalfWidth
        let maxX = bodyRect.maxX - cornerRadius - tailHalfWidth
        let raw = bodyRect.minX + bodyRect.width * tailLeading
        let centerX = max(minX, min(maxX, raw))

        var tail = Path()
        switch tailEdge {
        case .top:
            tail.move(to: CGPoint(x: centerX, y: rect.minY))
            tail.addLine(to: CGPoint(x: centerX - tailHalfWidth, y: bodyRect.minY))
            tail.addLine(to: CGPoint(x: centerX + tailHalfWidth, y: bodyRect.minY))
            tail.closeSubpath()
        case .bottom:
            tail.move(to: CGPoint(x: centerX, y: rect.maxY))
            tail.addLine(to: CGPoint(x: centerX - tailHalfWidth, y: bodyRect.maxY))
            tail.addLine(to: CGPoint(x: centerX + tailHalfWidth, y: bodyRect.maxY))
            tail.closeSubpath()
        }
        path.addPath(tail)
        return path
    }
}
