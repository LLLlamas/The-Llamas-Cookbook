import SwiftUI
import SwiftData

/// Sheet for adding a recipe's ingredients to a grocery list. Pick an
/// existing list or spin up a new one named after the recipe; the
/// ingredients land as `GroceryItem`s (stored quantities, no scaling — the
/// detail view shows ingredients unscaled) tagged with `sourceRecipeID`.
/// Items already on the chosen list (matched by name) are skipped so adding
/// the same recipe twice doesn't duplicate rows.
///
/// On-device aisle triage (Phase 4) runs against the freshly-added items;
/// until then they sit under "Other" and the user can sort by hand.
struct AddToGroceryListSheet: View {
    let recipe: Recipe

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceSettings.self) private var appearance

    @Query(sort: \GroceryList.updatedAt, order: .reverse)
    private var lists: [GroceryList]

    private var accent: Color { appearance.cookbookTitleAccentColor }

    /// Non-empty ingredients in display order.
    private var ingredients: [Ingredient] {
        recipe.sortedIngredients.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: createAndAdd) {
                        Label("New list from this recipe", systemImage: "plus.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                }

                if !lists.isEmpty {
                    Section("Add to an existing list") {
                        ForEach(lists) { list in
                            Button {
                                add(to: list)
                            } label: {
                                HStack(spacing: AppSpacing.sm) {
                                    Image(systemName: "basket.fill")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(accent)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(list.name)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(AppColor.textPrimary)
                                        Text(list.items.isEmpty ? "Empty" : "\(list.items.count) items")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(AppColor.textTertiary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(accent)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to a list")
            .navigationBarTitleDisplayMode(.inline)
            .tint(accent)
            .safeAreaInset(edge: .top) { header }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(accent)
                }
            }
        }
    }

    private var header: some View {
        Text(ingredients.count == 1
             ? "1 ingredient from \(recipe.title)"
             : "\(ingredients.count) ingredients from \(recipe.title)")
            .font(AppFont.caption)
            .foregroundStyle(AppColor.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.sm)
            .background(.regularMaterial)
    }

    // MARK: - Actions

    private func createAndAdd() {
        let name = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = GroceryList(name: name.isEmpty ? "Grocery List" : name)
        modelContext.insert(list)
        add(to: list)
    }

    private func add(to list: GroceryList) {
        let existing = Set(list.items.map { $0.name.lowercased() })
        var nextOrder = (list.items.map(\.order).max() ?? -1) + 1
        for ingredient in ingredients where !existing.contains(ingredient.name.lowercased()) {
            let item = GroceryItem(
                name: ingredient.name,
                quantity: ingredient.quantity,
                unit: ingredient.unit,
                sourceRecipeID: recipe.id,
                order: nextOrder
            )
            modelContext.insert(item)
            item.list = list
            nextOrder += 1
        }
        list.touch()
        Haptics.success()
        dismiss()
    }
}
