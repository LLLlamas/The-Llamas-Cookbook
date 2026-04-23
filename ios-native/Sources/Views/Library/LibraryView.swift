import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recipe.createdAt, order: .reverse) private var recipes: [Recipe]

    var body: some View {
        Group {
            if recipes.isEmpty {
                EmptyLibraryView()
            } else {
                List {
                    ForEach(recipes) { recipe in
                        RecipeRowView(recipe: recipe)
                    }
                    .onDelete(perform: deleteRecipes)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(AppColor.background)
            }
        }
        .navigationTitle("Llamas Cookbook")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addPlaceholder()
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.semibold)
                }
                .accessibilityLabel("Add recipe")
            }
        }
        .background(AppColor.background)
    }

    private func addPlaceholder() {
        let recipe = Recipe(title: "New recipe")
        modelContext.insert(recipe)
    }

    private func deleteRecipes(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(recipes[index])
        }
    }
}

private struct RecipeRowView: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                Text(recipe.title)
                    .font(AppFont.sectionHeading)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(2)
                Spacer()
                if recipe.favorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(AppColor.accent)
                }
            }
            if let summary = recipe.summary, !summary.isEmpty {
                Text(summary)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(2)
            }
        }
        .listRowBackground(AppColor.surface)
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "fork.knife.circle")
                .font(.system(size: 96, weight: .regular))
                .foregroundStyle(AppColor.accent)
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

#Preview("Populated") {
    NavigationStack {
        LibraryView()
    }
    .modelContainer(previewContainer(populated: true))
}

#Preview("Empty") {
    NavigationStack {
        LibraryView()
    }
    .modelContainer(previewContainer(populated: false))
}

@MainActor
private func previewContainer(populated: Bool) -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(
        for: Recipe.self, Ingredient.self, RecipeStep.self,
        configurations: config
    )
    if populated {
        let r1 = Recipe(title: "Grandma's Sunday pasta", summary: "The red sauce that started it all.", favorite: true)
        let r2 = Recipe(title: "Weeknight sheet-pan salmon", cookTimeMinutes: 20)
        container.mainContext.insert(r1)
        container.mainContext.insert(r2)
    }
    return container
}
