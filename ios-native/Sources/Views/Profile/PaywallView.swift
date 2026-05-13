import SwiftUI

// MARK: - PaywallView (Phase 1 stub)
//
// Phase 1: "Coming soon" placeholder. The upgrade button in the
// exhausted-state card opens this sheet so the code path compiles
// and the UI is wired, but no actual purchase occurs.
//
// Phase 2 will replace this with:
//  - Hero llama + value prop bullets (30 imports/month, Instacart teaser).
//  - "Subscribe — $2.99/month" button calling `LlamaProStore.purchase`.
//  - Restore Purchases link.
//  - Terms/privacy links.

struct PaywallView: View {
    @Environment(\.dismiss)          private var dismiss
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        NavigationStack {
            VStack(spacing: AppSpacing.lg) {
                Spacer()
                LlamaLogo(size: 96, shadowColor: appearance.accentColor)
                    .llamaFloat()
                Text("Llama Pro")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(appearance.accentColor)
                    .accentTextOutline()
                Text("30 photo imports per month.\nComing soon: Grocery list with Instacart integration.")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.xl)

                Text("$2.99 / month")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)

                // Phase 1: button disabled; purchase not yet wired.
                Button { } label: {
                    Text("Coming soon")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColor.onAccent.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.md)
                        .background(appearance.accentColor.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                }
                .buttonStyle(.plain)
                .disabled(true)
                .padding(.horizontal, AppSpacing.lg)

                Spacer()
            }
            .llamaBackground()
            .navigationBarTitleDisplayMode(.inline)
            .tint(appearance.accentColor)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Done")
                            .foregroundStyle(appearance.accentColor)
                            .accentTextOutline()
                    }
                }
            }
        }
    }
}
