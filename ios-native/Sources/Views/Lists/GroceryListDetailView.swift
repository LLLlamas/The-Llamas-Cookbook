import SwiftUI
import SwiftData

/// One grocery list, open for shopping. Items are grouped by aisle (the
/// llama's triage, Phase 4) in store-walk order; each row has its own
/// well-separated tap targets — an in-cart check circle (leading) and a
/// per-item "?" helper — so a stray tap never cross-fires (the minimized
/// Cook-Mode pill fall-through is the cautionary precedent).
///
/// Sharing, the on-device aisle triage, and the per-item "?" helper layer
/// on in later phases; this view already stands alone for a hand-built
/// list — add items from the bottom bar and check them off as you shop.
struct GroceryListDetailView: View {
    @Bindable var list: GroceryList

    @Environment(\.modelContext) private var modelContext
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(CookingSession.self) private var session
    @Environment(GroceryListStore.self) private var groceryStore
    @Environment(UserAccount.self) private var userAccount
    @Environment(OwnerProfile.self) private var ownerProfile
    @Environment(FriendsStore.self) private var friendsStore

    @State private var newItemName = ""
    @State private var showingRename = false
    @State private var renameText = ""
    /// Drives the "pick another name" alert when a rename is rejected by
    /// the profanity screen.
    @State private var nameRejected = false
    @State private var isTriaging = false
    @State private var helperItem: GroceryItem?
    /// The item whose helper sheet is open, retained across the sheet's
    /// own `item`-binding reset so `onDismiss` can push any note change to
    /// the cloud for a shared list.
    @State private var noteSyncItem: GroceryItem?
    @State private var showingShare = false
    @FocusState private var addFieldFocused: Bool

    private var accent: Color { appearance.cookbookTitleAccentColor }

    /// Trimmed, nil-if-empty new-item text. Used by both the add bar's
    /// enabled/opacity state and `addItem`, so the trim runs once per body
    /// pass instead of three inline copies.
    private var trimmedNewItem: String? { Optional(newItemName).trimmedIfNonEmpty }

    /// I own this list (vs. it being a mirror of a friend's shared list).
    /// Gates structural edits — only the owner adds/removes/renames; a
    /// recipient checks items off as they shop.
    private var isOwner: Bool { list.ownerIsMe }

