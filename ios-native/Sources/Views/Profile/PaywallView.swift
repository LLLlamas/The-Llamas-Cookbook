import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss)               private var dismiss
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(LlamaProStore.self)      private var proStore
    @Environment(QuotaService.self)       private var quotaService

    @State private var selectedPlan: LlamaProStore.Plan = .yearly
    @State private var isLoadingProducts = false

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
                    }

                    planPicker

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
                guard proStore.monthlyProduct == nil && proStore.yearlyProduct == nil else { return }
                isLoadingProducts = true
                await proStore.loadProduct()
                isLoadingProducts = false
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
                    Task { await quotaService.refresh(force: true) }
                    dismiss()
                }
            }
        }
    }

    // MARK: - Plan picker

    private var planPicker: some View {
        VStack(spacing: AppSpacing.sm) {
            planCard(plan: .yearly,
                     title: "Yearly",
                     price: proStore.yearlyProduct?.displayPrice,
                     suffix: " / year",
                     badge: "Best value")
            planCard(plan: .monthly,
                     title: "Monthly",
                     price: proStore.monthlyProduct?.displayPrice,
                     suffix: " / month",
                     badge: nil)
        }
    }

    private func planCard(
        plan: LlamaProStore.Plan,
        title: String,
        price: String?,
        suffix: String,
        badge: String?
    ) -> some View {
        let selected = selectedPlan == plan
        return Button {
            selectedPlan = plan
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: AppSpacing.sm) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(selected ? AppColor.onAccent : AppColor.textPrimary)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(selected ? appearance.accentColor : AppColor.onAccent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(selected ? AppColor.onAccent : appearance.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    if let price {
                        Text(price + suffix)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selected ? AppColor.onAccent.opacity(0.85) : AppColor.textSecondary)
                    } else if isLoadingProducts {
                        Text("Loading…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selected ? AppColor.onAccent.opacity(0.6) : AppColor.textTertiary)
                    }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? AppColor.onAccent : AppColor.textTertiary)
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? appearance.accentColor : AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .stroke(selected ? appearance.accentColor : AppColor.divider, lineWidth: selected ? 0 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
            .liftedCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feature list

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

    // MARK: - Subscribe button

    private var subscribeButton: some View {
        Button {
            Task {
                let product = selectedPlan == .yearly ? proStore.yearlyProduct : proStore.monthlyProduct
                guard let product else { return }
                await proStore.purchase(product)
            }
        } label: {
            ZStack {
                if proStore.isPurchasing || isLoadingProducts {
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
        .disabled(proStore.isPurchasing || isLoadingProducts)
    }

    // MARK: - Legal

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
