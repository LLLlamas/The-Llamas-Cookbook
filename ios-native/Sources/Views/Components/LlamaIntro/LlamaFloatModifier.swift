import SwiftUI

/// Gentle vertical bob applied to a llama mascot. Same easing /
/// amplitude / autoreverse curve `LlamaCharacter` uses for the
/// intro-tour idle bob, factored out so static llama placements
/// (accent-picker preview, friends-tab empty state) can share the
/// motion without pulling in the rest of the tour-character chrome
/// (halo pulse, wave, mirror flip, step-driven hop).
///
/// Respects Reduce Motion — when on, the offset stays at zero and
/// no animation is registered, so the mascot renders perfectly
/// still rather than snapping between bob endpoints.
struct LlamaFloatModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bobOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(y: bobOffset)
            .onAppear {
                guard !reduceMotion else { return }
                // Short delay lets any concurrent sheet/navigation transition
                // finish its first frames before the repeatForever animation
                // starts competing for the main run loop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                        bobOffset = -4
                    }
                }
            }
    }
}

extension View {
    /// Apply the shared llama idle-bob — gentle 4pt vertical float
    /// on a 1.4s autoreversing easeInOut, matching the intro tour's
    /// `LlamaCharacter`. Reduce-Motion-aware.
    func llamaFloat() -> some View {
        modifier(LlamaFloatModifier())
    }
}
