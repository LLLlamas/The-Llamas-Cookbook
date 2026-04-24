import SwiftUI
import SwiftData

private enum LibraryFilter: Equatable, Hashable {
    case all
    case favorites
    case tag(String)
}

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(EditorCoordinator.self) private var editor
    @Query(sort: \Recipe.title, order: .forward) private var recipes: [Recipe]

    @State private var filter: LibraryFilter = .all
    @State private var deletingRecipe: Recipe?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            addButton
        }
        .navigationTitle("Llamas Cookbook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: AppSpacing.xs + 2) {
                    LlamaMascot(size: 28)
                    Text("Llamas Cookbook")
                        .font(.system(size: 22, weight: .heavy, design: .serif))
                        .foregroundStyle(AppColor.accentDeep)
                        .tracking(0.3)
                }
            }
        }
        .toolbarBackground(AppColor.background, for: .navigationBar)
        .navigationDestination(for: Recipe.self) { recipe in
            RecipeDetailView(recipe: recipe)
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
                    recipeList
                }
            }
        }
    }

    private var recipeList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
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
                            .id(recipe.id)
                        }
                    }
                    // Right padding leaves room for the letter index so
                    // it doesn't overlap card content.
                    .padding(.leading, AppSpacing.lg)
                    .padding(.trailing, AppSpacing.lg + 16)
                    .padding(.vertical, AppSpacing.lg)
                }
                .background(AppColor.background)

                if availableLetters.count > 1 {
                    LetterIndex(letters: availableLetters) { letter in
                        guard let target = firstRecipe(startingWith: letter) else { return }
                        Haptics.selection()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(target.id, anchor: .top)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
    }

    private var availableLetters: [String] {
        Array(Set(filtered.map(Self.sectionLetter))).sorted(by: Self.letterOrder)
    }

    private func firstRecipe(startingWith letter: String) -> Recipe? {
        filtered.first { Self.sectionLetter(for: $0) == letter }
    }

    private static func sectionLetter(for recipe: Recipe) -> String {
        sectionLetter(for: recipe.title)
    }

    /// First character of the title, uppercased. Non-letters (digits,
    /// punctuation, emoji) collapse into a "#" bucket — matches the
    /// convention iOS's Contacts app uses for its side index.
    private static func sectionLetter(for title: String) -> String {
        guard let first = title.first else { return "#" }
        let s = String(first).uppercased()
        return s.rangeOfCharacter(from: .letters) != nil ? s : "#"
    }

    /// Sort letters A–Z, with "#" at the end so the alphabet reads normally.
    private static func letterOrder(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "#" { return false }
        if rhs == "#" { return true }
        return lhs < rhs
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
                        label: "\(StringCase.titleCase(tag))  ·  \(count)",
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
        case .tag(let tag): return "No recipes tagged \"\(StringCase.titleCase(tag))\""
        }
    }

    private var addButton: some View {
        Menu {
            Button {
                Haptics.impact(.light)
                editor.startNew()
            } label: {
                Label("New recipe", systemImage: "square.and.pencil")
            }
            Button {
                Haptics.impact(.light)
                editor.startImport()
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

/// Vertical A–Z strip on the trailing edge of the library list. Tap a
/// letter to jump. Drag a finger up/down to scrub through letters —
/// matches the behavior of iOS Contacts' side index.
private struct LetterIndex: View {
    let letters: [String]
    let onSelect: (String) -> Void

    @State private var lastScrubbed: String?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: 10, weight: .heavy, design: .serif))
                        .foregroundStyle(AppColor.accentDeep)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 20)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(AppColor.surface.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(AppColor.divider, lineWidth: 0.5)
                    )
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Map y-position within the strip to a letter index.
                        let h = geo.size.height - 12  // minus vertical padding
                        let per = h / CGFloat(max(letters.count, 1))
                        let raw = Int((value.location.y - 6) / per)
                        let idx = max(0, min(letters.count - 1, raw))
                        let letter = letters[idx]
                        if letter != lastScrubbed {
                            lastScrubbed = letter
                            onSelect(letter)
                        }
                    }
                    .onEnded { _ in lastScrubbed = nil }
            )
        }
        .frame(width: 22)
    }
}

#Preview("Populated") {
    NavigationStack { LibraryView() }
        .modelContainer(previewContainer(populated: true))
        .environment(CookingSession())
        .environment(EditorCoordinator())
}

#Preview("Empty") {
    NavigationStack { LibraryView() }
        .modelContainer(previewContainer(populated: false))
        .environment(CookingSession())
        .environment(EditorCoordinator())
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
