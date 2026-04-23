import SwiftUI

struct StepQuickAdd: View {
    let nextNumber: Int
    let onAdd: (DraftStep) -> Void

    @State private var text = ""
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

            TextField("Describe step \(nextNumber)…", text: $text)
                .submitLabel(.done)
                .focused($focused)
                .onSubmit { submit() }
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .frame(minHeight: 44)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(AppColor.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
        }
    }

    private func submit() {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else {
            focused = false
            return
        }
        Haptics.impact(.light)
        onAdd(DraftStep(text: trimmed))
        text = ""
        focused = true
    }
}
