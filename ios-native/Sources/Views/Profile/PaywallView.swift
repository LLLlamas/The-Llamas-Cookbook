import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss)               private var dismiss
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(LlamaProStore.self)      private var proStore
    @Environment(QuotaService.self)       private var quotaService

    @State private var selectedPlan: LlamaProStore.Plan
    @State private var isLoadingProducts = false
    @State private var showNoRestoreAlert = false

    init(initialPlan: LlamaProStore.Plan = .yearly) {
        _selectedPlan = State(initialValue: initialPlan)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.xl) {
                    Spacer().frame(height: AppSpacing.lg)

                    LlamaLogoOrCrown(size: 96, accent: AppColor.accent)
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
                        Task {
                            let wasPro = proStore.isPro
                            await proStore.restore()
                            if !proStore.isPro && !wasPro {
                                showNoRestoreAlert = true
                            }
                        }
                    } label: {
                        Text("Restore Purchases")
                            .font(AppFont.caption)
                            .foregroundStyle(appearance.accentColor)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .disabled(proStore.isPurchasing)
                    .alert("No Purchases Found", isPresented: $showNoRestoreAlert) {
                        Button("OK", role: .cancel) { }
                    } message: {
                        Text("No active Llama Pro subscription was found for this Apple Account.")
                    }

                    legalText

                    Spacer().frame(height: AppSpacing.xl)
                }
                .padding(.horizontal, AppSpacing.lg)
            }
            .llamaBackground()
            .navigationBarTitleDisplayMode(.inline)
            .tint(appearance.accentColor)
            .task {
                // Sync against actual StoreKit entitlements first. This catches
                // the case where a subscription was purchased in a prior session
                // but plan wasn't updated (e.g. the old isPro-based dismiss bug).
                // If plan changes here, onChange(of: proStore.plan) dismisses below.
                await proStore.checkCurrentEntitlements()
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
            .onChange(of: proStore.plan) { _, _ in
                // Fires on any tier change: free→monthly, free→yearly, monthly→yearly.
                // Watching plan (not isPro) catches the monthly→yearly upgrade where
                // isPro was already true and would never trigger.
                Task { await quotaService.refresh(force: true) }
                dismiss()
            }
        }
    }

    // MARK: - Plan picker

    private var planPicker: some View {
        VStack(spacing: AppSpacing.sm) {
            // Always show yearly — it's the upgrade target for everyone.
            planCard(plan: .yearly,
                     title: "Yearly",
                     price: proStore.yearlyProduct?.displayPrice,
                     suffix: " / year",
                     badge: "Best value")
            // Only show monthly if the user isn't already on a paid plan.
            if proStore.plan == .none {
                planCard(plan: .monthly,
                         title: "Monthly",
                         price: proStore.monthlyProduct?.displayPrice,
                         suffix: " / month",
                         badge: nil)
            }
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
            PaywallFeatureRow(icon: "sparkles",
                             text: "AI-powered recipe extraction from photos")
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
        VStack(spacing: AppSpacing.sm) {
            Text("Subscription automatically renews unless cancelled at least 24 hours before the end of the current period. Manage anytime in Settings → Apple Account → Subscriptions.")
                .font(.system(size: 11))
                .foregroundStyle(AppColor.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)

            HStack(spacing: AppSpacing.md) {
                Link("Privacy Policy",
                     destination: URL(string: "https://llamascookbook.pages.dev/privacy")!)
                Text("·")
                Link("Terms of Use",
                     destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }
            .font(.system(size: 11))
            .foregroundStyle(AppColor.textSecondary.opacity(0.7))
        }
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
