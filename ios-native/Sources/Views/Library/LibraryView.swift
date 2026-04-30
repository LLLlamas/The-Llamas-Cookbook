import SwiftUI
import SwiftData

private enum LibraryFilter: Equatable, Hashable {
    case all
    case favorites
    case tag(String)
}

private enum LibrarySort: String, Equatable, Hashable {
    case aToZ
    case mostRecent

    var label: String {
        switch self {
        case .aToZ: return "A–Z"
        case .mostRecent: return "Most Recent"
        }
    }

    var iconName: String {
        switch self {
        case .aToZ: return "textformat"
        case .mostRecent: return "clock.arrow.circlepath"
        }
    }
}

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(EditorCoordinator.self) private var editor
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(CookingSession.self) private var session
    @Environment(NavigationContext.self) private var navContext
    @Environment(UserAccount.self) private var userAccount
    @Environment(OwnerProfile.self) private var ownerProfile
    // Read so we can re-inject across the ProfileView sheet boundary —
    // iOS 18 occasionally drops @Observable values across sheet
    // presentations (per CLAUDE.md › "Re-inject environments into
    // covers"). LibraryView itself doesn't consume FriendsStore.
    @Environment(FriendsStore.self) private var friendsStore
    @Query(sort: \Recipe.title, order: .forward) private var recipes: [Recipe]

    @State private var filter: LibraryFilter = .all
    @State private var sort: LibrarySort = .aToZ
    @State private var deletingRecipe: Recipe?
    @State private var showingAppearance = false
    @State private var showingProfile = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            mascotWatermark
            content
            addButton
        }
        // Explicit cream behind everything so the recipeList — which uses
        // .scrollContentBackground(.hidden) so the mascot watermark can
        // peek through — never falls through to the system background.
        .background(AppColor.background)
        .navigationTitle(cookbookTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: AppSpacing.xs) {
                    Button {
                        Haptics.selection()
                        showingAppearance = true
                    } label: {
                        // Sized down from 72 → 52 since the principal
                        // toolbar slot now coexists with a trailing
                        // profile button; the previous logo+title pair
                        // overflowed when the right side was occupied.
                        LlamaLogo(size: 52, shadowColor: appearance.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Customize accent color")
                    // Aggressive minimumScaleFactor so long display names
                    // like "Maximilian's Cookbook" still fit on a single
                    // line alongside the 52pt logo and the trailing
                    // profile glyph on the narrowest iPhone widths.
                    Text(cookbookTitle)
                        .font(.system(size: 22, weight: .heavy, design: .serif))
                        .foregroundStyle(appearance.accentColor)
                        .tracking(0.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .truncationMode(.tail)
                }
                // Trailing breathing room before the profile icon —
                // without this, "Cookbook" runs flush against the
                // person.crop.circle glyph on iPhone widths.
                .padding(.trailing, AppSpacing.sm)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.selection()
                    showingProfile = true
                } label: {
                    // Filled glyph when signed in, outline when not — gives
                    // the user a quiet visual cue that the app knows who
                    // they are without surfacing the display name in the
                    // toolbar (no room, and the Profile sheet shows it
                    // prominently anyway).
                    Image(systemName: userAccount.status.isSignedIn
                          ? "person.crop.circle.fill"
                          : "person.crop.circle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(appearance.accentColor)
                }
                .accessibilityLabel("Profile")
            }
        }
        .sheet(isPresented: $showingAppearance) {
            AccentColorPicker(settings: appearance)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingProfile) {
            ProfileView()
                // Re-inject @Observable values across the sheet boundary
                // — same belt-and-suspenders dance as the Cook Mode
                // cover and the share-import sheet in RootView.
                .environment(userAccount)
                .environment(ownerProfile)
                .environment(appearance)
                .environment(friendsStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: navContext.pendingImportedRecipeID) { _, newID in
            // Slice 5 — when a friend's recipe is imported (signal
            // set by `FriendRecipeDetailView.performImport`),
            // dismiss the Profile sheet so the friend's nav stack
            // tears down. RootView's mirror observer handles the
            // Detail-push side of the same signal.
            if newID != nil {
                showingProfile = false
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
                // Drop any active cook for this recipe BEFORE the
                // delete fires so CookingSession doesn't end up
                // holding a SwiftData fault to a deleted @Model.
                session.cleanupCooks(forDeletedRecipeID: recipe.id)
                // Tear down the cloud-side mirror for this recipe so
                // friends stop seeing it in `FriendLibraryView`. Fired
                // before the local delete so the recipeID capture
                // happens against a still-live @Model. Best-effort.
                LibraryMirrorService.shared.deleteRecipe(recipeID: recipe.id)
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

    /// Faint mascot watermark sitting behind everything. Sized to nearly
    /// fill the smaller screen dimension and centered in the available
    /// area so it reads as a page-wide emblem; opacity stays low enough
    /// that cards remain legible on top.
    private var mascotWatermark: some View {
        GeometryReader { geo in
            // 95% of the smaller dimension keeps the mascot inside the
            // safe visible area on every iPhone width without clipping.
            let dim = min(geo.size.width, geo.size.height) * 0.95
            // Watermark at 6% opacity — drop the shadow entirely
            // (a halo on a faint logo just muddies the page).
            LlamaLogo(size: dim, shadowOpacity: 0)
                .opacity(0.06)
                .frame(width: geo.size.width, height: geo.size.height)
        }
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
                    .padding(.top, AppSpacing.lg)
                    // Extra bottom runway when the cooking pills are
                    // overlaying the bottom edge — without this the
                    // last recipe card gets clipped under the pills.
                    // ~96pt clears the pill height (~46) + bottom
                    // overlay padding (12) + safe-area inset (~34).
                    .padding(.bottom, AppSpacing.lg + (isCookMinimized ? 80 : 0))
                }
                // No explicit background here — we want the faint mascot
                // watermark sitting behind the list to peek through the
                // gaps between recipe cards.
                .scrollContentBackground(.hidden)

                // The A–Z scrub strip only makes sense when the list is
                // sorted alphabetically. Hide it under "Most Recent"
                // where the order is chronological and tapping a letter
                // would scroll to a near-random card.
                if sort == .aToZ {
                    LetterIndex(
                        letters: Self.allLetters,
                        populated: populatedLetters,
                        accent: appearance.accentColor,
                        externalHighlightLetter: highlightLetter
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
            // Post-save highlight: RootView sets `pendingHighlightRecipeID`
            // after a save (any import flow or scratch entry) so the user
            // briefly sees the library scroll to their new recipe — and,
            // under A–Z sort, the magnify badge flash on its letter — in
            // the moment between sheet dismiss and Detail push. The
            // scroll target is the recipe row itself; the magnify badge
            // is driven by `highlightLetter` passed into LetterIndex.
            .onChange(of: navContext.pendingHighlightRecipeID) { _, newID in
                guard let newID,
                      let target = recipes.first(where: { $0.id == newID })
                else { return }
                Haptics.selection()
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(target.id, anchor: .top)
                }
            }
        }
    }

    /// Letter the magnify badge should flash on during a post-save
    /// highlight. `nil` at all other times so the badge stays the
    /// scrub-gesture-only affordance it was before.
    private var highlightLetter: String? {
        guard let id = navContext.pendingHighlightRecipeID,
              let recipe = recipes.first(where: { $0.id == id })
        else { return nil }
        return Self.sectionLetter(for: recipe)
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
                allChipMenu

                if favoriteCount > 0 {
                    FilterChip(
                        label: "Favorites  ·  \(favoriteCount)",
                        isActive: filter == .favorites,
                        iconName: "heart.fill",
                        accent: appearance.accentColor
                    ) {
                        filter = filter == .favorites ? .all : .favorites
                    }
                }

                ForEach(allTags, id: \.self) { tag in
                    let count = recipes.filter { $0.tags.contains(tag) }.count
                    FilterChip(
                        label: "\(StringCase.titleCase(tag))  ·  \(count)",
                        isActive: filter == .tag(tag),
                        iconName: nil,
                        accent: appearance.accentColor
                    ) {
                        filter = filter == .tag(tag) ? .all : .tag(tag)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.sm)
        }
    }

    /// "All" chip rendered as a Menu so a tap opens the sort dropdown
    /// (A–Z vs. Most Recent). Selecting an option both pins the filter
    /// to All and updates the sort. The chip itself shows a small
    /// chevron so the dropdown affordance is discoverable; the active
    /// sort gets a checkmark inside the menu.
    private var allChipMenu: some View {
        Menu {
            Button {
                Haptics.selection()
                filter = .all
                sort = .aToZ
            } label: {
                Label(LibrarySort.aToZ.label,
                      systemImage: sort == .aToZ ? "checkmark" : LibrarySort.aToZ.iconName)
            }
            Button {
                Haptics.selection()
                filter = .all
                sort = .mostRecent
            } label: {
                Label(LibrarySort.mostRecent.label,
                      systemImage: sort == .mostRecent ? "checkmark" : LibrarySort.mostRecent.iconName)
            }
        } label: {
            allChipLabel
        }
    }

    /// Chip surface for the All Menu — mirrors `FilterChip`'s look so
    /// the trigger sits in line with the other chips visually, but
    /// without being a Button (Menu owns the tap).
    private var allChipLabel: some View {
        let isActive = filter == .all
        return HStack(spacing: AppSpacing.xs) {
            Text("All  ·  \(recipes.count)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? AppColor.onAccent : AppColor.textPrimary)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isActive ? AppColor.onAccent : appearance.accentColor)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.xs + 2)
        .background(isActive ? appearance.accentColor : AppColor.surface)
        .overlay(
            Capsule().stroke(isActive ? appearance.accentColor : AppColor.divider, lineWidth: 1)
        )
        .clipShape(Capsule())
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
            .foregroundStyle(appearance.accentColor)
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
                Label("Write Down Your Recipe", systemImage: "square.and.pencil")
            }
            Button {
                Haptics.impact(.light)
                editor.startImportFromText()
            } label: {
                Label("Import From Text", systemImage: "doc.on.clipboard")
            }
            Button {
                Haptics.impact(.light)
                editor.startImportFromLink()
            } label: {
                Label("Import From Link", systemImage: "link")
            }
            Button {
                Haptics.impact(.light)
                editor.startImportFromPhoto()
            } label: {
                Label("Import From Photo", systemImage: "doc.viewfinder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AppColor.onAccent)
                .frame(width: 60, height: 60)
                // Vertical gradient + slight translucency reads as a
                // raised disc rather than a flat fill — paired with the
                // top-edge highlight stroke and double shadow below.
                .background(
                    LinearGradient(
                        colors: [
                            appearance.accentColor.opacity(0.95),
                            appearance.accentColor.opacity(0.80)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.45), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            ),
                            lineWidth: 1
                        )
                )
                // Coloured ambient + neutral contact shadow → the disc
                // looks like it's hovering above the cream background.
                .shadow(color: appearance.accentColor.opacity(0.35), radius: 14, y: 6)
                .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
        }
        .padding(AppSpacing.xl)
        // When Cook Mode is minimized, the resume pill at the bottom
        // would otherwise overlap the FAB. Push it up just enough to
        // clear the pill (its rendered height + safe-area padding).
        .padding(.bottom, isCookMinimized ? 64 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isCookMinimized)
        .accessibilityLabel("Add or import recipe")
    }

    private var isCookMinimized: Bool {
        !session.activeCooks.isEmpty && !session.isCookModeVisible
    }

    // MARK: Derived

    /// Personalised cookbook title — "Lorenzo's Cookbook" when signed in
    /// with a real display name, "Llamas Cookbook" otherwise. Falls back
    /// to the brand name for the signed-out state and for the "Cook"
    /// placeholder that `UserAccount.resolveDisplayName` lands on when
    /// Apple didn't supply a name and OwnerProfile was empty — showing
    /// "Cook's Cookbook" would feel impersonal in a way the bare brand
    /// title doesn't.
    private var cookbookTitle: String {
        guard let raw = userAccount.status.identity?.displayName else {
            return "Llamas Cookbook"
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Cook" else {
            return "Llamas Cookbook"
        }
        return "\(trimmed)'s Cookbook"
    }

    private var allTags: [String] {
        var set = Set<String>()
        for r in recipes { for t in r.tags { set.insert(t) } }
        return set.sorted()
    }

    private var favoriteCount: Int {
        recipes.lazy.filter(\.favorite).count
    }

    private var filtered: [Recipe] {
        let base: [Recipe]
        switch filter {
        case .all: base = recipes
        case .favorites: base = recipes.filter(\.favorite)
        case .tag(let tag): base = recipes.filter { $0.tags.contains(tag) }
        }
        switch sort {
        case .aToZ:
            // `@Query` already sorts by title; pass through.
            return base
        case .mostRecent:
            return base.sorted { $0.createdAt > $1.createdAt }
        }
    }
}

private struct FilterChip: View {
    let label: String
    let isActive: Bool
    let iconName: String?
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.xs) {
                if let iconName {
                    // Icon foregroundStyle is set explicitly so the
                    // heart can keep its accent fill on the inactive
                    // chip while the label text stays neutral.
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? AppColor.onAccent : accent)
                }
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive ? AppColor.onAccent : AppColor.textPrimary)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 2)
            .background(isActive ? accent : AppColor.surface)
            .overlay(
                Capsule().stroke(isActive ? accent : AppColor.divider, lineWidth: 1)
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
        .environment(CookingSession())
        .environment(EditorCoordinator())
        .environment(NavigationContext())
        .environment(AppearanceSettings())
        .environment(UserAccount())
        .environment(OwnerProfile())
        .environment(FriendsStore())
}

#Preview("Empty") {
    NavigationStack { LibraryView() }
        .modelContainer(previewContainer(populated: false))
        .environment(CookingSession())
        .environment(EditorCoordinator())
        .environment(NavigationContext())
        .environment(AppearanceSettings())
        .environment(UserAccount())
        .environment(OwnerProfile())
        .environment(FriendsStore())
}

@MainActor
private func previewContainer(populated: Bool) -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    // Declare every @Model type explicitly so the preview container
    // matches the live one in `LlamasCookbookApp` — SwiftData usually
    // auto-discovers `RecipePhoto` / `RecipeStepPhoto` via inverse
    // relationships, but listing them here keeps Previews from
    // crashing on a Mac if that auto-discovery ever drifts.
    let container = try! ModelContainer(
        for: Recipe.self, Ingredient.self, RecipeStep.self,
        RecipePhoto.self, RecipeStepPhoto.self,
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
