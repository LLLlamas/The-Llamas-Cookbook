import SwiftUI

struct ImportHelpView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            mascotHeader

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                helpRow(1, "Paste directly from your **Notes** app.")
                helpRow(2, "First line = the **recipe name**.")
                helpRow(3, "Type **\"Ingredients\"** above your first ingredient.")
                helpRow(4, "Type **\"Steps\"** above your first step.")
            }
            .padding(.horizontal, AppSpacing.sm)

            Text("That's it — I'll handle the rest.")
                .font(.system(size: 13))
                .italic()
                .foregroundStyle(AppColor.textSecondary)

            Button {
                Haptics.selection()
                onDismiss()
            } label: {
                Text("Got it")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(AppColor.accent)
                    .clipShape(Capsule())
            }

            Spacer(minLength: 0)
        }
        .padding(AppSpacing.lg)
        .padding(.top, AppSpacing.md)
        .frame(maxWidth: .infinity)
        .background(AppColor.background)
    }

    private var mascotHeader: some View {
        VStack(spacing: AppSpacing.sm) {
            LlamaMascot(size: 72)
            VStack(spacing: 2) {
                Text("Hi there!")
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.accentDeep)
                Text("Here's how I parse your notes")
                    .font(.system(size: 13, weight: .medium))
                    .tracking(0.3)
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
    }

    private func helpRow(_ number: Int, _ markdown: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm + 2) {
            ZStack {
                Circle()
                    .fill(AppColor.accentSoft)
                    .frame(width: 26, height: 26)
                Text("\(number)")
                    .font(.system(size: 13, weight: .heavy, design: .serif))
                    .foregroundStyle(AppColor.accentDeep)
            }
            Text(LocalizedStringKey(markdown))
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .tint(AppColor.accentDeep)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    ImportHelpView(onDismiss: {})
}
