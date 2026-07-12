import SwiftUI

/// Editor for store profiles — the named stores whose custom aisle walk
/// orders the grocery detail view's store picker offers. Level 1 lists the
/// stores (create from a chain template or the default order, rename,
/// delete); level 2 drag-reorders the 22 aisles to match how the user
/// actually walks that store. All device-local (see `StoreProfileStore`).
struct StoreLayoutsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(StoreProfileStore.self) private var storeProfiles

    /// Aisle order the pending new store should seed from — a chain
    /// template's walk, or nil for the canonical default ("Blank").
    @State private var pendingTemplateOrder: [String]?
    @State private var newStoreName = ""
    @State private var showingTemplatePicker = false
    @State private var showingNameAlert = false
    @State private var nameRejected = false
    @State private var renameTarget: StoreProfile?
    @State private var renameText = ""

    private var accent: Color { appearance.cookbookTitleAccentColor }

    var body: some View {
        NavigationStack {
            Group {
                if storeProfiles.profiles.isEmpty {
                    emptyState
                } else {
                    storeList
                }
            }
            .llamaBackground()
            .navigationTitle("My stores")
            .navigationBarTitleDisplayMode(.inline)
            .tint(accent)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.selection()
                        showingTemplatePicker = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    .accessibilityLabel("Add a store")
                }
            }
            .confirmationDialog(
                "Start from a typical layout",
                isPresented: $showingTemplatePicker,
                titleVisibility: .visible
            ) {
                ForEach(StoreTemplate.all) { template in
                    Button(template.name) {
                        pendingTemplateOrder = template.order
                        newStoreName = template.name
                        showingNameAlert = true
                    }
                }
                Button("Blank (default order)") {
                    pendingTemplateOrder = nil
                    newStoreName = ""
                    showingNameAlert = true
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Layouts vary by location — pick the closest match, then drag aisles into your store's order.")
            }
            .alert("Name this store", isPresented: $showingNameAlert) {
                TextField("Store name", text: $newStoreName)
                Button("Add") { addStore() }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Rename store", isPresented: renameAlertBinding) {
                TextField("Store name", text: $renameText)
                Button("Save") { renameStore() }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Pick another name", isPresented: $nameRejected) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(ContentModeration.blockedMessage)
            }
        }
    }

    // MARK: - Store list

    private var storeList: some View {
        List {
            ForEach(storeProfiles.profiles) { profile in
                NavigationLink {
                    StoreAisleOrderView(profileID: profile.id)
                        .environment(appearance)
                        .environment(storeProfiles)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("Tap to arrange aisles")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppColor.textTertiary)
                    }
                }
                .listRowBackground(Color.clear)
                .contextMenu {
                    Button {
                        renameText = profile.name
                        renameTarget = profile
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        deleteStore(profile.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    deleteStore(storeProfiles.profiles[index].id)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "storefront")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(accent.opacity(0.85))
                .accentTextOutline()
                .llamaFloat()
            Text("No stores yet")
                .font(AppFont.sectionHeading)
                .foregroundStyle(accent)
                .accentTextOutline()
            Text("Add the stores you shop at and arrange their aisles in walking order — your lists will route you straight through, no doubling back.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private func addStore() {
        guard let trimmed = Optional(newStoreName).trimmedIfNonEmpty else { return }
        guard ContentModeration.isClean(trimmed) else {
            Haptics.warning()
            nameRejected = true
            return
        }
        storeProfiles.add(
            named: trimmed,
            aisleOrder: pendingTemplateOrder ?? GroceryAisle.ordered
        )
        pendingTemplateOrder = nil
        newStoreName = ""
        Haptics.success()
    }

    private func renameStore() {
        guard let target = renameTarget else { return }
        renameTarget = nil
        guard let trimmed = Optional(renameText).trimmedIfNonEmpty else { return }
        guard ContentModeration.isClean(trimmed) else {
            Haptics.warning()
            nameRejected = true
            return
        }
        storeProfiles.rename(target.id, to: trimmed)
        Haptics.selection()
    }

    private func deleteStore(_ id: UUID) {
        Haptics.impact(.rigid)
        storeProfiles.delete(id)
    }
}

/// Level 2: drag the aisles into the order they appear in this store.
/// Every move persists immediately; lists assigned to this store reshuffle
/// the next time they're on screen.
private struct StoreAisleOrderView: View {
    let profileID: UUID

    @Environment(AppearanceSettings.self) private var appearance
    @Environment(StoreProfileStore.self) private var storeProfiles

    private var accent: Color { appearance.cookbookTitleAccentColor }

    private var profile: StoreProfile? {
        storeProfiles.profiles.first { $0.id == profileID }
    }

    /// Healed walk order — tolerant of profiles saved before a taxonomy
    /// change, and of the profile being deleted out from under the view.
    private var order: [String] {
        GroceryAisle.resolvedOrder(profile?.aisleOrder ?? GroceryAisle.ordered)
    }

    var body: some View {
        List {
            Text("Drag aisles into the order you walk them — the first aisle you hit at the door goes on top.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColor.textSecondary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .moveDisabled(true)
                .deleteDisabled(true)
            ForEach(Array(order.enumerated()), id: \.element) { pair in
                HStack(spacing: AppSpacing.sm) {
                    Text("\(pair.offset + 1)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent)
                        .frame(width: 24, alignment: .trailing)
                    Text(pair.element)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                }
                .listRowBackground(Color.clear)
            }
            .onMove { offsets, destination in
                moveAisles(from: offsets, to: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Always-active edit mode so the drag handles are visible without a
        // separate Edit toggle — reordering is this screen's whole job.
        .environment(\.editMode, .constant(.active))
        .llamaBackground()
        .navigationTitle(profile?.name ?? "Store layout")
        .navigationBarTitleDisplayMode(.inline)
        .tint(accent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reset") {
                    Haptics.selection()
                    storeProfiles.setAisleOrder(GroceryAisle.ordered, for: profileID)
                }
                .foregroundStyle(accent)
                .accessibilityLabel("Reset to the default aisle order")
            }
        }
    }

    private func moveAisles(from offsets: IndexSet, to destination: Int) {
        var updated = order
        updated.move(fromOffsets: offsets, toOffset: destination)
        storeProfiles.setAisleOrder(updated, for: profileID)
        Haptics.selection()
    }
}
