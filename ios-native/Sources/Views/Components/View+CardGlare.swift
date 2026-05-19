import SwiftUI

extension View {
    /// Glossy "glare" overlay for card surfaces. Combines three light
    /// behaviors into a single, GPU-cheap overlay:
    ///
    /// 1. **Sweep-in** — a soft diagonal streak slides across the card
    ///    exactly once as it scrolls into view, then settles off-edge.
    ///    Driven by a one-shot `@State` animation fired from `onAppear`
    ///    (state mutates once per appearance, never per frame). Inside a
    ///    `LazyVStack`, rows materialize just before they reach the
    ///    viewport, so the sweep plays as the card arrives.
    /// 2. **Scroll-reactive shine** — a softer highlight whose position
    ///    tracks the card's travel through the viewport, so the surface
    ///    "catches the light" as the user scrolls. Driven entirely by
    ///    `visualEffect`, which runs in SwiftUI's layout pass off the
    ///    main thread and never invalidates `body`.
    /// 3. **Edge depth** — a static, always-on inner edge rim: a faint
    ///    bright highlight along the top edge and a faint dark line along
    ///    the bottom edge ("light from above"), so the card reads as a
    ///    physically raised surface reinforcing its `.liftedCard()`
    ///    shadow. NO state, NO animation, NO `visualEffect` — just a thin
    ///    overlay stroke, free for scroll performance.
    ///
    /// All layers are clipped to `RoundedRectangle(cornerRadius:)` so
    /// nothing bleeds past the card's rounded corners. The moving streak
    /// uses `.blendMode(.plusLighter)` so it brightens rather than paints;
    /// the edge rim composites normally. The whole overlay is
    /// `.allowsHitTesting(false)`.
    ///
    /// Performance: pass the SAME `cornerRadius` the card clips to. Apply
    /// `cardGlare()` on top of a card that is itself flattened with
    /// `.drawingGroup()` (inside its own `.clipShape`) — the glare is a
    /// thin overlay that composites against that flat texture cheaply.
    /// Never apply to a card whose body uses `.blur()` / `.regularMaterial`
    /// (per CLAUDE.md › drawingGroup invariant).
    func cardGlare(cornerRadius: CGFloat = AppRadius.lg) -> some View {
        modifier(CardGlareModifier(cornerRadius: cornerRadius))
    }
}

/// Backing modifier for `View.cardGlare(cornerRadius:)`. Renders the
/// moving streak (sweep-in + scroll shine) and a static top/bottom edge
/// depth rim. See that method's doc comment for the behavior contract
/// and call-site rules.
private struct CardGlareModifier: ViewModifier {
    let cornerRadius: CGFloat

    /// Sweep-in progress, 0 → 1. Animated exactly once when the card
    /// first appears. `0` parks the streak off the leading edge; `1`
    /// parks it off the trailing edge so it leaves no residue.
    @State private var sweepProgress: CGFloat = 0
    /// Re-entrancy guard so the sweep plays a single time per card
    /// lifetime — a recycled `LazyVStack` row can fire `onAppear` again.
    @State private var hasSwept = false

    func body(content: Content) -> some View {
        content
            .overlay {
                streak
                    // Clip the streak to the card's rounded silhouette
                    // so the highlight can never spill past the corners.
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .allowsHitTesting(false)
            }
            .overlay {
                edgeDepth
                    .allowsHitTesting(false)
            }
            .onAppear {
                guard !hasSwept else { return }
                hasSwept = true
                sweepProgress = 0
                // One-shot sweep. The animation runs on the render
                // thread once `sweepProgress` flips — a single state
                // mutation, not a per-frame update.
                withAnimation(.easeOut(duration: 0.85)) {
                    sweepProgress = 1
                }
            }
    }

    /// The light streak — a narrow, angled white linear gradient that
    /// fills the card. Its horizontal position is the sum of two
    /// `visualEffect` offsets: the one-shot sweep-in and the continuous
    /// scroll-reactive shine. Both run in the layout pass, so neither
    /// invalidates `body`.
    private var streak: some View {
        LinearGradient(
            colors: [
                .clear,
                Color.white.opacity(0.0),
                Color.white.opacity(0.30),
                Color.white.opacity(0.09),
                .clear
            ],
            startPoint: .init(x: 0.0, y: 0.0),
            endPoint: .init(x: 1.0, y: 1.0)
        )
        .blendMode(.plusLighter)
        // Combined offset:
        //  • sweep-in — parks fully off the leading edge at progress 0,
        //    fully off the trailing edge at progress 1 (±1.6× width
        //    guarantees a clean entry and exit).
        //  • scroll shine — gentle light-catch tied to the card's
        //    travel through the viewport. `geo.bounds(of: .scrollView)`
        //    is resolved in the layout pass off the main thread.
        .visualEffect { effect, geo in
            let width = geo.size.width
            let sweep = (sweepProgress * 2 - 1) * width * 1.6
            let shine = shineOffset(
                width: width,
                viewport: geo.bounds(of: .scrollView)
            )
            return effect.offset(x: sweep + shine)
        }
    }

    /// Scroll-reactive shine offset. Maps the card's vertical position
    /// within the enclosing scroll view to a small horizontal slide of
    /// the highlight — the "light catching a surface" feel. Returns 0
    /// when the card is not inside a scroll view (e.g. previews).
    private func shineOffset(width: CGFloat, viewport: CGRect?) -> CGFloat {
        guard let viewport, viewport.height > 0 else { return 0 }
        // `viewport.midY` is the card's center expressed in the scroll
        // view's bounds — small near the top, large near the bottom.
        // Normalize to -1…1 across the visible span.
        let normalized = max(-1, min(1, (viewport.midY / viewport.height) * 2 - 1))
        // Modest travel so the shine reads as a gentle light-catch
        // rather than a second full sweep competing with the sweep-in.
        return normalized * width * 0.18
    }

    /// Static "raised object" edge depth. A single thin (1pt) inner
    /// stroke filled with a vertical gradient — bright at the very top,
    /// fully clear through the middle, subtly dark at the very bottom —
    /// so the card reads as a physically raised surface lit from above.
    ///
    /// `strokeBorder` insets the stroke entirely within the shape, so the
    /// rim never extends past the rounded corners. Always rendered: no
    /// `@State`, no animation, no `visualEffect` — it costs one static
    /// composited stroke and stays free during scrolling.
    private var edgeDepth: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.42),
                        Color.white.opacity(0.0),
                        Color.black.opacity(0.0),
                        Color.black.opacity(0.16)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
    }
}
