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
    /// Sort preference persisted via `@AppStorage` so the user's choice
    /// (A–Z vs. Most Recent) survives relaunches. Mirrors the same
    /// `@AppStorage`-string-with-enum-bridge pattern used elsewhere in
    /// the Library (see `hasSeenImportHelp` etc. — string-keyed
    /// UserDefaults is the established persistence channel for
    /// per-user UI state on this screen). `LibrarySort` is already
    /// `String`-backed; the `sort` computed property below decodes
    /// this string for read sites, and the All-chip context-menu
    /// writes the raw value directly.
    @AppStorage("library.sort.v1") private var sortRawValue: String = LibrarySort.aToZ.rawValue
    @State private var deletingRecipe: Recipe?
    @State private var showingAppearance = false
    @State private var showingProfile = false
    /// Bump-token consumed by `recipeList`'s ScrollViewReader to scroll
    /// the list back to its first row. Bumped by the All-chip "go
    /// home" tap. A counter (rather than a Bool) is used so repeated
    /// taps each register as a distinct value transition without a
    /// manual reset step.
    @State private var scrollToTopToken: Int = 0

    private var sort: LibrarySort {
        LibrarySort(rawValue: sortRawValue) ?? .aToZ
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            addButton
        }
        // Cream + faint mascot watermark behind everything. The
        // recipeList uses .scrollContentBackground(.hidden) so the
        // watermark peeks through; without the explicit background
        // the scroll area would fall through to the system colour.
        .llamaBackground()
        .navigationTitle(cookbookTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                CookbookHeader(
                    title: cookbookTitle,
                    accent: appearance.cookbookTitleAccentColor,
                    glowActive: appearance.isAccentGlowActive(.header)
                ) {
                    Button {
                        Haptics.selection()
                        showingAppearance = true
                    } label: {
                        // Sized down from 72 → 52 since the principal
                        // toolbar slot now coexists with a trailing
                        // profile button; the previous logo+title pair
                        // overflowed when the right side was occupied.
                        LlamaLogo(size: 52, shadowColor: appearance.cookbookTitleAccentColor)
                            .shadow(
                                color: appearance.cookbookTitleAccentColor.opacity(appearance.isAccentGlowActive(.header) ? 0.14 : 0),
                                radius: appearance.isAccentGlowActive(.header) ? 9 : 0
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Customize accent color")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.selection()
                    showingProfile = true
                } label: {
                    Image("Profile_Llama_Icon")
                        .renderingMode(.original)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 52, height: 52)
                        .opacity(userAccount.status.isSignedIn ? 1.0 : 0.45)
                        .shadow(color: appearance.cookbookTitleAccentColor.opacity(0.35), radius: 4, x: 0, y: 1)
                        .shadow(
                            color: appearance.cookbookTitleAccentColor.opacity(appearance.isAccentGlowActive(.header) ? 0.14 : 0),
                            radius: appearance.isAccentGlowActive(.header) ? 9 : 0
                        )
                }
                .accessibilityLabel("Profile")
                // The editor sheet is presented from RootView (parent
                // hierarchy), and the Profile sheet is presented from
                // LibraryView (child). iOS only allows one sheet per
                // presentation context, so tapping Profile while the
                // editor is minimized to its 80pt detent silently
                // no-ops — the user sees nothing happen. Greying out
                // the button when the editor is active gives honest
                // feedback that Profile is gated until the editor is
                // closed (Save / Cancel / discard).
                .disabled(editor.active != nil)
            }
        }
        .sheet(isPresented: $showingAppearance) {
            AccentColorPicker()
                .environment(appearance)
                .environment(userAccount)
                .presentationDetents([.large])
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
        .onChange(of: navContext.goHomeRequestedAt) { _, newValue in
            // "Go home" signal — written by the All chip and by a
            // bottom-nav Home re-tap. Run the local reset (filter +
            // scroll); RootView observes the same signal to clear the
            // nav path. No-op guard lives in `applyGoHomeReset`.
            guard newValue != nil else { return }
            applyGoHomeReset()
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
                ImportCountCache.clear(for: recipe.id)
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
                    // Spacing bumped slightly above AppSpacing.md so the
                    // focused card's 4% scale-up never visually overlaps
                    // its neighbors. Subtle on a still list; necessary
                    // mid-scroll.
                    LazyVStack(spacing: AppSpacing.md + 4) {
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
                            // Continuous scroll-focus zoom: the card
                            // closest to the scroll view's vertical
                            // center renders at 1.04, and cards above/
                            // below taper to 0.96 with a faint opacity
                            // dim. `.interactive` updates per-frame as
                            // the user drags.
                            .scrollTransition(.interactive, axis: .vertical) { content, phase in
                                let v = phase.value
                                let scale = 1.0 + 0.04 * (1 - abs(v)) - 0.04 * abs(v)
                                return content
                                    .scaleEffect(scale)
                                    .opacity(1.0 - 0.08 * abs(v))
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
                        accent: appearance.recipeListAccentColor,
                        glowActive: appearance.isAccentGlowActive(.recipeList),
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
            .onChange(of: scrollToTopToken) { _, _ in
                // "Go home" scroll-to-top — fired by the All chip and
                // by a re-tap of the active Home tab. Resets the user's
                // view to the first row so a tap from anywhere in a
                // long scroll lands them back at the top of the library.
                guard let first = filtered.first else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    proxy.scrollTo(first.id, anchor: .top)
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

    /// `#` (non-letter starts) at the top, then full A–Z. Always rendered
    /// so the strip has a consistent, filled-out look. Letters without any
    /// recipe are dimmed; tapping one scrolls to the next available letter
    /// — `#` falls through to A when no non-letter recipes exist.
    private static let allLetters: [String] = {
        let az = (0..<26).map { String(UnicodeScalar(UInt8(65 + $0))) }
        return ["#"] + az
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
        // The All chip is pinned outside the ScrollView so it stays
        // visible at the leading edge regardless of horizontal scroll
        // position; Favorites + tag chips scroll behind it as before.
        // Horizontal screen-margin padding is split between the outer
        // HStack (leading, for the All chip) and the inner HStack
        // (trailing, for the last scrolling chip) so the visual gutter
        // matches the previous single-ScrollView layout.
        HStack(spacing: AppSpacing.xs) {
            allChipMenu

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.xs) {
                    if favoriteCount > 0 {
                        FilterChip(
                            label: "Favorites  ·  \(favoriteCount)",
                            isActive: filter == .favorites,
                            iconName: "heart.fill",
                            accent: appearance.categoryAccentColor,
                            glowActive: appearance.isAccentGlowActive(.categories)
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
                            accent: appearance.categoryAccentColor,
                            glowActive: appearance.isAccentGlowActive(.categories)
                        ) {
                            filter = filter == .tag(tag) ? .all : .tag(tag)
                        }
                    }
                }
                .padding(.trailing, AppSpacing.lg)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .padding(.leading, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    /// "All" chip with a split interaction model:
    ///   • Tap → "go home": reset the filter to All, scroll the list to
    ///     the top, and pop the Library nav stack to root. No-op when
    ///     the user is already in the clean landing state.
    ///   • Long-press → sort picker (A–Z vs. Most Recent) via the
    ///     standard iOS `.contextMenu` (haptic + preview), matching
    ///     the long-press affordance recipe cards already use below.
    /// The chip carries a small `arrow.up.arrow.down` glyph so the
    /// long-press affordance is discoverable; the active sort gets a
    /// checkmark inside the menu.
    private var allChipMenu: some View {
        Button {
            handleAllChipTap()
        } label: {
            allChipLabel
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Haptics.selection()
                sortRawValue = LibrarySort.aToZ.rawValue
            } label: {
                Label(LibrarySort.aToZ.label,
                      systemImage: sort == .aToZ ? "checkmark" : LibrarySort.aToZ.iconName)
            }
            Button {
                Haptics.selection()
                sortRawValue = LibrarySort.mostRecent.rawValue
            } label: {
                Label(LibrarySort.mostRecent.label,
                      systemImage: sort == .mostRecent ? "checkmark" : LibrarySort.mostRecent.iconName)
            }
        }
    }

    /// Tap behaviour for the All chip. Fires the shared
    /// `goHomeRequestedAt` signal — `applyGoHomeReset` (run by the
    /// `.onChange` observer below) owns the reset logic and the no-op
    /// guard. Routing through the signal means the bottom-nav Home
    /// re-tap and the All chip share one code path and can't drift.
    private func handleAllChipTap() {
        navContext.goHomeRequestedAt = Date()
    }

    /// Shared "go home" reset, fired by both the All chip and the
    /// bottom-nav Home re-tap (via `goHomeRequestedAt`). Resets every
    /// piece of "where am I in the library" state so the user lands
    /// back on the clean landing view:
    ///   • filter → `.all`
    ///   • scroll position → top (via `scrollToTopToken` consumed by
    ///     the recipeList's ScrollViewReader)
    ///   • Library nav stack → root (via the same signal observed by
    ///     RootView, which owns `libraryPath`)
    ///
    /// Sort is *not* touched — `library.sort.v1` is a sticky user
    /// preference. The scroll-to-top fires unconditionally so a re-tap
    /// of the Home tab from deep in a long scroll lands at the top
    /// (matching the standard iOS scroll-to-top affordance) even when
    /// the filter is already All and the nav stack is at root. A
    /// redundant scroll on an already-top list is visually a no-op.
    private func applyGoHomeReset() {
        Haptics.selection()
        if filter != .all { filter = .all }
        scrollToTopToken &+= 1
    }

    /// Chip surface for the All chip — mirrors `FilterChip`'s look so
    /// the trigger sits in line with the other chips visually, but
    /// rendered as a label (the parent Button owns the tap).
    private var allChipLabel: some View {
        let isActive = filter == .all
        return HStack(spacing: AppSpacing.xs) {
            Text("All  ·  \(recipes.count)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? AppColor.onAccent : AppColor.textPrimary)
                .accentTextOutline()
            // Sort glyph (not a chevron) signals the long-press menu
            // is a *sort* picker rather than a generic dropdown — the
            // tap action is "go home", which the chip label itself
            // already implies.
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isActive ? AppColor.onAccent : appearance.categoryAccentColor)
                .accentTextOutline()
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.xs + 2)
        .background(isActive ? appearance.categoryAccentColor : AppColor.surface)
        .overlay(
            Capsule().stroke(isActive ? appearance.categoryAccentColor : AppColor.divider, lineWidth: 1)
        )
        .clipShape(Capsule())
        .shadow(
            color: appearance.categoryAccentColor.opacity(appearance.isAccentGlowActive(.categories) ? 0.10 : 0),
            radius: appearance.isAccentGlowActive(.categories) ? 7 : 0
        )
        .animation(.easeInOut(duration: 0.14), value: appearance.isAccentGlowActive(.categories))
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
            .foregroundStyle(appearance.recipeListAccentColor)
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
                editor.startImportFromTextLink()
            } label: {
                Label("Import From Text/Link", systemImage: "doc.on.clipboard")
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
                .accentTextOutline()
                .frame(width: 60, height: 60)
                // Vertical gradient + slight translucency reads as a
                // raised disc rather than a flat fill — paired with the
                // top-edge highlight stroke and double shadow below.
                .background(
                    LinearGradient(
                        colors: [
                            appearance.plusButtonAccentColor.opacity(0.95),
                            appearance.plusButtonAccentColor.opacity(0.80)
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
                .shadow(color: appearance.plusButtonAccentColor.opacity(0.35), radius: 14, y: 6)
                .shadow(
                    color: appearance.plusButtonAccentColor.opacity(appearance.isAccentGlowActive(.plusButton) ? 0.14 : 0),
                    radius: appearance.isAccentGlowActive(.plusButton) ? 16 : 0
                )
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

    private var cookbookTitle: String {
        StringCase.cookbookTitle(displayName: userAccount.status.identity?.displayName)
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
    let glowActive: Bool
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
                        .accentTextOutline()
                }
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive ? AppColor.onAccent : AppColor.textPrimary)
                    .accentTextOutline()
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 2)
            .background(isActive ? accent : AppColor.surface)
            .overlay(
                Capsule().stroke(isActive ? accent : AppColor.divider, lineWidth: 1)
            )
            .clipShape(Capsule())
            .shadow(color: accent.opacity(glowActive ? 0.10 : 0), radius: glowActive ? 7 : 0)
            .animation(.easeInOut(duration: 0.14), value: glowActive)
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
