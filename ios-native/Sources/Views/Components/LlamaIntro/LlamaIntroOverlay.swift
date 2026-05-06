import SwiftUI
import UIKit

/// Coach-mark overlay. Dims the host view, draws a steady accent
/// glow around the current step's tagged field (same drop-shadow
/// silhouette as `LlamaLogo`'s halo), parks a llama + bubble above
/// the field with the bubble's tail pointing down at it, and floats
/// the Back · indicator · Next controls directly below the field.
/// When the target is too close to the top to fit the bubble above,
/// the bubble drops below the target and the controls roll into the
/// cluster's VStack so the whole walkthrough still fits.
///
/// The dim + halo layers are non-hit-testing — touches fall through
/// to the editor fields underneath, so the user types directly into
/// the real draft as the tour progresses. Only the bubble + controls
/// catch taps. There is no Skip button: finishing the walkthrough is
/// the dismissal, and the user has built up a real recipe by then.
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
            let frame: CGRect? = resolveFrame(in: geometry)
            let safeArea = geometry.frame(in: .local)

            ZStack {
                dimLayer(cutout: frame, in: safeArea)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

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

    /// Union the primary target rect with any `extraTargets` so a
    /// single step can highlight two adjacent fields. Targets that
    /// haven't been laid out yet (no anchor in the dictionary) are
    /// skipped — that way a step on a screen where one of the extras
    /// is conditionally absent still spotlights the rest cleanly.
    private func resolveFrame(in geometry: GeometryProxy) -> CGRect? {
        let ids = [currentStep.target].compactMap { $0 } + currentStep.extraTargets
        let rects = ids.compactMap { anchors[$0] }.map { geometry[$0] }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
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
    }

    /// Steady accent halo around the cutout, shaped like
    /// `LlamaLogo`'s drop shadow — soft, no pulse. A near-invisible
    /// fill anchors the drop shadow without tinting the field
    /// underneath; without a fill of any kind, SwiftUI's drop shadow
    /// can render as nothing on a stroked-only shape.
    @ViewBuilder
    private func haloGlow(around frame: CGRect) -> some View {
        let inflated = frame.insetBy(dx: -8, dy: -8)
        RoundedRectangle(cornerRadius: AppRadius.md)
            .fill(Color.white.opacity(0.001))
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
            let plan = computePlan(
                target: frame,
                safeArea: safeArea,
                llamaSize: llamaSize,
                bubbleMaxWidth: bubbleMaxWidth
            )
            ZStack {
                bubbleCluster(plan: plan, llamaSize: llamaSize, bubbleMaxWidth: bubbleMaxWidth)
                if let controlsCenter = plan.separateControlsCenter {
                    controlsBar
                        .frame(maxWidth: bubbleMaxWidth)
                        .position(x: controlsCenter.x, y: controlsCenter.y)
                        .id("controls-\(currentIndex)")
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: currentIndex)
                }
            }
        } else {
            // Target not yet resolved on the first frame — fall back
            // to a centered cluster so the user sees the llama and
            // copy instead of a black void.
            let fallback = LayoutPlan(
                bubbleSide: .right,
                bubbleClusterCenter: CGPoint(x: safeArea.midX, y: safeArea.midY),
                tailEdge: .top,
                tailLeading: 0.5,
                showTail: false,
                separateControlsCenter: nil
            )
            bubbleCluster(plan: fallback, llamaSize: llamaSize, bubbleMaxWidth: bubbleMaxWidth)
        }
    }

    /// HStack of [llama, bubble (+ controls if not separate)] —
    /// position dictated by the layout plan.
    @ViewBuilder
    private func bubbleCluster(plan: LayoutPlan, llamaSize: CGFloat, bubbleMaxWidth: CGFloat) -> some View {
        let bubble = LlamaSpeechBubble(
            headline: currentStep.headline,
            message: currentStep.body,
            tailEdge: plan.tailEdge,
            tailLeading: plan.tailLeading,
            showTail: plan.showTail,
            maxWidth: bubbleMaxWidth
        )

        // When controls live inside the cluster (no room to split
        // them out below the target), order them so the bubble is
        // closest to the target — bubble on top of VStack for tail
        // UP, bubble on bottom for tail DOWN. Without this flip the
        // controls end up between the bubble and the target and
        // visually disconnect the tail from the field.
        let bubbleColumn = bubbleColumnContent(
            bubble: bubble,
            plan: plan,
            bubbleMaxWidth: bubbleMaxWidth
        )

        let llamaCharacter = LlamaCharacter(
            size: llamaSize,
            facing: plan.bubbleSide == .left ? .left : .right,
            isWaving: currentStep.waveOnEnter && currentIndex == 0,
            stepID: currentIndex
        )

        HStack(alignment: .center, spacing: AppSpacing.md) {
            // Bubble side `.left` means the bubble sits on the left
            // of the llama (target was on the left half of the
            // screen); `.right` flips it so the bubble lives on the
            // right of the llama (target on the right half — the
            // Save button is the canonical case).
            if plan.bubbleSide == .left {
                bubbleColumn
                llamaCharacter
            } else {
                llamaCharacter
                bubbleColumn
            }
        }
        .position(x: plan.bubbleClusterCenter.x, y: plan.bubbleClusterCenter.y)
        .id(currentIndex)
        .transition(reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.96))
        )
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.85), value: currentIndex)
    }

    @ViewBuilder
    private func bubbleColumnContent(
        bubble: LlamaSpeechBubble,
        plan: LayoutPlan,
        bubbleMaxWidth: CGFloat
    ) -> some View {
        if plan.separateControlsCenter == nil {
            VStack(alignment: plan.bubbleSide == .left ? .leading : .trailing, spacing: AppSpacing.sm) {
                if plan.tailEdge == .top {
                    bubble
                    controlsBar.frame(maxWidth: bubbleMaxWidth)
                } else {
                    controlsBar.frame(maxWidth: bubbleMaxWidth)
                    bubble
                }
            }
        } else {
            bubble
        }
    }

    // MARK: - Layout plan

    /// Result of the placement algorithm.
    /// - `bubbleSide`: which side of the llama the bubble lives on
    ///   (always the same horizontal half as the target so the tail
    ///   can anchor at the target's midX).
    /// - `bubbleClusterCenter`: position of the bubble + llama HStack.
    /// - `tailEdge`: `.bottom` when the bubble sits above the target
    ///   (tail points down), `.top` when below (tail up).
    /// - `separateControlsCenter`: when non-nil, controls render in
    ///   a standalone position below the target halo — used for the
    ///   common case where the bubble fits above the target so the
    ///   reading order is bubble → field → controls. When nil, the
    ///   controls fold into the bubble's VStack instead (top-of-
    ///   screen targets where the bubble has to live below).
    private struct LayoutPlan {
        enum Side { case left, right }
        var bubbleSide: Side
        var bubbleClusterCenter: CGPoint
        var tailEdge: LlamaSpeechBubble.TailEdge
        var tailLeading: CGFloat
        /// False when the cluster falls back to a centered placement
        /// (target frame not yet resolved). The bubble drops its
        /// tail in that case so the orphan triangle doesn't dangle
        /// into empty space.
        var showTail: Bool
        var separateControlsCenter: CGPoint?
    }

    /// Decide whether the bubble goes above or below the target,
    /// where the controls land, and where everything sits
    /// horizontally.
    private func computePlan(
        target: CGRect,
        safeArea: CGRect,
        llamaSize: CGFloat,
        bubbleMaxWidth: CGFloat
    ) -> LayoutPlan {
        let inflated = target.insetBy(dx: -8, dy: -8)
        let edgeMargin: CGFloat = AppSpacing.lg
        // Tight gap between the bubble's tail tip (or controls top
        // edge) and the halo so the tail reads as "right at" the
        // target rather than floating above it. The halo itself
        // already inflates by 8pt, so 4pt here lands the tail tip
        // 12pt off the target's true edge — close enough to feel
        // attached without literally overlapping the glow.
        let pairSpacing: CGFloat = AppSpacing.xs
        let bubbleHeightEstimate: CGFloat = 170
        // Arrow row (36) + spacing + Exit pill (36) — keeps the split
        // layout from clipping the Exit button below the safe area.
        let controlsHeight: CGFloat = 88
        let clusterHeightWithControls = bubbleHeightEstimate + controlsHeight + AppSpacing.sm

        let roomAbove = inflated.minY - safeArea.minY
        let roomBelow = safeArea.maxY - inflated.maxY

        // Preferred: bubble sits ABOVE the target (tail pointing down
        // at the field) and the controls float below the target —
        // reads top-to-bottom as bubble → field → controls. Falls
        // back to "everything below target" only when the field is
        // too close to the top of the safe area to host the bubble
        // above (step 1 editorHero, step 11 toolbar Save button).
        let canSplit =
            roomAbove >= bubbleHeightEstimate + pairSpacing + edgeMargin
            && roomBelow >= controlsHeight + pairSpacing + edgeMargin

        let bubbleAbove: Bool
        let controlsAreSeparate: Bool
        if canSplit {
            bubbleAbove = true
            controlsAreSeparate = true
        } else {
            bubbleAbove = false
            controlsAreSeparate = false
        }

        // Vertical position of bubble cluster.
        let bubbleClusterY: CGFloat
        if bubbleAbove {
            bubbleClusterY = inflated.minY - pairSpacing - bubbleHeightEstimate / 2
        } else {
            let clusterHeight = controlsAreSeparate ? bubbleHeightEstimate : clusterHeightWithControls
            bubbleClusterY = inflated.maxY + pairSpacing + clusterHeight / 2
        }
        let halfClusterHeightForClamp = controlsAreSeparate
            ? bubbleHeightEstimate / 2
            : clusterHeightWithControls / 2
        let clampedY = max(
            safeArea.minY + halfClusterHeightForClamp + edgeMargin,
            min(safeArea.maxY - halfClusterHeightForClamp - edgeMargin, bubbleClusterY)
        )

        // Horizontal: bubble on the same horizontal half as the
        // target so the tail can anchor at target.midX without
        // overshooting the bubble's clamped 0…1 range.
        let leftHalf = target.midX < safeArea.midX
        let bubbleSide: LayoutPlan.Side = leftHalf ? .left : .right

        let bubbleHalfWidth = bubbleMaxWidth / 2
        let clusterHalfWidth = (llamaSize + pairSpacing + bubbleMaxWidth) / 2

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

        // Separate controls — center horizontally near target.midX,
        // clamped so the row doesn't kiss the screen edges.
        let separateControlsCenter: CGPoint?
        if controlsAreSeparate {
            let controlsY = inflated.maxY + pairSpacing + controlsHeight / 2
            let clampedControlsY = min(
                safeArea.maxY - controlsHeight / 2 - edgeMargin,
                controlsY
            )
            let controlsHalfWidth = bubbleMaxWidth / 2
            let controlsCenterX = max(
                safeArea.minX + controlsHalfWidth + edgeMargin,
                min(safeArea.maxX - controlsHalfWidth - edgeMargin, target.midX)
            )
            separateControlsCenter = CGPoint(x: controlsCenterX, y: clampedControlsY)
        } else {
            separateControlsCenter = nil
        }

        return LayoutPlan(
            bubbleSide: bubbleSide,
            bubbleClusterCenter: CGPoint(x: clampedX, y: clampedY),
            tailEdge: bubbleAbove ? .bottom : .top,
            tailLeading: tailLeading,
            showTail: true,
            separateControlsCenter: separateControlsCenter
        )
    }

    // MARK: - Controls

    /// Back · indicator · Next, with a centered Exit pill below.
    /// Back and Next are filled accent circles with just an arrow
    /// glyph; the last step swaps Next for a "Got it!" pill so the
    /// user reads "I'm done" rather than "next." Exit lets the user
    /// bail out of the walkthrough at any step (the partial recipe
    /// they've typed stays in the editor).
    private var controlsBar: some View {
        VStack(spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                backButton

                stepIndicator
                    .padding(.horizontal, AppSpacing.xs)

                nextButton
            }

            exitButton
        }
    }

    @ViewBuilder
    private var backButton: some View {
        Button {
            Haptics.selection()
            stepBack()
        } label: {
            Image(systemName: "arrow.left")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppColor.onAccent)
                .frame(width: 36, height: 36)
                .background(appearance.accentColor)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isFirstStep ? 0 : 1)
        .disabled(isFirstStep)
        .accessibilityLabel("Previous step")
        .accessibilityHidden(isFirstStep)
    }

    @ViewBuilder
    private var nextButton: some View {
        Button {
            Haptics.selection()
            advance()
        } label: {
            if isLastStep {
                Text("Got it!")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.onAccent)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.xs + 2)
                    .background(appearance.accentColor)
                    .clipShape(Capsule())
                    .frame(minHeight: 36)
            } else {
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppColor.onAccent)
                    .frame(width: 36, height: 36)
                    .background(appearance.accentColor)
                    .clipShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLastStep ? "Finish walkthrough" : "Next step")
    }

    @ViewBuilder
    private var exitButton: some View {
        Button {
            Haptics.selection()
            finish()
        } label: {
            Text("Exit")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColor.onAccent)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.xs + 2)
                .background(appearance.accentColor)
                .clipShape(Capsule())
                .frame(minHeight: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Exit walkthrough")
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