    /// Best display name for stamping onto live pushes.
    private var myDisplayName: String {
        let signedIn = userAccount.status.identity?.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let signedIn, !signedIn.isEmpty { return signedIn }
        return ownerProfile.userName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Aisle sections in store-walk order. When nothing has been triaged
    /// yet (every item falls in "Other"), we render a single flat list
    /// without a header rather than a lone "Other" label.
    private var sections: [(aisle: String, items: [GroceryItem])] {
        GroceryAisle.group(list.sortedItems, aisleOf: \.aisle)
    }

    private var showsAisleHeaders: Bool { sections.count > 1 }

    /// Extra runway under the add-item bar so a minimized Cook-Mode pill
    /// (painted by `CookingPillsOverlay` over this tab's bottom edge)
    /// doesn't sit on top of the TextField + Add button. 70pt = pill
    /// (~54) + overlay gap (12) + air (4), matching the recipe-detail
    /// clearance documented in CLAUDE.md.
    private var cookPillClearance: CGFloat {
        (!session.activeCooks.isEmpty && !session.isCookModeVisible) ? 70 : 0
    }

    var body: some View {
        Group {
            if list.items.isEmpty {
                emptyState
            } else {
                itemList
            }
        }
        .llamaBackground()
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.inline)
        .tint(accent)
        .toolbar {
            if isOwner {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.selection()
                        showingShare = true
                    } label: {
                        Image(systemName: list.isShared ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    .accessibilityLabel(list.isShared ? "Manage sharing" : "Share list with a friend")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await sortByAisle() }
                        } label: {
                            Label("Sort by aisle", systemImage: "wand.and.stars")
                        }
                        .disabled(list.items.isEmpty)
                        Button {
                            renameText = list.name
                            showingRename = true
                        } label: {
                            Label("Rename list", systemImage: "pencil")
                        }
                        if list.isShared {
                            Divider()
                            Button(role: .destructive) {
                                Task { await groceryStore.unshare(list) }
                            } label: {
                                Label("Stop sharing", systemImage: "person.crop.circle.badge.xmark")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    .accessibilityLabel("List options")
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if list.isShared { sharedStatusBanner }
        }
        .safeAreaInset(edge: .bottom) {
            // Recipients shop the list (check items off) but don't edit its
            // structure — only the owner adds/removes rows.
            if isOwner { addItemBar }
        }
        .overlay { triagingOverlay }
        .task { await autoTriage() }
        .sheet(item: $helperItem, onDismiss: pushHelperNoteIfShared) { item in
            ItemHelperSheet(item: item)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environment(appearance)
        }
        .sheet(isPresented: $showingShare) {
            ShareGroceryListSheet(list: list, ownerName: myDisplayName)
                .environment(appearance)
                .environment(friendsStore)
                .environment(groceryStore)
        }
        .alert("Rename list", isPresented: $showingRename) {
            TextField("List name", text: $renameText)
            Button("Save") { renameList() }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Pick another name", isPresented: $nameRejected) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(ContentModeration.blockedMessage)
        }
    }

    /// Slim live-status banner. Owner sees who they shared with; a
    /// recipient sees who shared it to them — both with a pulsing dot to
    /// signal the list is syncing live.
    private var sharedStatusBanner: some View {
        HStack(spacing: AppSpacing.sm) {
            Circle()
                .fill(AppColor.success)
                .frame(width: 8, height: 8)
            Text(sharedStatusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var sharedStatusText: String {
        if isOwner {
            let who = list.sharedWithName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let who, !who.isEmpty { return "Shared with \(who) · syncing live" }
            return "Shared · syncing live"
        }
        let who = list.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let who, !who.isEmpty { return "Shared by \(who) · check items off as you shop" }
        return "Shared with you · check items off as you shop"
    }

    // MARK: - Item list

    private var itemList: some View {
        List {
            ForEach(sections, id: \.aisle) { section in
                Section {
                    ForEach(section.items) { item in
                        GroceryItemRow(
                            item: item,
                            accent: accent,
                            onToggleChecked: { toggleChecked(item) },
                            onToggleOutOfStock: { toggleOutOfStock(item) },
                            onHelp: {
                                helperItem = item
                                noteSyncItem = item
                            }
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: AppSpacing.lg, bottom: 3, trailing: AppSpacing.lg))
                        // Recipients shop the list (check off) but don't edit
                        // its structure — suppress swipe-to-delete for them, or
                        // a "deleted" row resurrects on the next owner sync.
                        .deleteDisabled(!isOwner)
                    }
                    .onDelete { offsets in deleteItems(section.items, at: offsets) }
                } header: {
                    if showsAisleHeaders {
                        Text(section.aisle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accent)
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Add-item bar

    private var addItemBar: some View {
        HStack(spacing: AppSpacing.sm) {
            TextField("Add an item", text: $newItemName)
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .focused($addFieldFocused)
                .onSubmit(addItem)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .background(AppColor.surface)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(AppColor.divider.opacity(0.6), lineWidth: 1))

            Button(action: addItem) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppColor.onAccent)
                    .accentTextOutline()
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.tint(accent).interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .disabled(trimmedNewItem == nil)
            .opacity(trimmedNewItem == nil ? 0.5 : 1)
            .accessibilityLabel("Add item")
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
        // Liquid Glass floating chrome (was `.regularMaterial`) so the
        // add-item bar reads consistently with the cook pills + tab bar.
        .glassEffect(.regular, in: Rectangle())
        .padding(.bottom, cookPillClearance)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "basket")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(accent.opacity(0.85))
                .accentTextOutline()
                .llamaFloat()
            Text("This list is empty")
                .font(AppFont.sectionHeading)
                .foregroundStyle(accent)
                .accentTextOutline()
            Text(emptyStateDetail)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Empty-state guidance. Owners get the "add it yourself" instructions;
    /// a recipient viewing an empty shared mirror has no add bar, so those
    /// instructions would be impossible to follow — give them a passive
    /// "nothing here yet" instead.
    private var emptyStateDetail: String {
        if isOwner {
            return "Add items below, or open a recipe and tap the basket on its ingredients to fill this list."
        }
        let who = list.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let who, !who.isEmpty {
            return "Nothing on this list yet — \(who) hasn't added items, or everything's been checked off."
        }
        return "Nothing on this list yet — the owner hasn't added items, or everything's been checked off."
    }

    // MARK: - Triaging overlay

    /// "Asking the llama…" scrim shown only when a manual aisle sort takes
    /// long enough to matter (1 s debounce inside `sortByAisle`). The silent
    /// auto-triage on appear never shows it.
    @ViewBuilder
    private var triagingOverlay: some View {
        if isTriaging {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: AppSpacing.md) {
                    LlamaProgressIndicator(size: 96, accent: accent)
                    Text("Asking the llama…")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .padding(AppSpacing.xl)
                .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            }
            .transition(.opacity)
        }
    }

    // MARK: - Triage

    /// Silent first-pass aisle classification of any never-triaged items
    /// (aisle == nil) — runs on appear so a list built from a recipe lands
    /// already grouped in store-walk order.
    private func autoTriage() async {
        // A recipient's mirror takes its aisle grouping from the owner's
        // authoritative metadata — don't run local triage that the next sync
        // would just overwrite (and that would fight the owner).
        guard isOwner || !list.isShared else { return }
        let untriaged = list.items.filter { $0.aisle == nil }
        guard !untriaged.isEmpty else { return }
        await applyTriage(to: untriaged)
        // If this is an owned shared list, push the freshly-grouped aisles.
        syncStructureIfShared()
    }

    /// User-initiated "Sort by aisle" — re-classifies every item's aisle,
    /// behind a 1 s overlay debounce so the instant heuristic path never
    /// flashes the scrim.
    private func sortByAisle() async {
        let items = list.sortedItems
        guard !items.isEmpty else { return }
        let overlay = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { isTriaging = true }
        }
        await applyTriage(to: items)
        overlay.cancel()
        isTriaging = false
        Haptics.success()
        // Aisle lives in the shared item metadata — re-upload so recipients
        // get the same store-walk grouping.
        syncStructureIfShared()
    }

    private func applyTriage(to items: [GroceryItem]) async {
        let result = await IngredientAssistant.triage(names: items.map(\.name))
        for (i, item) in items.enumerated() {
            if let aisle = result.aisleByIndex[i] { item.aisle = aisle }
        }
        list.touch()
    }

    // MARK: - Actions

    private func addItem() {
        guard let trimmed = trimmedNewItem else { return }
        let nextOrder = (list.items.map(\.order).max() ?? -1) + 1
        let item = GroceryItem(name: trimmed, order: nextOrder)
        modelContext.insert(item)
        item.list = list
        list.touch()
        newItemName = ""
        addFieldFocused = true
        Haptics.selection()
        // New row needs a cloud slot — re-upload the structure.
        syncStructureIfShared()
    }

    private func toggleChecked(_ item: GroceryItem) {
        item.isChecked.toggle()
        list.touch()
        Haptics.selection()
        // Live check-off: push just this item's slot to every participant.
        if list.isShared {
            Task { await groceryStore.pushCheck(item) }
        }
    }

    /// "!" — the shopper flags an item as can't-find / out of stock.
    /// The full helper sheet owns suggested substitutions; this quick toggle
    /// just records the state locally and clears any note when turned off.
    private func toggleOutOfStock(_ item: GroceryItem) {
        item.outOfStock.toggle()
        if !item.outOfStock {
            item.substitution = nil
        }
        list.touch()
        if item.outOfStock { Haptics.warning() } else { Haptics.selection() }
        if list.isShared {
            Task { await groceryStore.pushNote(item) }
        }
    }

    private func deleteItems(_ items: [GroceryItem], at offsets: IndexSet) {
        Haptics.impact(.rigid)
        for index in offsets {
            modelContext.delete(items[index])
        }
        list.touch()
        syncStructureIfShared()
    }

    private func renameList() {
        guard let trimmed = Optional(renameText).trimmedIfNonEmpty else { return }
        guard ContentModeration.isClean(trimmed) else {
            Haptics.warning()
            nameRejected = true
            return
        }
        list.name = trimmed
        list.touch()
        syncStructureIfShared()
    }

    /// Re-upload the full item set for an owned, shared list after a
    /// structural change (add/remove row, rename, re-sort).
    /// No-op for purely local lists or a recipient's mirror.
    private func syncStructureIfShared() {
        guard isOwner, list.isShared else { return }
        Task { await groceryStore.syncStructure(list, ownerName: myDisplayName) }
    }

    /// Push a note change made through the helper sheet ("they're out of
    /// oat milk") to the shared record, for the item that was open.
    private func pushHelperNoteIfShared() {
        guard list.isShared, let item = noteSyncItem else {
            noteSyncItem = nil
            return
        }
        let captured = item
        noteSyncItem = nil
        Task { await groceryStore.pushNote(captured) }
    }
}

/// One item row. The leading circle AND the central label both toggle the
/// check (so the user needn't hit the small circle); the trailing "?" helper
/// and "!" unavailable flag are separate bounded tap targets so taps don't
/// cross-fire. Checked items dim + strike through.
private struct GroceryItemRow: View {
    let item: GroceryItem
    let accent: Color
    let onToggleChecked: () -> Void
    let onToggleOutOfStock: () -> Void
    let onHelp: () -> Void

    private var display: MeasureDisplay { item.display() }

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            // Leading: in-cart check-off.
            Button(action: onToggleChecked) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(item.isChecked ? accent : AppColor.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isChecked ? "Uncheck \(item.name)" : "Check off \(item.name)")

            // Center: the whole name + measure column toggles the check too,
            // so the user needn't hit the little circle. The helper buttons
            // stay separate trailing tap targets.
            Button(action: onToggleChecked) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name.capitalized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(item.isChecked ? AppColor.textTertiary : AppColor.textPrimary)
                        .strikethrough(item.isChecked, color: AppColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    statusSubline
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isChecked ? "Uncheck \(item.name)" : "Check off \(item.name)")

            Button(action: onHelp) {
                Image(systemName: item.substitution == nil ? "questionmark.circle" : "questionmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(item.substitution == nil ? AppColor.textTertiary : AppColor.success)
                    .frame(width: 34, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("What is \(item.name)? Or mark unavailable")

            Button(action: onToggleOutOfStock) {
                Image(systemName: item.outOfStock ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(item.outOfStock ? AppColor.destructive : AppColor.textTertiary)
                    .frame(width: 34, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.outOfStock
                ? "Clear unavailable flag on \(item.name)"
                : "Flag \(item.name) as unavailable")
        }
        .padding(.vertical, 2)
    }

    /// Second line under the name: the chosen swap, an out-of-stock flag, or
    /// the measure — in that priority.
    @ViewBuilder
    private var statusSubline: some View {
        if let swap = item.substitution, !swap.isEmpty {
            Text("Swap: \(swap)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.success)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if item.outOfStock {
            Text("Couldn't find it")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.destructive)
        } else if !display.measure.isEmpty {
            Text(display.measure)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColor.textTertiary)
        }
    }
}

/// The "?" swap helper — a focused sheet showing the item, a confident
/// offline visual (`IngredientVisual`), curated common swaps
/// (`GrocerySwaps`), and a free-text field. Picking or writing a swap
/// stamps `GroceryItem.substitution` through the parent's `onApply`.
private struct GrocerySwapSheet: View {
    let item: GroceryItem
    let accent: Color
    let onApply: (String) -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var customSwap = ""

    private var suggestions: [GrocerySwaps.Suggestion] { GrocerySwaps.suggestions(for: item.name) }
    private var currentSwap: String { item.substitution ?? "" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    header
                    if !currentSwap.isEmpty { currentSwapCard }
                    suggestionsSection
                    customSection
                }
                .padding(AppSpacing.lg)
            }
            .llamaBackground()
            .navigationTitle("Find a swap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(spacing: AppSpacing.sm) {
            IngredientGlyphView(itemName: item.name, size: 76, accent: accent)
            Text(item.name.capitalized)
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.center)
            if item.outOfStock {
                Label("You flagged this as hard to find", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColor.destructive)
            }
        }
    }

    private var currentSwapCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("CURRENT SWAP")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppColor.textTertiary)
            HStack(alignment: .firstTextBaseline) {
                Text(currentSwap)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.success)
                Spacer(minLength: AppSpacing.sm)
                Button {
                    onClear()
                    dismiss()
                } label: {
                    Text("Clear")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColor.destructive)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(suggestions.isEmpty ? "Common swaps" : "Tap a swap to use it")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent)

            if suggestions.isEmpty {
                Text("No common swap on file for this one — write your own below.")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(suggestions) { suggestion in
                    Button {
                        onApply(suggestion.swap)
                        dismiss()
                    } label: {
                        suggestionRow(suggestion)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionRow(_ suggestion: GrocerySwaps.Suggestion) -> some View {
        HStack(spacing: AppSpacing.sm) {
            // A confident visual of the substitute ingredient when we have
            // one (curated, high-confidence only — never a wrong picture);
            // otherwise the swap-arrow glyph.
            if IngredientVisual.hasGlyph(for: suggestion.swap) {
                IngredientGlyphView(itemName: suggestion.swap, size: 34, accent: accent)
            } else {
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 34)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.swap)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .multilineTextAlignment(.leading)
                if let note = suggestion.note {
                    Text(note)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColor.textTertiary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppColor.textTertiary)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Or write your own")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent)
            HStack(spacing: AppSpacing.sm) {
                TextField("e.g. oat milk", text: $customSwap)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(commitCustom)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .background(AppColor.surface)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(AppColor.divider.opacity(0.6), lineWidth: 1))
                Button(action: commitCustom) {
                    Text("Save")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppColor.onAccent)
                        .padding(.horizontal, AppSpacing.md)
                        .frame(height: 40)
                        .glassEffect(.regular.tint(accent).interactive(), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(customSwap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(customSwap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitCustom() {
        let trimmed = customSwap.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onApply(trimmed)
        dismiss()
    }
}

/// Active = solid accent fill; inactive = Liquid Glass capsule. Mirrors
/// `LibraryView.ChipBackground` / `CategoryFilterStrip.ChipBackground` so
/// the grocery have/need toggle reads as the same chip vocabulary as the
/// rest of the app's inactive capsule chips.
private struct GlassChipBackground: ViewModifier {
    let isActive: Bool
    let accent: Color

    func body(content: Content) -> some View {
        if isActive {
            content.background(accent, in: Capsule())
        } else {
            content.glassEffect(.regular, in: Capsule())
        }
    }
}
