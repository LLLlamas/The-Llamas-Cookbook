import SwiftUI
import SwiftData

/// Grocery Lists tab. A grocery list combines ingredients from one or more
/// recipes (via a recipe's "Add to grocery list") plus anything hand-added,
/// then travels to the store — checked off in-app, on a shared web page, or
/// by a friend the list was shared with. This is the list-of-lists home;
/// tapping one pushes `GroceryListDetailView`.
///
/// Lists live in local SwiftData (`@Query`), newest-touched first. Creating
/// a list is a one-field prompt; deleting is a swipe. The feature is free —
/// no Pro gate.
struct ListsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(GroceryListStore.self) private var groceryStore

    /// Most-recently-touched first so the list someone's actively shopping
    /// floats to the top. Includes both lists the user owns and live
    /// mirrors of lists friends shared to them (`ownerIsMe == false`).
    @Query(sort: \GroceryList.updatedAt, order: .reverse)
    private var lists: [GroceryList]

    @State private var showingNewListPrompt = false
    @State private var newListName = ""
    /// Drives the "pick another name" alert when a list name is rejected
    /// by the profanity screen.
    @State private var nameRejected = false

    private var accent: Color { appearance.cookbookTitleAccentColor }

    var body: some View {
        Group {
            if lists.isEmpty {
                emptyState
            } else {
                listRows
            }
        }
        .llamaBackground()
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
        .tint(accent)
        .toolbar {
            ToolbarItem(placement: .principal) {
                CookbookHeader(
                    title: "Lists",
                    accent: accent,
                    glowActive: appearance.isAccentGlowActive(.header)
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.impact(.light)
                    newListName = ""
                    showingNewListPrompt = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accent)
                        .accentTextOutline()
                }
                .accessibilityLabel("New grocery list")
            }
        }
        .navigationDestination(for: GroceryList.self) { list in
            GroceryListDetailView(list: list)
        }
        .alert("New grocery list", isPresented: $showingNewListPrompt) {
            TextField("List name", text: $newListName)
            Button("Create", action: createList)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Name your list — like “Weekend Shop” or “Taco Night”.")
        }
        .alert("Pick another name", isPresented: $nameRejected) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(ContentModeration.blockedMessage)
        }
        .task {
            // Opening the tab clears the "something changed" dot and pulls a
            // fresh sync so shared lists land / update without waiting on a
            // push.
            groceryStore.markSharedSeen()
            await groceryStore.refresh()
        }
    }

    // MARK: - Rows

    private var listRows: some View {
        List {
            ForEach(Array(lists.enumerated()), id: \.element.id) { index, list in
                NavigationLink(value: list) {
                    GroceryListRow(list: list, index: index)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: AppSpacing.xs, trailing: AppSpacing.lg))
            }
            .onDelete(perform: deleteLists)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "checklist")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(accent.opacity(0.85))
                .accentTextOutline()
                .llamaFloat()
            Text("No grocery lists yet")
                .font(AppFont.sectionHeading)
                .foregroundStyle(accent)
                .accentTextOutline()
            Text("Build one from any recipe — tap the basket on its ingredients — or start a fresh list here.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
            Button {
                Haptics.impact(.light)
                newListName = ""
                showingNewListPrompt = true
            } label: {
                Label("New List", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.onAccent)
                    .accentTextOutline()
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.sm + 2)
                    .glassEffect(.regular.tint(accent).interactive(), in: Capsule())
                    .shadow(color: accent.opacity(0.35), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.top, AppSpacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func createList() {
        let name = Optional(newListName).trimmedIfNonEmpty ?? "Grocery List"
        guard ContentModeration.isClean(name) else {
            Haptics.warning()
            nameRejected = true
            return
        }
        let list = GroceryList(name: name)
        modelContext.insert(list)
        Haptics.success()
    }

    private func deleteLists(at offsets: IndexSet) {
        Haptics.impact(.rigid)
        for index in offsets {
            let list = lists[index]
            // Owned + shared → tear down the cloud record too, otherwise
            // recipients keep a ghost mirror that never resolves. (A
            // received mirror just gets removed locally; it reappears on
            // the next refresh while the owner still has it shared.)
            if list.ownerIsMe, let recordName = list.shareRecordName {
                Task.detached { try? await CloudGroceryListService.deleteShare(recordName: recordName) }
            }
            modelContext.delete(list)
        }
    }
}

/// One row in the lists-of-lists. Name, a compact "N items · M to buy"
/// summary, and the last-touched date — same muted-metadata vocabulary the
/// recipe and friend cards use.
private struct GroceryListRow: View {
    @Environment(AppearanceSettings.self) private var appearance
    let list: GroceryList
    /// Row position — drives the per-row accent-cascade stagger so the
    /// Lists tab retints top → bottom in lockstep with the Library list,
    /// exactly like `RecipeCardView`. Defaults to 0 so previews still build.
    var index: Int = 0

    /// Held during this row's cascade stagger window so the icon/title
    /// color advances at `recipeListFlipDelay + index * stagger` rather
    /// than flipping in unison. Mirrors `RecipeCardView.heldAccentOverride`.
    @State private var heldAccentOverride: Color? = nil
    @State private var glowActive = false

    private var itemCount: Int { list.items.count }
    private var toBuyCount: Int { list.toBuyCount }
    private var isAllSet: Bool { list.isAllSet }

    /// Design-system sage green — the canonical "done / good" tint.
    private var doneGreen: Color { AppColor.success }

    /// Cascade-aware accent (held old hue → new), matching the recipe list.
    private var accent: Color { heldAccentOverride ?? appearance.recipeListAccentColor }

    /// The row's lead tint: green once the list is fully shopped, accent
    /// otherwise. Drives the icon, the icon well, and the card border so
    /// the "all set" state reads as green at a glance from the list.
    private var leadTint: Color { isAllSet ? doneGreen : accent }

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(leadTint.opacity(0.14))
                Image(systemName: isAllSet ? "checkmark" : "basket.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(leadTint)
                    .shadow(color: leadTint.opacity(glowActive ? 0.20 : 0), radius: glowActive ? 7 : 0)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(list.name)
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: leadTint.opacity(glowActive ? 0.12 : 0), radius: glowActive ? 6 : 0)
                summaryView
                if let shared = sharedLine {
                    HStack(spacing: 3) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(shared)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                }
            }

            Spacer(minLength: 0)

            // Trailing: a prominent green "Done" badge once the list is
            // fully shopped (the unmistakable done marker), otherwise the
            // last-touched date.
            if isAllSet {
                doneBadge
            } else {
                Text(Formatters.date.string(from: list.updatedAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
        .padding(AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Done lists get a green-tinted card so they read as finished
            // at a glance, distinct from the cream of active lists.
            LinearGradient(
                colors: isAllSet
                    ? [doneGreen.opacity(0.16), doneGreen.opacity(0.06)]
                    : [AppColor.surfaceRaised.opacity(0.85), AppColor.surface.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(leadTint.opacity(isAllSet ? 0.55 : 0.18), lineWidth: isAllSet ? 1.5 : 1)
        )
        .liftedCard()
        .animation(.easeInOut(duration: 0.25), value: isAllSet)
        // Per-row staggered glow during an accent-color cascade — kicked by
        // the shared cascade token so the Lists tab ripples top → bottom.
        .onChange(of: appearance.recipeCardCascadeToken) { _, _ in
            scheduleStaggeredGlow()
        }
    }

    /// Bright "Done" pill — the explicit "this list is finished" marker.
    private var doneBadge: some View {
        Label("Done", systemImage: "checkmark.seal.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(AppColor.onAccent)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 4)
            .background(doneGreen, in: Capsule())
    }

    /// Item count plus shopping state. The "all set" case is green so a
    /// completed list reads as done from the list-of-lists.
    @ViewBuilder
    private var summaryView: some View {
        if itemCount == 0 {
            Text("Empty")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.textTertiary)
        } else if isAllSet {
            Label {
                Text("All set · \(itemCountLabel)")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(doneGreen)
        } else {
            Text("\(itemCountLabel) · \(toBuyCount) to buy")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.textTertiary)
        }
    }

    private var itemCountLabel: String {
        itemCount == 1 ? "1 item" : "\(itemCount) items"
    }

    /// Mirrors `RecipeCardView.scheduleStaggeredGlow` — seeds the prior
    /// accent immediately, then clears it (and pulses the glow) at
    /// `recipeListFlipDelay + index * stagger` for the top-down wave.
    private func scheduleStaggeredGlow() {
        let stagger = Double(index) * AppearanceSettings.recipeCardGlowStagger
        let flipDelay = AppearanceSettings.recipeListFlipDelay
        let hold = AppearanceSettings.recipeCardGlowHoldDuration
        if let previous = appearance.cascadePreviousAccentColor {
            heldAccentOverride = previous
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(flipDelay + stagger))
            withAnimation(.easeInOut(duration: 0.18)) {
                heldAccentOverride = nil
                glowActive = true
            }
            try? await Task.sleep(for: .seconds(hold))
            withAnimation(.easeInOut(duration: 0.14)) { glowActive = false }
        }
    }

    /// Sharing eyebrow — "Shared by Dad" on a received mirror, "Shared with
    /// Sam" on a list the user owns + shared. Nil for purely local lists.
    private var sharedLine: String? {
        guard list.isShared else { return nil }
        if list.ownerIsMe {
            let who = list.sharedWithName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let who, !who.isEmpty { return "Shared with \(who)" }
            return "Shared"
        }
        let who = list.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let who, !who.isEmpty { return "Shared by \(who)" }
        return "Shared with you"
    }
}

#Preview {
    NavigationStack { ListsView() }
        .modelContainer(for: [GroceryList.self, GroceryItem.self], inMemory: true)
        .environment(AppearanceSettings())
        .environment(GroceryListStore())
}
