import ActivityKit
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

struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerAttributes.self) { context in
            lockScreen(for: context)
                .activityBackgroundTint(TimerWidgetColor.background)
                .activitySystemActionForegroundColor(TimerWidgetColor.accentDeep)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(TimerWidgetColor.accent)
                        Text(context.state.label.capitalized)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TimerWidgetColor.textPrimary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...context.state.endDate, countsDown: true)
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .monospacedDigit()
                        .foregroundStyle(TimerWidgetColor.accent)
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Text("Step \(context.state.stepNumber)")
                            .font(.system(size: 12, weight: .heavy))
                            .tracking(0.4)
                            .foregroundStyle(TimerWidgetColor.accentDeep)
                        Text("·")
                            .foregroundStyle(TimerWidgetColor.textSecondary)
                        Text(context.attributes.recipeTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TimerWidgetColor.textSecondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(TimerWidgetColor.accent)
            } compactTrailing: {
                Text(timerInterval: Date()...context.state.endDate, countsDown: true)
                    .monospacedDigit()
                    .foregroundStyle(TimerWidgetColor.accent)
                    .frame(maxWidth: 50)
            } minimal: {
                Image(systemName: "timer")
                    .foregroundStyle(TimerWidgetColor.accent)
            }
            .keylineTint(TimerWidgetColor.accent)
        }
    }

    // MARK: - Lock Screen / Notification-Center layout

    private func lockScreen(for context: ActivityViewContext<TimerAttributes>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(TimerWidgetColor.accent.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: "timer")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(TimerWidgetColor.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Step \(context.state.stepNumber) · \(context.state.label.capitalized)")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(TimerWidgetColor.accentDeep)
                Text(context.attributes.recipeTitle)
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(TimerWidgetColor.textPrimary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(timerInterval: Date()...context.state.endDate, countsDown: true)
                .font(.system(size: 28, weight: .bold, design: .serif))
                .monospacedDigit()
                .foregroundStyle(TimerWidgetColor.accent)
                .frame(maxWidth: 110, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
