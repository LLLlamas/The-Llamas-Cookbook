import SwiftUI

struct EmptyLibraryView: View {
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            LlamaLogoOrCrown(size: 140, accent: appearance.accentColor)
            Text("No recipes yet")
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.textPrimary)
            Text("Tap + to add your first recipe.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyLibraryView()
        .environment(AppearanceSettings())
}
