import SwiftUI
import UIKit

/// Coach-mark overlay. Dims the host view, punches a soft cutout
/// around the current step's tagged field, parks the llama and a
/// speech bubble adjacent to it, and exposes Skip / Next controls.
///
/// The host owns the preference read — anchor preferences from
/// `.tourTarget` modifiers in toolbar items don't reliably propagate
/// into a child overlay's own preference scope, so the host attaches
/// `.overlayPreferenceValue(LlamaTourTargetKey.self) { anchors in
/// LlamaIntroOverlay(anchors: anchors, ...) }` at the outermost
/// level. The overlay receives the dictionary and resolves each
/// step's target rect via its own GeometryProxy.
///
/// `scrollProxy` lets the overlay scroll off-screen targets into
/// view between steps; toolbar / out-of-scroll targets are no-ops
/// (proxy only sees views inside its `ScrollView`).
struct LlamaIntroOverlay: View {
    let steps: [LlamaIntroStep]
    let anchors: [LlamaTourTarget: Anchor<CGRect>]
    var scrollProxy: ScrollViewProxy? = nil
    let onFinish: () -> Void

    @Environment(AppearanceSettings.self) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentIndex = 0
    @State private var haloPulse: CGFloat = 1.0

    private var currentStep: LlamaIntroStep {
        steps[max(0, min(currentIndex, steps.count - 1))]
    }

    private var isLastStep: Bool {
        currentIndex >= steps.count - 1
    }

