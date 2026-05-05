import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

/// Terracotta accent shared with the main app's `AppColor.accent`.
/// Duplicated here (rather than imported) so the widget extension target
/// stays self-contained and doesn't pull in the app's Theme module.
private enum TimerWidgetColor {
    static let accent = Color(red: 0.788, green: 0.486, blue: 0.365)        // #C97C5D
    static let accentDeep = Color(red: 0.624, green: 0.353, blue: 0.247)    // #9F5A3F
    static let background = Color(red: 0.953, green: 0.918, blue: 0.859)    // cook-mode cream
    static let surface = Color(red: 1.000, green: 0.992, blue: 0.972)       // #FFFDF8
    static let cream = Color(red: 1, green: 0.992, blue: 0.972)             // on-accent text
    static let textPrimary = Color(red: 0.169, green: 0.137, blue: 0.125)   // #2B2320
    static let textSecondary = Color(red: 0.478, green: 0.435, blue: 0.400) // #7A6F66
}

/// AlarmKit-backed cooking timer Live Activity. AlarmKit owns the
/// alarm lifecycle (schedule / fire / cancel) — this widget just
/// renders the countdown + alert presentations using the metadata
/// the main app attached when scheduling.
///
/// Uses `ActivityConfiguration(for: AlarmAttributes<TimerAlarmMetadata>.self)`
/// — the same ActivityKit plumbing as before, but the attribute type
/// is AlarmKit's wrapper around our metadata. AlarmKit's `AlarmPresentationState`
/// drives the count-down vs. alert-fired layout via `context.state.mode`.
struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<TimerAlarmMetadata>.self) { context in
            lockScreen(for: context)
                .activityBackgroundTint(TimerWidgetColor.background)
                .activitySystemActionForegroundColor(TimerWidgetColor.accentDeep)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        profileLlamaMark(size: 22)
                        Text((context.attributes.metadata?.label ?? "timer").capitalized)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TimerWidgetColor.textPrimary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdownText(for: context, font: .system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(TimerWidgetColor.accent)
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Text("Step \(context.attributes.metadata?.stepNumber ?? 0)")
                            .font(.system(size: 12, weight: .heavy))
                            .tracking(0.4)
                            .foregroundStyle(TimerWidgetColor.accentDeep)
                        Text("·")
                            .foregroundStyle(TimerWidgetColor.textSecondary)
                        Text(context.attributes.metadata?.recipeTitle ?? "")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TimerWidgetColor.textSecondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                profileLlamaMark(size: 18)
            } compactTrailing: {
                countdownText(for: context, font: .system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(TimerWidgetColor.accent)
                    .frame(maxWidth: 50)
            } minimal: {
                profileLlamaMark(size: 18)
            }
            .keylineTint(TimerWidgetColor.accent)
        }
    }

    // MARK: - Lock Screen / Notification-Center layout

    private func lockScreen(for context: ActivityViewContext<AlarmAttributes<TimerAlarmMetadata>>) -> some View {
        ZStack(alignment: .trailing) {
            // Explicit cream fill — ensures the background is warm on the
            // lock screen alarm state where activityBackgroundTint alone
            // is not sufficient to override the system dark background.
            TimerWidgetColor.background

            // Large llama watermark: template rendering eliminates any
            // background-pixel color mismatch that would show as a gray
            // band against the cream. Bleeds off the trailing edge for a
            // natural crop. Height matched to the view's content height
            // so it fills without distorting.
            Image("LlamaLogo")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(TimerWidgetColor.accent.opacity(0.16))
                .frame(height: 86)
                .padding(.trailing, -20)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // Foreground content row
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(TimerWidgetColor.accent.opacity(0.18))
                        .frame(width: 48, height: 48)
                    profileLlamaMark(size: 38)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Step \(context.attributes.metadata?.stepNumber ?? 0) · \((context.attributes.metadata?.label ?? "timer").capitalized)")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(TimerWidgetColor.accentDeep)
                    Text(context.attributes.metadata?.recipeTitle ?? "")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(TimerWidgetColor.textPrimary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                countdownText(for: context, font: .system(size: 28, weight: .bold, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(TimerWidgetColor.accent)
                    .frame(maxWidth: 110, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .widgetURL(context.attributes.metadata.flatMap { URL(string: "llamascookbook://cook/\($0.recipeID.uuidString)") })
    }

    /// Renders a live countdown or a static "0:00" after the alarm fires.
    /// Uses `endDate` from our own metadata rather than any
    /// `AlarmPresentationState` property so this stays stable across
    /// AlarmKit beta API changes.
    @ViewBuilder
    private func countdownText(
        for context: ActivityViewContext<AlarmAttributes<TimerAlarmMetadata>>,
        font: Font
    ) -> some View {
        if let endDate = context.attributes.metadata?.endDate, endDate > Date() {
            Text(timerInterval: Date()...endDate, countsDown: true)
                .font(font)
                .monospacedDigit()
        } else {
            Text("0:00")
                .font(font)
                .monospacedDigit()
        }
    }

    /// Brand llama, sized for Live Activity slots. Asset is bundled into
    /// the widget extension (the main app's `Assets.xcassets` isn't on
    /// this target's source paths) and renders in original colors —
    /// `template-rendering-intent: original` preserves the baked-in
    /// llama palette over a `foregroundStyle` tint, matching the in-app
    /// `LlamaLogo` view.
    private func llamaMark(size: CGFloat) -> some View {
        Image("LlamaLogo")
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// Profile-style llama head, used as the lock-screen activity's
    /// avatar icon — the head-on framing reads cleaner than the full
    /// body at small sizes. Bundled into the widget extension's
    /// asset catalog (the main app's catalog isn't on this target's
    /// source paths) and rendered with original colors.
    private func profileLlamaMark(size: CGFloat) -> some View {
        Image("Profile_Llama_Icon")
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
