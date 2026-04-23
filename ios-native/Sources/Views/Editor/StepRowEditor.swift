import SwiftUI

struct StepRowEditor: View {
    let index: Int
    @Binding var step: DraftStep
    let onDelete: () -> Void

    @State private var isEditing = false

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
        VStack(spacing: AppSpacing.sm) {
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

                TextField("Step \(index + 1)", text: $step.text, axis: .vertical)
                    .lineLimit(1...6)
                    .submitLabel(.done)
                    .onSubmit { isEditing = false }
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .frame(minHeight: 44)
                    .background(AppColor.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .stroke(AppColor.divider, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
            }
            HStack {
                Spacer()
                Button("Done") { isEditing = false }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .background(AppColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            }
        }
        .padding(AppSpacing.sm)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.accent, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }
}
