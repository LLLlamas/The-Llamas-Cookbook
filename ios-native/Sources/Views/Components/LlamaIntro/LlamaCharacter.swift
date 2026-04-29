import SwiftUI

/// Animated wrapper around `LlamaLogo` for tour overlays. Bobs and
/// halo-pulses in idle, hops on step change, mirrors to face the
/// highlighted field, and waves on the first step.
///
/// Reduce Motion suppresses every motion flourish; the mirror flip
/// still happens since it's a layout cue, not animation.
struct LlamaCharacter: View {
    enum Facing { case left, right }

    let size: CGFloat
    let facing: Facing
    let isWaving: Bool
    /// Bumped on every step change so SwiftUI re-runs the `.id()`-
    /// driven transition, producing the hop-in feel.
    let stepID: Int

    @Environment(AppearanceSettings.self) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var bobOffset: CGFloat = 0
    @State private var haloOpacity: Double = 0.45
    @State private var waveAngle: Double = 0

    var body: some View {
        LlamaLogo(
            size: size,
            shadowColor: appearance.accentColor,
            shadowOpacity: haloOpacity
        )
        .offset(y: bobOffset)
        .rotationEffect(.degrees(waveAngle))
        .scaleEffect(x: facing == .left ? -1 : 1, y: 1)
        .id(stepID)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
        .animation(.spring(response: 0.5, dampingFraction: 0.55), value: stepID)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: facing)
        .onAppear { startIdleAnimations() }
        .task(id: isWaving) { if isWaving { await playWave() } }
    }

    private func startIdleAnimations() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            bobOffset = -4
        }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            haloOpacity = 0.70
        }
    }

    private func playWave() async {
        guard !reduceMotion else { return }
        for _ in 0..<3 {
            withAnimation(.easeInOut(duration: 0.15)) { waveAngle = 6 }
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeInOut(duration: 0.15)) { waveAngle = -6 }
            try? await Task.sleep(for: .milliseconds(150))
        }
        withAnimation(.easeInOut(duration: 0.15)) { waveAngle = 0 }
    }
}