    var body: some View {
        GeometryReader { geometry in
            let frame: CGRect? = currentStep.target
                .flatMap { anchors[$0] }
                .map { geometry[$0] }
            let safeArea = geometry.frame(in: .local)

            ZStack {
                dimLayer(cutout: frame, in: safeArea)
                    .ignoresSafeArea()

                if let frame {
                    haloRing(around: frame)
                }

                placement(frame: frame, safeArea: safeArea)

                controlsBar
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .onAppear {
            // Anchor preferences need one layout pass before they're
            // populated. Defer the first scroll-and-announce a beat
            // so the first step's frame is non-nil when we resolve.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                handleStepChange(initial: true)
                if !reduceMotion { startHaloPulse() }
            }
        }
        .onChange(of: currentIndex) { _, _ in
            handleStepChange(initial: false)
        }
    }

    // MARK: - Dim + halo

    @ViewBuilder
    private func dimLayer(cutout: CGRect?, in bounds: CGRect) -> some View {
        Canvas { context, size in
            // Even-odd fill rule subtracts the cutout from the dim
            // rectangle, giving a soft spotlight without compositing
            // tricks. Inflated 8pt so the field has breathing room.
            var path = Path()
            path.addRect(CGRect(origin: .zero, size: size))
            if let cutout {
                let inflated = cutout.insetBy(dx: -8, dy: -8)
                path.addRoundedRect(
                    in: inflated,
                    cornerSize: CGSize(width: AppRadius.md, height: AppRadius.md)
                )
            }
            context.fill(path, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
        }
        .frame(width: bounds.width, height: bounds.height)
        .contentShape(Rectangle())
        .onTapGesture { /* swallow taps so the host doesn't react beneath the dim */ }
    }

    @ViewBuilder
    private func haloRing(around frame: CGRect) -> some View {
        let inflated = frame.insetBy(dx: -8, dy: -8)
        RoundedRectangle(cornerRadius: AppRadius.md)
            .stroke(appearance.accentColor.opacity(0.85), lineWidth: 2)
            .frame(width: inflated.width, height: inflated.height)
            .scaleEffect(haloPulse)
            .position(x: inflated.midX, y: inflated.midY)
            .allowsHitTesting(false)
    }

    private func startHaloPulse() {
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            haloPulse = 1.04
        }
    }

    // MARK: - Bubble + llama placement

    @ViewBuilder
    private func placement(frame: CGRect?, safeArea: CGRect) -> some View {
        let llamaSize: CGFloat = 84
        let bubbleMaxWidth: CGFloat = min(280, safeArea.width - 32)

        if let frame {
            let layout = bubbleLayout(
                target: frame,
                safeArea: safeArea,
                llamaSize: llamaSize,
                bubbleMaxWidth: bubbleMaxWidth
            )

            ZStack(alignment: .topLeading) {
                LlamaCharacter(
                    size: llamaSize,
                    facing: layout.llamaFacing,
                    isWaving: currentStep.waveOnEnter && currentIndex == 0,
                    stepID: currentIndex
                )
                .position(x: layout.llamaCenter.x, y: layout.llamaCenter.y)

                LlamaSpeechBubble(
                    headline: currentStep.headline,
                    body: currentStep.body,
                    tailEdge: layout.tailEdge,
                    tailLeading: layout.tailLeading,
                    maxWidth: bubbleMaxWidth
                )
                .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
                .position(x: layout.bubbleCenter.x, y: layout.bubbleCenter.y)
                .id(currentIndex)
                .transition(reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.96))
                )
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.85), value: currentIndex)
        } else {
            // Target not yet resolved — fall back to a centered
            // bubble + llama so the user sees something instead of
            // a black void on the first frame.
            VStack(spacing: AppSpacing.md) {
                LlamaCharacter(
                    size: llamaSize,
                    facing: .right,
                    isWaving: currentStep.waveOnEnter && currentIndex == 0,
                    stepID: currentIndex
                )
                LlamaSpeechBubble(
                    headline: currentStep.headline,
                    body: currentStep.body,
                    tailEdge: .top,
                    tailLeading: 0.5,
                    maxWidth: bubbleMaxWidth
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Result of the placement algorithm: where to draw the llama,
    /// where to draw the bubble, which side the bubble's tail sits
    /// on, and how far along that edge the tail anchors.
    private struct BubbleLayout {
        var llamaCenter: CGPoint
        var bubbleCenter: CGPoint
        var llamaFacing: LlamaCharacter.Facing
        var tailEdge: LlamaSpeechBubble.TailEdge
        var tailLeading: CGFloat
    }

    /// Pick a quadrant for the llama + bubble pair given the target's
    /// frame. Below the target if it sits in the top half of the
    /// safe area, above if bottom; left of center → llama leads on
    /// the left, right of center → llama trails on the right.
    /// Long fields (>60% of safe-area height) pin to the bottom inset.
    private func bubbleLayout(
        target: CGRect,
        safeArea: CGRect,
        llamaSize: CGFloat,
        bubbleMaxWidth: CGFloat
    ) -> BubbleLayout {
        let inflated = target.insetBy(dx: -8, dy: -8)
        let bubbleHeight: CGFloat = 130
        let pairSpacing: CGFloat = AppSpacing.md
        let edgeMargin: CGFloat = AppSpacing.lg

        let oversized = inflated.height > safeArea.height * 0.6
        let belowTarget: Bool

        if oversized {
            // Pin to bottom inset — bubble sits between the target's
            // bottom edge and the controls bar.
            belowTarget = false
        } else {
            belowTarget = target.midY < safeArea.midY
        }

        let bubbleCenterY: CGFloat
        if belowTarget {
            bubbleCenterY = inflated.maxY + pairSpacing + bubbleHeight / 2
        } else {
            bubbleCenterY = inflated.minY - pairSpacing - bubbleHeight / 2
        }

        // Clamp bubble vertically inside the safe area. The controls
        // bar reserves the bottom ~80pt; halo lives above the cutout.
        let clampedY = max(
            safeArea.minY + bubbleHeight / 2 + edgeMargin,
            min(safeArea.maxY - bubbleHeight / 2 - 88, bubbleCenterY)
        )

        // Llama sits adjacent to the bubble on the side closer to
        // the screen edge — face the bubble so the bubble reads as
        // "delivered" by the llama.
        let leftHalf = target.midX < safeArea.midX
        let llamaCenterX: CGFloat
        let bubbleCenterX: CGFloat
        let facing: LlamaCharacter.Facing
        let bubbleHalfWidth = bubbleMaxWidth / 2

        if leftHalf {
            llamaCenterX = max(safeArea.minX + llamaSize / 2 + edgeMargin,
                               target.midX - llamaSize / 2 - bubbleHalfWidth)
            bubbleCenterX = min(safeArea.maxX - bubbleHalfWidth - edgeMargin,
                                llamaCenterX + llamaSize / 2 + pairSpacing + bubbleHalfWidth)
            facing = .right
        } else {
            llamaCenterX = min(safeArea.maxX - llamaSize / 2 - edgeMargin,
                               target.midX + llamaSize / 2 + bubbleHalfWidth)
            bubbleCenterX = max(safeArea.minX + bubbleHalfWidth + edgeMargin,
                                llamaCenterX - llamaSize / 2 - pairSpacing - bubbleHalfWidth)
            facing = .left
        }

        // Tail leading is the target midX projected into the
        // bubble's local 0…1 coordinate space.
        let bubbleMinX = bubbleCenterX - bubbleHalfWidth
        let raw = (target.midX - bubbleMinX) / bubbleMaxWidth
        let tailLeading = max(0.05, min(0.95, raw))

        return BubbleLayout(
            llamaCenter: CGPoint(x: llamaCenterX, y: clampedY),
            bubbleCenter: CGPoint(x: bubbleCenterX, y: clampedY),
            llamaFacing: facing,
            tailEdge: belowTarget ? .top : .bottom,
            tailLeading: tailLeading
        )
    }

    // MARK: - Controls

    private var controlsBar: some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            Button {
                Haptics.selection()
                finish()
            } label: {
                Text("Skip")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip walkthrough")

            Spacer()

            stepDots

            Spacer()

            Button {
                Haptics.selection()
                advance()
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Text(isLastStep ? "Got it!" : "Next")
                        .font(.system(size: 15, weight: .semibold))
                    if !isLastStep {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                }
                .foregroundStyle(AppColor.onAccent)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.sm + 2)
                .background(appearance.accentColor)
                .clipShape(Capsule())
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isLastStep ? "Finish walkthrough" : "Next step")
        }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<steps.count, id: \.self) { idx in
                Circle()
                    .fill(idx <= currentIndex ? appearance.accentColor : AppColor.divider)
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Step transitions

    private func handleStepChange(initial: Bool) {
        // Drop any focused responder on each transition so the
        // keyboard never blocks the highlighted field. Without this,
        // the paste-editor step in the text-import tour would surface
        // the keyboard halfway up the screen.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )

        if let target = currentStep.target, let scrollProxy {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.85)) {
                scrollProxy.scrollTo(target, anchor: .center)
            }
        }

        // Voice the new step content so VoiceOver users hear the
        // change without exploring the layout. `.screenChanged`
        // moves focus to the announcement; iOS reads it once.
        let combined = "\(currentStep.headline). \(currentStep.body)"
        if !initial {
            UIAccessibility.post(notification: .announcement, argument: combined)
        } else {
            UIAccessibility.post(notification: .screenChanged, argument: combined)
        }
    }

    private func advance() {
        if isLastStep {
            finish()
        } else {
            currentIndex += 1
        }
    }

    private func finish() {
        onFinish()
    }
}
