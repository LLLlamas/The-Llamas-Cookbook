import SwiftUI

struct StepRowEditor: View {
    let index: Int
    @Binding var step: DraftStep
    @Binding var isEditing: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm + 2) {
            Text("\(index + 1).")
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.accent)
                .monospacedDigit()
                .frame(minWidth: 28, alignment: .leading)

            if isEditing {
                editContent
            } else {
                viewContent
            }

            Button {
                Haptics.impact(.light)
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(AppSpacing.xs)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, AppSpacing.sm - 1)
        .padding(.horizontal, AppSpacing.sm)
        .background(isEditing ? AppColor.accentSoft.opacity(0.55) : AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(
                    isEditing ? AppColor.accent : AppColor.divider,
                    lineWidth: isEditing ? 1.5 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing {
                Haptics.selection()
                isEditing = true
            }
        }
    }

    @ViewBuilder
    private var viewContent: some View {
        Text(step.text.isEmpty ? "Tap to edit" : step.text)
            .font(AppFont.body)
            .foregroundStyle(step.text.isEmpty ? AppColor.textTertiary : AppColor.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
        if step.needsTimer {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColor.accent.opacity(0.8))
        }
    }

    @ViewBuilder
    private var editContent: some View {
        TextField("Step \(index + 1)", text: $step.text)
            .font(AppFont.body)
            .foregroundStyle(AppColor.textPrimary)
            .submitLabel(.done)
            .onSubmit { isEditing = false }
            .tint(AppColor.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
        TimerToggleButton(isOn: $step.needsTimer)
    }
}
