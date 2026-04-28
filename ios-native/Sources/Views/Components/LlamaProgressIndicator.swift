import SwiftUI

/// Branded indeterminate-progress indicator: the `LlamaLogo` with its
/// drop-shadow halo continuously filling from bottom to top.
///
/// Replaces a plain `ProgressView` spinner in the cloud-share upload
/// overlay (`RecipeDetailView.cloudShareLoadingOverlay`) — the
/// recognizable logo signals "the app is working" while the rising
/// halo carries the indeterminate-progress affordance, so users don't
/// wonder whether it's frozen during a slow upload.
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
        ZStack {
            // Animating halo: a soft blurred disc larger than the
            // logo (so it reads as the logo's drop shadow rather
            // than a backing disc), masked from the bottom so it
            // appears to "fill" upward as `progress` rises.
            Circle()
                .fill(accent)
                .opacity(0.55)
                .blur(radius: size * 0.18)
                .frame(width: size * 1.25, height: size * 1.25)
                .mask {
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle()
                                .frame(height: geo.size.height * progress)
                        }
                    }
                }

            // The logo body, no static shadow — the animating halo
            // above replaces it. `shadowOpacity: 0` is the contract
            // for "I'm providing my own halo."
            LlamaLogo(size: size, shadowColor: accent, shadowOpacity: 0)
        }
        // The halo extends ~12% past the logo on each side, so reserve
        // a slightly larger frame to keep blur edges from clipping.
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
