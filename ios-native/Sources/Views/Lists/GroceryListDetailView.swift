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
    @Environment(StoreProfileStore.self) private var storeProfiles

    @State private var newItemName = ""
    @State private var showingStoreEditor = false
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
    @State private var noteSyncInitialAvailability: AvailabilitySnapshot?
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

    /// Aisle sections in store-walk order — canonical, or the assigned
    /// store profile's custom walk. Items are alphabetized within each
    /// section (display-only: `GroceryItem.order` is load-bearing for the
    /// CloudKit share-slot mapping and is never rewritten). When nothing
    /// has been triaged yet (every item falls in "Other"), we render a
    /// single flat list without a header rather than a lone "Other" label.
    private var sections: [(aisle: String, items: [GroceryItem])] {
        let alphabetized = list.sortedItems.sorted { a, b in
            let cmp = a.name.localizedCaseInsensitiveCompare(b.name)
            // Explicit `order` tie-break — Swift's sort isn't stable.
            if cmp == .orderedSame { return a.order < b.order }
            return cmp == .orderedAscending
        }
        return GroceryAisle.group(alphabetized, order: activeAisleOrder, aisleOf: \.aisle)
    }

    /// The assigned store profile's healed walk order, or nil for the
    /// canonical default. A stale assignment (deleted store) resolves to
    /// nil inside the store, so this can't dangle.
    private var activeAisleOrder: [String]? {
        storeProfiles.aisleOrder(forList: list.id)
    }

    /// Store-picker selection for the toolbar menu. Setting reshuffles the
    /// aisle sections in place (List diffing animates the move).
    private var storeSelection: Binding<UUID?> {
        Binding(
            get: { storeProfiles.assignedStoreID(forList: list.id) },
            set: { newValue in
                Haptics.selection()
                withAnimation(.easeInOut(duration: 0.3)) {
                    storeProfiles.assign(newValue, toList: list.id)
                }
            }
        )
    }

    private var liveSyncKey: String {
        "\(list.id.uuidString)|\(list.shareRecordName ?? "local")"
    }

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
                GroceryEmptyState(
                    isOwner: isOwner,
                    ownerName: list.ownerName,
                    accent: accent
                )
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
            }
            // The overflow menu shows for recipients too — the store-layout
            // pick is a per-device viewing preference (each shopper walks
            // their own store), while the structural actions inside stay
            // owner-gated.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Store layout", selection: storeSelection) {
                        Label("Default order", systemImage: "list.bullet")
                            .tag(UUID?.none)
                        ForEach(storeProfiles.profiles) { profile in
                            Text(profile.name).tag(UUID?.some(profile.id))
                        }
                    }
                    Button {
                        Haptics.selection()
                        showingStoreEditor = true
                    } label: {
                        Label("Edit stores…", systemImage: "storefront")
                    }
                    if isOwner {
                        Divider()
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
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("List options")
            }
        }
        .safeAreaInset(edge: .top) {
            if list.isShared {
                GroceryShareStatusBanner(
                    isOwner: isOwner,
                    sharedWithName: list.sharedWithName,
                    ownerName: list.ownerName,
                    accent: accent
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Recipients shop the list (check items off) but don't edit its
            // structure — only the owner adds/removes rows.
            if isOwner { addItemBar }
        }
        .overlay {
            if isTriaging { GroceryTriagingOverlay(accent: accent) }
        }
        .task(id: liveSyncKey) {
            // Sync FIRST and alone. This used to run `await autoTriage()`
            // ahead of the sync, and the sync's own first line awaited the
            // notification-permission prompt — so the first fetch sat behind
            // an on-device model round trip AND a modal system alert. On the
            // owner's phone, opening a freshly-built list meant the shopper's
            // changes didn't appear until triage finished.
            await runVisibleSharedListSync()
        }
        .task(id: liveSyncKey) {
            await autoTriage()
        }
        .task(id: liveSyncKey) {
            // Off the sync path deliberately: this can block on a modal
            // system alert. No-ops after the first answer either way.
            guard list.isShared else { return }
            await CloudKitSubscriptions.requestVisibleNotificationAuthorizationIfNeeded()
        }
        // Push-driven updates land via GroceryListStore.observeRemotePushes
        // (its refresh() reconciles this list too) — no per-view push fetch.
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
        .sheet(isPresented: $showingStoreEditor) {
            StoreLayoutsView()
                .environment(appearance)
                .environment(storeProfiles)
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

    // MARK: - Item list

    private var itemList: some View {
        // Hoisted once per body pass — `sections` sorts + groups on every
        // access, and it's read by the ForEach and each section's header gate.
        let sections = self.sections
        let showsAisleHeaders = sections.count > 1
        return List {
            ForEach(sections, id: \.aisle) { section in
                // The aisle title is emitted as the FIRST scrolling row of its
                // section (not a `Section`/`header:`), so plain List can't pin
                // it to the top — it scrolls away like any other row instead of
                // overlapping content as the user scrolls. The `showsAisleHeaders`
                // gate keeps a lone "Other" group label-free.
                if showsAisleHeaders {
                    Text(section.aisle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent)
                        .textCase(nil)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: AppSpacing.xs, leading: AppSpacing.lg, bottom: 1, trailing: AppSpacing.lg))
                        .deleteDisabled(true)
                }
                ForEach(section.items) { item in
                    GroceryItemRow(
                        item: item,
                        accent: accent,
                        onToggleChecked: { toggleChecked(item) },
                        onToggleOutOfStock: { toggleOutOfStock(item) },
                        onHelp: {
                            helperItem = item
                            noteSyncItem = item
                            noteSyncInitialAvailability = AvailabilitySnapshot(item)
                        }
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: AppSpacing.lg, bottom: 1, trailing: AppSpacing.lg))
                    // Recipients shop the list (check off) but don't edit
                    // its structure — suppress swipe-to-delete for them, or
                    // a "deleted" row resurrects on the next owner sync.
                    .deleteDisabled(!isOwner)
                }
                .onDelete { offsets in deleteItems(section.items, at: offsets) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Add-item bar

    private var addItemBar: some View {
        // A floating, inset control — NOT an edge-to-edge docked strip, which
        // read as a second nav bar stacked on the OS tab bar. The field and
        // the "+" share ONE `GlassEffectContainer` (mirroring the cook-pills
        // bar — the repo's reference for the API) so they sample a shared
        // backdrop and fuse into a single cohesive glass surface.
        GlassEffectContainer(spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                TextField("Add an item", text: $newItemName)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .focused($addFieldFocused)
                    .onSubmit(addItem)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm + 2)
                    .glassEffect(.regular, in: Capsule())

                Button(action: addItem) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppColor.onAccent)
                        .accentTextOutline()
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.tint(accent).interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .disabled(trimmedNewItem == nil)
                .opacity(trimmedNewItem == nil ? 0.5 : 1)
                .accessibilityLabel("Add item")
            }
        }
        // Inset from the screen edges so it floats clear of the tab bar with
        // breathing room — a deliberate "add" control, not a docked bar.
        .padding(.horizontal, AppSpacing.lg)
        .padding(.bottom, AppSpacing.sm + cookPillClearance)
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

    /// Keep the currently-open shared list fresh. CloudKit pushes should
    /// usually drive this immediately; the short single-record polling loop
    /// covers delayed/missed pushes without forcing the user to leave Detail
    /// and re-enter the Lists tab to trigger its broader refresh.
    private func runVisibleSharedListSync() async {
        guard list.isShared else { return }
        var ok = await groceryStore.refreshSharedList(list)
        // Tight polls while the list is actually on screen, then back off.
        //
        // Pushes are nominally the primary channel, but the OWNER's grocery
        // subscription is content-available only (no banner, by design —
        // most updates on your own record are your own edits), and iOS
        // throttles silent pushes hard. So for the person watching a shopper
        // tick items off, this loop is often what actually delivers the
        // update, not the push. At 8 s that read as laggy; 3 s lands close
        // enough to feel live. Each poll is one `record(for:)` on a known
        // record name — cheap enough to run at this cadence for the couple
        // of minutes a detail view is realistically open.
        //
        // The backoff still matters, but 30 s was too deep for a screen the
        // user is actively watching: after 20 polls the only working channel
        // became a 30 s heartbeat, and `polls` never reset while the view
        // stayed pushed. That is precisely why backing out and re-entering
        // "fixed" it — re-entry restarts this task, which refetches
        // immediately and resets the counter. 10 s is a ceiling you can
        // stand in front of.
        //
        // A failed fetch backs off separately and much harder: a
        // rate-limited container should not be polled every 3 s.
        var polls = 0
        var failures = 0
        while !Task.isCancelled {
            let interval = ok ? Self.visiblePollInterval(afterPolls: polls)
                              : Self.failureBackoff(afterFailures: failures)
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, list.isShared else { return }
            ok = await groceryStore.refreshSharedList(list)
            if ok {
                failures = 0
                polls += 1
            } else {
                failures += 1
            }
        }
    }

    /// Ceiling for the healthy on-screen poll. The user is looking at the
    /// screen; anything slower reads as "not live".
    static let maxVisiblePollInterval: Double = 10

    /// Healthy-path cadence: 3 s while the list is fresh on screen, easing
    /// to the ceiling for a list left open on a counter all afternoon.
    static func visiblePollInterval(afterPolls polls: Int) -> Double {
        min(3 + Double(polls / 20) * 7, maxVisiblePollInterval)
    }

    /// Exponential-ish backoff for a failing fetch, capped so the loop still
    /// recovers on its own once the container stops rejecting us.
    static func failureBackoff(afterFailures failures: Int) -> Double {
        min(5 * pow(2, Double(min(failures, 4))), 60)
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
        // Checking off gets a soft, weighty thump to pair with the row's
        // stamp/poof/sweep celebration; unchecking stays a plain tick.
        // Local taps only — remote flips animate but never buzz the phone.
        if item.isChecked {
            Haptics.impact(.soft)
        } else {
            Haptics.selection()
        }
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
            Task { await groceryStore.pushNote(item, notifyOwner: item.outOfStock) }
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
        groceryStore.syncStructureDebounced(list, ownerName: myDisplayName)
    }

    /// Push a note change made through the helper sheet ("they're out of
    /// oat milk") to the shared record, for the item that was open.
    private func pushHelperNoteIfShared() {
        guard let item = noteSyncItem else {
            noteSyncItem = nil
            noteSyncInitialAvailability = nil
            return
        }
        let captured = item
        let current = AvailabilitySnapshot(captured)
        let changed = noteSyncInitialAvailability != current
        noteSyncItem = nil
        noteSyncInitialAvailability = nil
        guard changed else { return }
        list.touch()
        guard list.isShared else { return }
        Task {
            await groceryStore.pushNote(
                captured,
                notifyOwner: current.outOfStock
            )
        }
    }
}

private struct AvailabilitySnapshot: Equatable {
    let outOfStock: Bool
    let substitution: String?

    init(_ item: GroceryItem) {
        outOfStock = item.outOfStock
        substitution = item.substitution.trimmedIfNonEmpty
    }
}

// (Removed `GrocerySwapSheet` + `GlassChipBackground` — superseded by the
// live "?" helper and the separate "!" unavailable flag. The have/need axis
// was dropped.)
