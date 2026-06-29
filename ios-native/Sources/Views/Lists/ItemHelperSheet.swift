import SwiftUI

/// The per-item "?" helper. A tight "what is it?" answer for a shopper who
/// doesn't recognize the item: a very brief on-device blurb plus the aisle
/// it likely lives in. Out-of-stock lives only in the row's separate "!"
/// button.
struct ItemHelperSheet: View {
    @Bindable var item: GroceryItem

    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceSettings.self) private var appearance

    @State private var blurb: String?
    @State private var loadingBlurb = true

    private var accent: Color { appearance.cookbookTitleAccentColor }

    /// The aisle to surface: the item's own classification if it's been
    /// triaged, else the researched heuristic.
    private var aisle: String {
        item.aisle ?? GroceryKnowledge.aisle(for: item.name)
    }

    var body: some View {
        NavigationStack {
            List {
                whatIsItSection
                aisleSection
            }
            .navigationTitle(item.name.capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .tint(accent)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(accent)
                }
            }
            .task(id: item.id) { await loadContent() }
        }
        .presentationDetents([.medium])
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
                Text("A common grocery item.")
                    .font(.system(size: 15))
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
    }

    // MARK: - Likely aisle

    private var aisleSection: some View {
        Section {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Likely aisle")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                    Text(aisle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                }
            }
        }
    }

    // MARK: - Actions

    private func loadContent() async {
        loadingBlurb = true
        blurb = await IngredientAssistant.describe(item.name)
        loadingBlurb = false
    }
}
