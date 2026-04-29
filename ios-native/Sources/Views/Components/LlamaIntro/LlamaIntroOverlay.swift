import SwiftUI
import UIKit

/// Coach-mark overlay. Dims the host view, draws a steady accent
/// glow around the current step's tagged field (same drop-shadow
/// silhouette as `LlamaLogo`'s halo), and parks a llama + bubble +
/// controls cluster directly below or above the field.
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

    private var currentStep: LlamaIntroStep {
        steps[max(0, min(currentIndex, steps.count - 1))]
    }

    private var isLastStep: Bool {
        currentIndex >= steps.count - 1
    }

    private var isFirstStep: Bool {
        currentIndex <= 0
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
                    haloGlow(around: frame)
                }

                cluster(frame: frame, safeArea: safeArea)
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

    /// Steady accent halo around the cutout, shaped like
    /// `LlamaLogo`'s drop shadow — soft, no pulse. The faint accent
    /// fill anchors the shadow; without a fill of any kind, SwiftUI's
    /// drop shadow can render as nothing on a stroked-only shape.
    @ViewBuilder
    private func haloGlow(around frame: CGRect) -> some View {
        let inflated = frame.insetBy(dx: -8, dy: -8)
        RoundedRectangle(cornerRadius: AppRadius.md)
            .fill(appearance.accentColor.opacity(0.06))
            .frame(width: inflated.width, height: inflated.height)
            .shadow(color: appearance.accentColor.opacity(0.55), radius: 14, x: 0, y: 5)
            .shadow(color: appearance.accentColor.opacity(0.35), radius: 22, x: 0, y: 0)
            .position(x: inflated.midX, y: inflated.midY)
            .allowsHitTesting(false)
    }

    // MARK: - Cluster (llama + bubble + controls)

    @ViewBuilder
    private func cluster(frame: CGRect?, safeArea: CGRect) -> some View {
        let llamaSize: CGFloat = 84
        // Cluster is bubble + llama side-by-side. Bubble has to leave
        // room for the llama AND respect a small horizontal margin
        // off both edges so the cluster doesn't kiss the screen edge.
        let bubbleMaxWidth: CGFloat = max(
            160,
            min(240, safeArea.width - 32 - llamaSize - AppSpacing.md)
        )

        if let frame {
            let layout = clusterLayout(
                target: frame,
                safeArea: safeArea,
                llamaSize: llamaSize,
                bubbleMaxWidth: bubbleMaxWidth
            )
            clusterBody(
                layout: layout,
                llamaSize: llamaSize,
                bubbleMaxWidth: bubbleMaxWidth
            )
        } else {
            // Target not yet resolved on the first frame — fall back
            // to a centered cluster so the user sees the llama and
            // copy instead of a black void.
            let fallback = ClusterLayout(
                bubbleSide: .right,
                center: CGPoint(x: safeArea.midX, y: safeArea.midY),
                tailEdge: .top,
                tailLeading: 0.5,
                showTail: false
            )
            clusterBody(
                layout: fallback,
                llamaSize: llamaSize,
                bubbleMaxWidth: bubbleMaxWidth
            )
        }
    }

    @ViewBuilder
    private func clusterBody(
        layout: ClusterLayout,
        llamaSize: CGFloat,
        bubbleMaxWidth: CGFloat
    ) -> some View {
        let bubbleAndControls = VStack(alignment: layout.bubbleSide == .left ? .leading : .trailing, spacing: AppSpacing.sm) {
            LlamaSpeechBubble(
                headline: currentStep.headline,
                message: currentStep.body,
                tailEdge: layout.tailEdge,
                tailLeading: layout.tailLeading,
                showTail: layout.showTail,
                maxWidth: bubbleMaxWidth
            )
            controlsBar
                .frame(maxWidth: bubbleMaxWidth)
        }

        let llamaCharacter = LlamaCharacter(
            size: llamaSize,
            facing: layout.bubbleSide == .left ? .left : .right,
            isWaving: currentStep.waveOnEnter && currentIndex == 0,
            stepID: currentIndex
        )

        HStack(alignment: .center, spacing: AppSpacing.md) {
            // Bubble side `.left` means the bubble sits on the left
            // of the llama (target was on the left half of the
            // screen); `.right` flips it so the bubble lives on the
            // right of the llama (target on the right half — the
            // Save button is the canonical case).
            if layout.bubbleSide == .left {
                bubbleAndControls
                llamaCharacter
            } else {
                llamaCharacter
                bubbleAndControls
            }
        }
        .position(x: layout.center.x, y: layout.center.y)
        .id(currentIndex)
        .transition(reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.96))
        )
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.85), value: currentIndex)
    }

    /// Result of the placement algorithm. `bubbleSide` indicates
    /// which side of the llama the bubble sits on; the bubble is
    /// always on the SAME side as the target (so its tail can point
    /// at the target without overshooting the bubble's edges) and
    /// the llama stands on the opposite side.
    private struct ClusterLayout {
        enum Side { case left, right }
        var bubbleSide: Side
        var center: CGPoint
        var tailEdge: LlamaSpeechBubble.TailEdge
        var tailLeading: CGFloat
        /// False when the cluster falls back to a centered placement
        /// (target frame not yet resolved). The bubble drops its
        /// tail in that case so the orphan triangle doesn't dangle
        /// into empty space.
        var showTail: Bool
    }

    /// Compute cluster center + tail orientation. Cluster sits
    /// below the target when the target is in the top half of the
    /// safe area (tail points up at it), above when the target is
    /// in the bottom half (tail points down). Bubble side mirrors
    /// the target's horizontal half so the tail can anchor at the
    /// target's midX without exceeding the bubble's clamped 0…1
    /// range.
    private func clusterLayout(
        target: CGRect,
        safeArea: CGRect,
        llamaSize: CGFloat,
        bubbleMaxWidth: CGFloat
    ) -> ClusterLayout {
        let inflated = target.insetBy(dx: -8, dy: -8)
        let edgeMargin: CGFloat = AppSpacing.lg
        let pairSpacing: CGFloat = AppSpacing.md
        // Bubble height + controls + spacing — rough estimate just
        // for vertical clamping; the actual cluster sizes itself.
        let bubbleHeightEstimate: CGFloat = 160
        let controlsHeight: CGFloat = 44 + AppSpacing.sm
        let clusterHeight = bubbleHeightEstimate + controlsHeight

        let oversized = inflated.height > safeArea.height * 0.5
        let belowTarget: Bool
        if oversized {
            // Tall fields can't fit a cluster + cluster height in
            // the available margin. Push to whichever side has
            // more room.
            let aboveSpace = inflated.minY - safeArea.minY
            let belowSpace = safeArea.maxY - inflated.maxY
            belowTarget = belowSpace >= aboveSpace
        } else {
            belowTarget = target.midY < safeArea.midY
        }

        let centerY: CGFloat
        if belowTarget {
            centerY = inflated.maxY + pairSpacing + clusterHeight / 2
        } else {
            centerY = inflated.minY - pairSpacing - clusterHeight / 2
        }
        let clampedY = max(
            safeArea.minY + clusterHeight / 2 + edgeMargin,
            min(safeArea.maxY - clusterHeight / 2 - edgeMargin, centerY)
        )

        // Horizontal: bubble on the same horizontal half as the
        // target. Target on the LEFT → bubble on the LEFT side of
        // the cluster (tail anchored to bubble's left half). Target
        // on the RIGHT (Save is the canonical case) → bubble on the
        // RIGHT so the tail points up at the toolbar Save pill
        // without overshooting the bubble's clamped tail range.
        let leftHalf = target.midX < safeArea.midX
        let bubbleSide: ClusterLayout.Side = leftHalf ? .left : .right

        let bubbleHalfWidth = bubbleMaxWidth / 2
        let clusterHalfWidth = (llamaSize + pairSpacing + bubbleMaxWidth) / 2

        // For target.midX to land at the bubble's center:
        // - bubbleSide == .left: bubble.midX = clusterCenterX -
        //   clusterHalfWidth + bubbleHalfWidth → solve for
        //   clusterCenterX.
        // - bubbleSide == .right: bubble.midX = clusterCenterX +
        //   clusterHalfWidth - bubbleHalfWidth → solve.
        let desiredCenterX: CGFloat
        switch bubbleSide {
        case .left:
            desiredCenterX = target.midX + (clusterHalfWidth - bubbleHalfWidth)
        case .right:
            desiredCenterX = target.midX - (clusterHalfWidth - bubbleHalfWidth)
        }
        let clampedX = max(
            safeArea.minX + clusterHalfWidth + edgeMargin,
            min(safeArea.maxX - clusterHalfWidth - edgeMargin, desiredCenterX)
        )

        // Tail leading is target.midX projected back into the
        // bubble's local 0…1 coords given the clamped cluster X.
        let bubbleCenterX: CGFloat
        switch bubbleSide {
        case .left:
            bubbleCenterX = clampedX - clusterHalfWidth + bubbleHalfWidth
        case .right:
            bubbleCenterX = clampedX + clusterHalfWidth - bubbleHalfWidth
        }
        let bubbleMinX = bubbleCenterX - bubbleHalfWidth
        let raw = (target.midX - bubbleMinX) / bubbleMaxWidth
        let tailLeading = max(0.05, min(0.95, raw))

        return ClusterLayout(
            bubbleSide: bubbleSide,
            center: CGPoint(x: clampedX, y: clampedY),
            tailEdge: belowTarget ? .top : .bottom,
            tailLeading: tailLeading,
            showTail: true
        )
    }

    // MARK: - Controls

    /// Skip · Back · indicator · Next, sitting directly below the
    /// bubble (inside the cluster) so the controls travel with the
    /// instructional text. Back is invisible-but-laid-out on the
    /// first step; the dot rail collapses to "X / N" text when the
    /// tour has more than 7 steps so the row stays readable.
    private var controlsBar: some View {
        HStack(spacing: AppSpacing.xs) {
            Button {
                Haptics.selection()
                finish()
            } label: {
                Text("Skip")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip walkthrough")

            backButton

            Spacer(minLength: AppSpacing.xs)

            stepIndicator

            Spacer(minLength: AppSpacing.xs)

            Button {
                Haptics.selection()
                advance()
            } label: {
                HStack(spacing: 4) {
                    Text(isLastStep ? "Got it!" : "Next")
                        .font(.system(size: 14, weight: .semibold))
                    if !isLastStep {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                }
                .foregroundStyle(AppColor.onAccent)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.xs + 2)
                .background(appearance.accentColor)
                .clipShape(Capsule())
                .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isLastStep ? "Finish walkthrough" : "Next step")
        }
    }

    @ViewBuilder
    private var backButton: some View {
        Button {
            Haptics.selection()
            stepBack()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 11, weight: .bold))
                Text("Back")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(appearance.accentColor)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .frame(minHeight: 36)
        }
        .buttonStyle(.plain)
        .opacity(isFirstStep ? 0 : 1)
        .disabled(isFirstStep)
        .accessibilityLabel("Previous step")
        .accessibilityHidden(isFirstStep)
    }

    @ViewBuilder
    private var stepIndicator: some View {
        if steps.count <= 7 {
            HStack(spacing: 5) {
                ForEach(0..<steps.count, id: \.self) { idx in
                    Circle()
                        .fill(idx <= currentIndex ? appearance.accentColor : AppColor.divider)
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
        } else {
            Text("\(currentIndex + 1) / \(steps.count)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(AppColor.textSecondary)
                .accessibilityLabel("Step \(currentIndex + 1) of \(steps.count)")
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

    private func stepBack() {
        guard !isFirstStep else { return }
        currentIndex -= 1
    }

    private func finish() {
        onFinish()
    }
}
