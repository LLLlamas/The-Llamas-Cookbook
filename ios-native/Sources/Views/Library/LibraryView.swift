import SwiftUI
import SwiftData

private enum LibraryFilter: Equatable, Hashable {
    case all
    case favorites
    case tag(String)
}

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recipe.createdAt, order: .reverse) private var recipes: [Recipe]

    @State private var filter: LibraryFilter = .all
    @State private var showingNewEditor = false
    @State private var showingImport = false
    @State private var deletingRecipe: Recipe?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            addButton
        }
        .navigationTitle("Llamas Cookbook")
        .toolbarBackground(AppColor.background, for: .navigationBar)
        .navigationDestination(for: Recipe.self) { recipe in
            RecipeDetailView(recipe: recipe)
        }
        .sheet(isPresented: $showingNewEditor) {
            NavigationStack {
                RecipeEditorView(recipe: nil)
            }
        }
        .sheet(isPresented: $showingImport) {
            NavigationStack {
                ImportRecipeView()
            }
        }
        .alert(
            "Delete recipe?",
            isPresented: Binding(
                get: { deletingRecipe != nil },
                set: { if !$0 { deletingRecipe = nil } }
            ),
            presenting: deletingRecipe
        ) { recipe in
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                modelContext.delete(recipe)
                deletingRecipe = nil
            }
        } message: { recipe in
            Text("\"\(recipe.title)\" will be permanently removed.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if recipes.isEmpty {
            EmptyLibraryView()
        } else {
            VStack(spacing: 0) {
                if !allTags.isEmpty || favoriteCount > 0 {
                    filterStrip
                        .background(AppColor.background)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(AppColor.divider)
                                .frame(height: 1)
                        }
                }

                if filtered.isEmpty {
                    emptyFilterState
                } else {
                    ScrollView {
                        LazyVStack(spacing: AppSpacing.md) {
                            ForEach(filtered) { recipe in
                                NavigationLink(value: recipe) {
                                    RecipeCardView(recipe: recipe)
                                }
                                .buttonStyle(RecipeCardButtonStyle())
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deletingRecipe = recipe
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(AppSpacing.lg)
                    }
                    .background(AppColor.background)
                }
            }
        }
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.xs) {
                FilterChip(
                    label: "All  ·  \(recipes.count)",
                    isActive: filter == .all,
                    iconName: nil
                ) {
                    filter = .all
                }

                if favoriteCount > 0 {
                    FilterChip(
                        label: "Favorites  ·  \(favoriteCount)",
                        isActive: filter == .favorites,
                        iconName: "heart.fill"
                    ) {
                        filter = filter == .favorites ? .all : .favorites
                    }
                }

                ForEach(allTags, id: \.self) { tag in
                    let count = recipes.filter { $0.tags.contains(tag) }.count
                    FilterChip(
                        label: "\(StringCase.capitalizeFirst(tag))  ·  \(count)",
                        isActive: filter == .tag(tag),
                        iconName: nil
                    ) {
                        filter = filter == .tag(tag) ? .all : .tag(tag)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.sm)
        }
    }

    private var emptyFilterState: some View {
        VStack(spacing: AppSpacing.md) {
            Text(emptyFilterMessage)
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.center)
            Button("Clear filter") {
                filter = .all
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.sm)
            .background(AppColor.surface)
            .foregroundStyle(AppColor.accent)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.background)
    }

    private var emptyFilterMessage: String {
        switch filter {
        case .all: return ""
        case .favorites: return "Nothing favorited yet"
        case .tag(let tag): return "No recipes tagged \"\(StringCase.capitalizeFirst(tag))\""
        }
    }

    private var addButton: some View {
        Menu {
            Button {
                Haptics.impact(.light)
                showingNewEditor = true
            } label: {
                Label("New recipe", systemImage: "square.and.pencil")
            }
            Button {
                Haptics.impact(.light)
                showingImport = true
            } label: {
                Label("Import from text", systemImage: "doc.on.clipboard")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
                .frame(width: 60, height: 60)
                .background(AppColor.accent)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
        }
        .padding(AppSpacing.xl)
        .accessibilityLabel("Add or import recipe")
    }

    // MARK: Derived

    private var allTags: [String] {
        var set = Set<String>()
        for r in recipes { for t in r.tags { set.insert(t) } }
        return set.sorted()
    }

    private var favoriteCount: Int {
        recipes.lazy.filter(\.favorite).count
    }

    private var filtered: [Recipe] {
        switch filter {
        case .all: return recipes
        case .favorites: return recipes.filter(\.favorite)
        case .tag(let tag): return recipes.filter { $0.tags.contains(tag) }
        }
    }
}

private struct FilterChip: View {
    let label: String
    let isActive: Bool
    let iconName: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.xs) {
                if let iconName {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 2)
            .background(isActive ? AppColor.accent : AppColor.surface)
            .foregroundStyle(isActive ? Color(red: 1, green: 0.992, blue: 0.972) : AppColor.textPrimary)
            .overlay(
                Capsule().stroke(isActive ? AppColor.accent : AppColor.divider, lineWidth: 1)
            )
            .clipShape(Capsule())
        }
    }
}

private struct RecipeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview("Populated") {
    NavigationStack { LibraryView() }
        .modelContainer(previewContainer(populated: true))
}

#Preview("Empty") {
    NavigationStack { LibraryView() }
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
        let r1 = Recipe(title: "Grandma's Sunday pasta",
                        summary: "The red sauce that started it all.",
                        favorite: true,
                        tags: ["dinner", "pasta"])
        let r2 = Recipe(title: "Weeknight sheet-pan salmon",
                        cookTimeMinutes: 20,
                        tags: ["dinner", "quick"])
        let r3 = Recipe(title: "Brown butter chocolate chip cookies",
                        tags: ["dessert"])
        container.mainContext.insert(r1)
        container.mainContext.insert(r2)
        container.mainContext.insert(r3)
    }
    return container
}
