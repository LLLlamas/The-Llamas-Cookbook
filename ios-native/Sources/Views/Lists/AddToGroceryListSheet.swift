import SwiftUI
import SwiftData

/// Sheet for adding a recipe's ingredients to a grocery list. The user
/// first chooses *which* ingredients to add (everything is selected by
/// default — uncheck whatever you already have at home), then picks an
/// existing list or spins up a new one named after the recipe. The chosen
/// ingredients land as `GroceryItem`s (stored quantities, no scaling — the
/// detail view shows ingredients unscaled) tagged with `sourceRecipeID`.
/// Items already on the chosen list (matched by name) are skipped so adding
/// the same recipe twice doesn't duplicate rows.
///
/// On success the sheet reports how many items actually landed (post-dedup)
/// + the list name back to the caller via `onAdded`, which drives the
/// confirmation toast on `RecipeDetailView`.
///
/// On-device aisle triage (Phase 4) runs against the freshly-added items in
/// `GroceryListDetailView`; until the user opens the list they sit under
/// "Other" and can be sorted by hand.
struct AddToGroceryListSheet: View {
    let recipe: Recipe
    /// Reports `(addedCount, listName)` back to the presenter after a
    /// successful add so it can surface the confirmation toast. `addedCount`
    /// is the post-dedup figure — 0 means every selected item was already on
    /// the list.
    var onAdded: (_ count: Int, _ listName: String) -> Void = { _, _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceSettings.self) private var appearance

    @Query(sort: \GroceryList.updatedAt, order: .reverse)
    private var lists: [GroceryList]

    /// Ingredient ids the user wants on the list. Seeded to "all" so the
    /// common path (add everything) is a single tap; the user trims down
    /// whatever they already have on hand.
    @State private var selectedIDs: Set<UUID>

    private var accent: Color { appearance.cookbookTitleAccentColor }

    init(
        recipe: Recipe,
        onAdded: @escaping (_ count: Int, _ listName: String) -> Void = { _, _ in }
    ) {
        self.recipe = recipe
        self.onAdded = onAdded
        let ids = recipe.sortedIngredients
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.id)
        _selectedIDs = State(initialValue: Set(ids))
    }

    /// Non-empty ingredients in display order.
    private var ingredients: [Ingredient] {
        recipe.sortedIngredients.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The subset the user has chosen to add, in display order.
    private var selectedIngredients: [Ingredient] {
        ingredients.filter { selectedIDs.contains($0.id) }
    }

    private var allSelected: Bool {
        !ingredients.isEmpty && selectedIDs.count == ingredients.count
    }

    private var hasSelection: Bool { !selectedIDs.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                ingredientSection
                Section {
                    Button(action: createAndAdd) {
                        Label("New list from this recipe", systemImage: "plus.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(hasSelection ? accent : AppColor.textTertiary)
                    }
                    .disabled(!hasSelection)
                }

                if !lists.isEmpty {
                    Section("Add to an existing list") {
                        ForEach(lists) { list in
                            Button {
                                add(to: list)
                            } label: {
                                existingListRow(list)
                            }
                            .disabled(!hasSelection)
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

    // MARK: - Ingredient picker

    private var ingredientSection: some View {
        Section {
            ForEach(ingredients) { ingredient in
                Button {
                    toggle(ingredient)
                } label: {
                    ingredientRow(ingredient)
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text("Choose what to add")
                Spacer()
                Button(allSelected ? "Clear all" : "Select all") {
                    Haptics.selection()
                    if allSelected {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(ingredients.map(\.id))
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .textCase(nil)
            }
        } footer: {
            Text("Uncheck anything you already have at home.")
        }
    }

    private func ingredientRow(_ ingredient: Ingredient) -> some View {
        let selected = selectedIDs.contains(ingredient.id)
        let display = ingredient.display()
        return HStack(spacing: AppSpacing.sm) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(selected ? accent : AppColor.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(ingredient.name.capitalized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !display.measure.isEmpty {
                    Text(display.measure)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColor.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .opacity(selected ? 1 : 0.5)
    }

    private func existingListRow(_ list: GroceryList) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "basket.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(hasSelection ? accent : AppColor.textTertiary)
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
                .foregroundStyle(hasSelection ? accent : AppColor.textTertiary)
        }
    }

    private var header: some View {
        Text(headerText)
            .font(AppFont.caption)
            .foregroundStyle(AppColor.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.sm)
            .background(.regularMaterial)
    }

    private var headerText: String {
        let n = selectedIDs.count
        let total = ingredients.count
        if n == 0 {
            return "Pick ingredients to add from \(recipe.title)"
        }
        let noun = total == 1 ? "ingredient" : "ingredients"
        return "\(n) of \(total) \(noun) from \(recipe.title)"
    }

    // MARK: - Actions

    private func toggle(_ ingredient: Ingredient) {
        Haptics.selection()
        if selectedIDs.contains(ingredient.id) {
            selectedIDs.remove(ingredient.id)
        } else {
            selectedIDs.insert(ingredient.id)
        }
    }

    private func createAndAdd() {
        let name = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = GroceryList(name: name.isEmpty ? "Grocery List" : name)
        modelContext.insert(list)
        add(to: list)
    }

    private func add(to list: GroceryList) {
        guard hasSelection else { return }
        let existing = Set(list.items.map { $0.name.lowercased() })
        var nextOrder = (list.items.map(\.order).max() ?? -1) + 1
        var added = 0
        for ingredient in selectedIngredients where !existing.contains(ingredient.name.lowercased()) {
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
            added += 1
        }
        list.touch()
        Haptics.success()
        onAdded(added, list.name)
        dismiss()
    }
}
