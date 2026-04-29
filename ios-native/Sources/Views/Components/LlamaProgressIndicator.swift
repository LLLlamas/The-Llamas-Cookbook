import SwiftUI

/// Branded indeterminate-progress indicator: the `LlamaLogo` with a
/// pulsing drop-shadow halo that "breathes" outward — start with nearly
/// no shadow, swelling to a dramatic glow, then back down — to signal
/// ongoing activity while preserving the llama's transparent silhouette.
///
/// Replaces a plain `ProgressView` spinner in the cloud-share upload
/// overlay (`RecipeDetailView.cloudShareLoadingOverlay`) — the
/// recognizable logo signals "the app is working" while the pulsing
/// halo carries the indeterminate-progress affordance, so users don't
/// wonder whether it's frozen during a slow upload.
///
/// Halo follows alpha: SwiftUI's `.shadow(...)` modifier renders shadow
/// from the source view's alpha channel, so applying it to the
/// transparent llama PNG produces a halo shaped like the llama's
/// silhouette — not a square box of blur revealed bottom-to-top, which
/// is what the previous `Circle()`-mask implementation produced and
/// what made the indicator look like "the llama lives in a colored
/// rectangle that's filling up." The brand mark stays recognizable
/// through the entire pulse cycle.
///
/// Animation strategy: `TimelineView(.animation)` drives a sinusoidal
/// triangular wave (rises 0→1, falls 1→0, repeats) at ~1.4s per cycle.
/// `TimelineView` is the right primitive for indeterminate progress
/// because it bypasses SwiftUI's `@State`+`withAnimation` lifecycle
/// (no risk of getting "stuck at 1" if the view re-presents quickly,
/// no need to manually reset on re-appear). Cosine smoothing at the
/// apex avoids the jolt of a raw triangle wave.
struct LlamaProgressIndicator: View {
    var size: CGFloat = 80
    var accent: Color = AppColor.accent

    /// Cycle period in seconds. ~1.4s reads as "patient but
    /// progressing"; faster feels jittery, slower feels stuck.
    private let cycleDuration: TimeInterval = 1.4

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let phase = elapsed.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
            // Triangular wave: 0 → 1 → 0 over one cycle.
            let triangular = phase < 0.5 ? phase * 2 : 2 - phase * 2
            // Cosine ease so the apex feels smooth instead of a
            // sharp peak. Maps 0..1 → 0..1 via the canonical
            // half-cosine curve.
            let smooth = 0.5 - 0.5 * cos(triangular * .pi)

            indicator(progress: smooth)
        }
    }

    @ViewBuilder
    private func indicator(progress: Double) -> some View {
        // Halo grows in both opacity and radius. Floor sits at "barely
        // visible" so the trough doesn't read as static; ceiling pushes
        // to a dramatic glow so the contrast between trough and peak
        // signals ongoing work. y-offset stays at 0 so the halo pulses
        // concentrically — a downward-offset shadow at peak radius
        // looks like the llama is sinking into a puddle.
        let opacity = 0.05 + 0.75 * progress
        let radius = size * (0.04 + 0.26 * progress)

        // `LlamaLogo` is asked for `shadowOpacity: 0` so its built-in
        // static shadow is suppressed; this view supplies the animated
        // shadow itself. Outer `.shadow(...)` renders from the
        // composed view's alpha channel, which is just the transparent
        // llama PNG — so the halo traces the llama silhouette.
        LlamaLogo(size: size, shadowColor: accent, shadowOpacity: 0)
            .shadow(color: accent.opacity(opacity), radius: radius, x: 0, y: 0)
            // Reserve a slightly larger frame so the peak halo doesn't
            // clip against the surrounding overlay padding.
            .frame(width: size * 1.4, height: size * 1.4)
    }
}

#Preview {
    VStack(spacing: 32) {
        LlamaProgressIndicator(size: 80)
        LlamaProgressIndicator(size: 60, accent: .purple)
        LlamaProgressIndicator(size: 120, accent: .green)
    }
    .padding()
    .background(AppColor.background)
}
