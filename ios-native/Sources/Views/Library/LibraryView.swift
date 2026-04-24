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
            mascotWatermark
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

    /// Faint mascot watermark sitting behind everything. Pinned toward
    /// the bottom-center so it feels like an emblem rather than a pattern,
    /// and low-opacity enough that cards stay legible on top.
    private var mascotWatermark: some View {
        VStack {
            Spacer(minLength: 0)
            LlamaMascot(size: 300)
                .opacity(0.06)
                .padding(.bottom, 120)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
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
                // No explicit background here — we want the faint mascot
                // watermark sitting behind the list to peek through the
                // gaps between recipe cards.
                .scrollContentBackground(.hidden)

                LetterIndex(
                    letters: Self.allLetters,
                    populated: populatedLetters
                ) { letter in
                    guard let target = firstRecipe(atOrAfter: letter) else { return }
                    Haptics.selection()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(target.id, anchor: .top)
                    }
                }
                .padding(.trailing, 2)
            }
        }
    }

    /// Full A–Z (plus `#` for non-letter starts) — always rendered so the
    /// strip has a consistent, filled-out look. Letters without any recipe
    /// are dimmed; tapping one scrolls to the next available letter.
    private static let allLetters: [String] = {
        let az = (0..<26).map { String(UnicodeScalar(UInt8(65 + $0))) }
        return az + ["#"]
    }()

    private var populatedLetters: Set<String> {
        Set(filtered.map(Self.sectionLetter))
    }

    /// Find the first recipe whose section letter is `letter` or the next
    /// populated letter after it. Keeps taps on empty letters useful
    /// instead of no-ops.
    private func firstRecipe(atOrAfter letter: String) -> Recipe? {
        guard let startIndex = Self.allLetters.firstIndex(of: letter) else { return nil }
        let populated = populatedLetters
        for candidate in Self.allLetters[startIndex...] where populated.contains(candidate) {
            return filtered.first { Self.sectionLetter(for: $0) == candidate }
        }
        return nil
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

/// Vertical A–Z strip on the trailing edge of the library list. Renders
/// the whole alphabet (+ `#`) for a consistent full look; letters that
/// match at least one recipe are fully opaque, the rest are dimmed.
/// Tap or drag your finger up/down to scrub through letters.
private struct LetterIndex: View {
    let letters: [String]
    let populated: Set<String>
    let onSelect: (String) -> Void

    @State private var lastScrubbed: String?

    private let rowHeight: CGFloat = 11
    private let stripWidth: CGFloat = 14
    private let verticalPadding: CGFloat = 4

    var body: some View {
        let strip = VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 9, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.accentDeep.opacity(populated.contains(letter) ? 0.85 : 0.3))
                    .frame(maxWidth: .infinity)
                    .frame(height: rowHeight)
            }
        }
        .frame(width: stripWidth)
        .padding(.vertical, verticalPadding)
        .background(
            Capsule()
                .fill(AppColor.surface.opacity(0.35))
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let idx = max(
                        0,
                        min(
                            letters.count - 1,
                            Int((value.location.y - verticalPadding) / rowHeight)
                        )
                    )
                    let letter = letters[idx]
                    if letter != lastScrubbed {
                        lastScrubbed = letter
                        onSelect(letter)
                    }
                }
                .onEnded { _ in lastScrubbed = nil }
        )

        // Vertically center the strip in the trailing edge of the list.
        return VStack {
            Spacer(minLength: 0)
            strip
            Spacer(minLength: 0)
        }
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
