import SwiftUI

struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            LlamaMascot(size: 140)
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
        .background(AppColor.background)
    }
}

#Preview {
    EmptyLibraryView()
}
