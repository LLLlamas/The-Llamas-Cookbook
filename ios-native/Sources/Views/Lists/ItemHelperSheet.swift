import SwiftUI

/// The per-item "?" helper. Two jobs for whoever's at the store:
///   • **What is this?** — an on-device blurb (what it is + which aisle) for
///     a shopper who doesn't recognize the item, plus a "See photos" link to
///     a web image search (the on-device model is text-only).
///   • **They don't have this** — flags the item out-of-stock and surfaces
///     substitute swaps (researched reference first, then the model). In a
///     shared list this also pings the cook (Phase 6/8); for a local list it
///     just records the swap the shopper picks.
struct ItemHelperSheet: View {
    @Bindable var item: GroceryItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(AppearanceSettings.self) private var appearance

    @State private var blurb: String?
    @State private var loadingBlurb = true
    @State private var substitutes: [String] = []
    @State private var loadingSubs = false
    @State private var revealedSubs = false

    private var accent: Color { appearance.cookbookTitleAccentColor }

    var body: some View {
        NavigationStack {
            List {
                whatIsItSection
                outOfStockSection
            }
            .navigationTitle(item.name.capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .tint(accent)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(accent)
                }
            }
            .task { await loadBlurb() }
        }
    }

    // MARK: - What is this?

    private var whatIsItSection: some View {
        Section("What is it?") {
            if loadingBlurb {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView().tint(accent)
                    Text("Asking the llama…")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
            } else if let blurb {
                Text(blurb)
                    .font(.system(size: 15))
                    .foregroundStyle(AppColor.textPrimary)
            } else {
                Text("Tap below to see what \(item.name.lowercased()) looks like.")
                    .font(.system(size: 15))
                    .foregroundStyle(AppColor.textSecondary)
            }

            Button {
                Haptics.selection()
                openURL(imageSearchURL)
            } label: {
                Label("See photos", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
    }

    // MARK: - Out of stock

    @ViewBuilder
    private var outOfStockSection: some View {
        Section("Can't find it?") {
            if let swap = item.substitution, !swap.isEmpty {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "arrow.triangle.swap")
                        .foregroundStyle(accent)
                    Text("Getting \(swap) instead")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                }
                Button("Clear substitute", role: .destructive) {
                    item.substitution = nil
                    item.outOfStock = false
                }
                .font(.system(size: 14, weight: .semibold))
            } else if revealedSubs {
                if loadingSubs {
                    HStack(spacing: AppSpacing.sm) {
                        ProgressView().tint(accent)
                        Text("Finding swaps…")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                } else if substitutes.isEmpty {
                    Text("No common swap on hand — tap “See photos” above, or check with whoever's cooking.")
                        .font(.system(size: 14))
                        .foregroundStyle(AppColor.textSecondary)
                } else {
                    Text("Tap a swap to use it:")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                    ForEach(substitutes, id: \.self) { swap in
                        Button {
                            choose(swap)
                        } label: {
                            HStack(spacing: AppSpacing.sm) {
                                Image(systemName: "arrow.right.circle")
                                    .foregroundStyle(accent)
                                Text(swap)
                                    .font(.system(size: 15))
                                    .foregroundStyle(AppColor.textPrimary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                }
            } else {
                Button {
                    Task { await flagOutOfStock() }
                } label: {
                    Label("They don't have this", systemImage: "exclamationmark.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Actions

    private func loadBlurb() async {
        blurb = await IngredientAssistant.describe(item.name)
        loadingBlurb = false
    }

    private func flagOutOfStock() async {
        Haptics.warning()
        item.outOfStock = true
        revealedSubs = true
        loadingSubs = true
        substitutes = await IngredientAssistant.suggestSubstitutes(for: item.name)
        loadingSubs = false
    }

    private func choose(_ swap: String) {
        item.substitution = swap
        item.outOfStock = true
        Haptics.success()
        dismiss()
    }

    private var imageSearchURL: URL {
        let query = "\(item.name) food"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: "https://www.google.com/search?tbm=isch&q=\(encoded)")
            ?? URL(string: "https://www.google.com")!
    }
}
