import SwiftUI

struct StepQuickAdd: View {
    let nextNumber: Int
    let onAdd: (DraftStep) -> Void

    @State private var text = ""
    @State private var needsTimer = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Text("\(nextNumber)")
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.accent)
                .monospacedDigit()
                .frame(width: 36, height: 44)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(AppColor.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))

            HStack(spacing: AppSpacing.xs) {
                TextField("Describe step \(nextNumber)…", text: $text)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit { submit() }
                    .tint(AppColor.accent)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)

                TimerToggleButton(isOn: $needsTimer)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .frame(minHeight: 44)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
    }

    private func submit() {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else {
            focused = false
            return
        }
        Haptics.impact(.light)
        onAdd(DraftStep(text: trimmed, needsTimer: needsTimer))
        text = ""
        needsTimer = false
        focused = true
    }
}

struct TimerToggleButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            Haptics.selection()
            isOn.toggle()
        } label: {
            Image(systemName: "timer")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isOn ? AppColor.onAccent : AppColor.accent)
                .frame(width: 36, height: 36)
                .background(isOn ? AppColor.accent : AppColor.background)
                .overlay(
                    Circle().stroke(AppColor.accent, lineWidth: isOn ? 0 : 1.5)
                )
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Timer enabled for this step" : "Enable timer for this step")
    }
}
