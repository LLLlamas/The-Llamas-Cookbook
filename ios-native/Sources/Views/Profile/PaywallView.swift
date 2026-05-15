import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss)              private var dismiss
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(LlamaProStore.self)      private var proStore
    @Environment(QuotaService.self)       private var quotaService

    @State private var isLoadingProduct = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.xl) {
                    Spacer().frame(height: AppSpacing.lg)

                    LlamaLogo(size: 96, shadowColor: appearance.accentColor)
                        .llamaFloat()

                    VStack(spacing: AppSpacing.xs) {
                        Text("Llama Pro")
                            .font(.system(size: 28, weight: .bold, design: .serif))
                            .foregroundStyle(appearance.accentColor)
                            .accentTextOutline()

                        priceLabel
                    }

                    featureList

                    subscribeButton

                    if let error = proStore.purchaseError {
                        Text(error)
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, AppSpacing.xl)
                    }

                    Button {
                        Task { await proStore.restore() }
                    } label: {
                        Text("Restore Purchases")
                            .font(AppFont.caption)
                            .foregroundStyle(appearance.accentColor)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .disabled(proStore.isPurchasing)

                    legalText

                    Spacer().frame(height: AppSpacing.xl)
                }
                .padding(.horizontal, AppSpacing.lg)
            }
            .llamaBackground()
            .navigationBarTitleDisplayMode(.inline)
            .tint(appearance.accentColor)
            .task {
                guard proStore.product == nil else { return }
                isLoadingProduct = true
                await proStore.loadProduct()
                isLoadingProduct = false
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Done")
                            .foregroundStyle(appearance.accentColor)
                            .accentTextOutline()
                    }
                }
            }
            .onChange(of: proStore.isPro) { _, isPro in
                if isPro {
                    // Refresh quota so the pill reflects Pro limits immediately
                    // when the user returns to the import sheet.
                    Task { await quotaService.refresh(force: true) }
                    dismiss()
                }
            }
        }
    }

    // MARK: - Subviews

    private var priceLabel: some View {
        Group {
            if let product = proStore.product {
                Text(product.displayPrice + " / month")
            } else {
                Text("$2.99 / month")
            }
        }
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(AppColor.textPrimary)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            PaywallFeatureRow(icon: "photo.stack",
                             text: "30 photo imports per month")
            PaywallFeatureRow(icon: "cart",
                             text: "Grocery list with Instacart integration (coming soon)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.sm)
    }

    private var subscribeButton: some View {
        Button {
            Task { await proStore.purchase() }
        } label: {
            ZStack {
                if proStore.isPurchasing || isLoadingProduct {
                    ProgressView()
                        .tint(AppColor.onAccent)
                } else {
                    Text("Subscribe")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColor.onAccent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.md)
            .background(appearance.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .buttonStyle(.plain)
        .disabled(proStore.isPurchasing || isLoadingProduct)
    }

    private var legalText: some View {
        Text("Subscription automatically renews unless cancelled at least 24 hours before the end of the current period. Manage anytime in Settings → Apple Account → Subscriptions.")
            .font(.system(size: 11))
            .foregroundStyle(AppColor.textSecondary.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.horizontal, AppSpacing.sm)
    }
}

// MARK: - Feature Row

private struct PaywallFeatureRow: View {
    let icon: String
    let text: String

    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: icon)
                .foregroundStyle(appearance.accentColor)
                .frame(width: 22, alignment: .center)
            Text(text)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
        }
    }
}
