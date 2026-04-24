import SwiftUI

struct StepRowEditor: View {
    let index: Int
    @Binding var step: DraftStep
    @Binding var isEditing: Bool
    let onDelete: () -> Void

    var body: some View {
        if isEditing {
            editMode
        } else {
            viewMode
        }
    }

    private var viewMode: some View {
        Button {
            Haptics.selection()
            isEditing = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
                Text("\(index + 1).")
                    .font(AppFont.sectionHeading)
                    .foregroundStyle(AppColor.accent)
                    .monospacedDigit()
                    .frame(minWidth: 28, alignment: .leading)
                Text(step.text)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if step.needsTimer {
                    Image(systemName: "timer")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColor.accent)
                        .padding(.horizontal, AppSpacing.xs)
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
            .padding(.vertical, AppSpacing.sm)
            .padding(.horizontal, AppSpacing.xs)
        }
        .buttonStyle(.plain)
    }

    private var editMode: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Text("\(index + 1)")
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.accent)
                .monospacedDigit()
                .frame(width: 36, height: 44)
                .background(AppColor.background)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(AppColor.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))

            HStack(spacing: AppSpacing.xs) {
                TextField("Step \(index + 1)", text: $step.text)
                    .submitLabel(.done)
                    .onSubmit { isEditing = false }
                    .tint(AppColor.accent)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)

                TimerToggleButton(isOn: $step.needsTimer)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .frame(minHeight: 44)
            .background(AppColor.background)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.accent, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .padding(.vertical, AppSpacing.xs)
    }
}
