import SwiftUI

/// One item row. The leading circle AND the central label both toggle the
/// check (so the user needn't hit the small circle); the trailing "?" helper
/// and "!" unavailable flag are separate bounded tap targets so taps don't
/// cross-fire. Checked items dim + strike through.
///
/// Split out of `GroceryListDetailView` — the celebration animation it
/// triggers lives in `CheckOffCelebration.swift`.
struct GroceryItemRow: View {
    let item: GroceryItem
    let accent: Color
    let onToggleChecked: () -> Void
    let onToggleOutOfStock: () -> Void
    let onHelp: () -> Void

    /// Bumped on every unchecked→checked flip — a local tap OR a live
    /// remote sync landing — to run the one-shot stamp/poof/sweep
    /// celebration. Starts at 0 so freshly-rendered rows (list open,
    /// scroll-in, already-checked items) never replay it.
    @State private var celebration = 0

    /// Reduce Motion suppresses the celebration entirely (the check still
    /// flips with its gentle color fade — that's a state change, not motion).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var display: MeasureDisplay { item.display() }

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            // Leading: in-cart check-off. The mark stamps down (lift →
            // sink → spring settle) with a brief green glow, and a poof
            // bursts over it — layered ABOVE the phase animator so the
            // burst isn't scaled by the stamp.
            Button(action: onToggleChecked) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(item.isChecked ? AppColor.success : AppColor.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeInOut(duration: 0.2), value: item.isChecked)
                    .phaseAnimator(CheckStampPhase.allCases, trigger: celebration) { view, phase in
                        view
                            .scaleEffect(phase.scale)
                            .shadow(color: AppColor.success.opacity(phase.glowOpacity), radius: phase.glowRadius)
                    } animation: { phase in
                        phase.animation
                    }
                    .overlay {
                        if celebration > 0 {
                            CheckPoof().id(celebration)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isChecked ? "Uncheck \(item.name)" : "Check off \(item.name)")

            // Center: the whole name + measure column toggles the check too,
            // so the user needn't hit the little circle. The helper buttons
            // stay separate trailing tap targets.
            Button(action: onToggleChecked) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.name.capitalized)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(item.isChecked ? AppColor.textTertiary : AppColor.textPrimary)
                        .strikethrough(item.isChecked, color: AppColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    statusSubline
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.22), value: item.isChecked)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isChecked ? "Uncheck \(item.name)" : "Check off \(item.name)")

            Button(action: onHelp) {
                Image(systemName: item.substitution == nil ? "questionmark.circle" : "questionmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(item.substitution == nil ? AppColor.textTertiary : AppColor.success)
                    .frame(width: 34, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("What is \(item.name)?")

            Button(action: onToggleOutOfStock) {
                Image(systemName: item.outOfStock ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(item.outOfStock ? AppColor.destructive : AppColor.textTertiary)
                    .frame(width: 34, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.outOfStock
                ? "Clear unavailable flag on \(item.name)"
                : "Flag \(item.name) as unavailable")
        }
        // The green highlight that washes across the row, leading →
        // trailing, as the item lands in the cart.
        .overlay {
            if celebration > 0 {
                CheckSweep().id(celebration)
            }
        }
        .onChange(of: item.isChecked) { wasChecked, isChecked in
            guard isChecked, !wasChecked, !reduceMotion else { return }
            celebration += 1
        }
    }

    /// Second line under the name: the chosen swap, an out-of-stock flag, or
    /// the measure — in that priority.
    @ViewBuilder
    private var statusSubline: some View {
        if let swap = item.substitution, !swap.isEmpty {
            Text("Swap: \(swap)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColor.success)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if item.outOfStock {
            Text("Couldn't find it")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColor.destructive)
        } else if !display.measure.isEmpty {
            Text(display.measure)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.textTertiary)
        }
    }
}
