import SwiftUI
import SwiftData

/// One grocery list, open for shopping. Items are grouped by aisle (the
/// llama's triage, Phase 4) in store-walk order; each row has its own
/// well-separated tap targets — an in-cart check circle (leading) and a
/// have/need toggle (trailing) — so a stray tap never cross-fires (the
/// minimized Cook-Mode pill fall-through is the cautionary precedent).
///
/// Sharing, the on-device aisle triage, and the per-item "?" helper layer
/// on in later phases; this view already stands alone for a hand-built
/// list — add items from the bottom bar, check them off, mark have/need.
struct GroceryListDetailView: View {
    @Bindable var list: GroceryList

    @Environment(\.modelContext) private var modelContext
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(CookingSession.self) private var session

    @State private var newItemName = ""
    @State private var showingRename = false
    @State private var renameText = ""
    @FocusState private var addFieldFocused: Bool

    private var accent: Color { appearance.cookbookTitleAccentColor }

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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = list.name
                        showingRename = true
                    } label: {
                        Label("Rename list", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("List options")
            }
        }
        .safeAreaInset(edge: .bottom) { addItemBar }
        .alert("Rename list", isPresented: $showingRename) {
            TextField("List name", text: $renameText)
            Button("Save") { renameList() }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Item list

    private var itemList: some View {
        List {
            ForEach(sections, id: \.aisle) { section in
                Section {
                    ForEach(section.items) { item in
                        GroceryItemRow(item: item, accent: accent) {
                            toggleChecked(item)
                        } onToggleNeeded: {
                            toggleNeeded(item)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: AppSpacing.lg, bottom: 3, trailing: AppSpacing.lg))
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
                    .frame(width: 40, height: 40)
                    .background(accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .disabled(newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            .accessibilityLabel("Add item")
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
        .background(.regularMaterial)
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
            Text("Add items below, or open a recipe and tap the basket on its ingredients to fill this list.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func addItem() {
        let trimmed = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let nextOrder = (list.items.map(\.order).max() ?? -1) + 1
        let item = GroceryItem(name: trimmed, order: nextOrder)
        modelContext.insert(item)
        item.list = list
        list.touch()
        newItemName = ""
        addFieldFocused = true
        Haptics.selection()
    }

    private func toggleChecked(_ item: GroceryItem) {
        item.isChecked.toggle()
        list.touch()
        Haptics.selection()
    }

    private func toggleNeeded(_ item: GroceryItem) {
        item.needed.toggle()
        list.touch()
        Haptics.impact(.light)
    }

    private func deleteItems(_ items: [GroceryItem], at offsets: IndexSet) {
        Haptics.impact(.rigid)
        for index in offsets {
            modelContext.delete(items[index])
        }
        list.touch()
    }

    private func renameList() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        list.name = trimmed
        list.touch()
    }
}

/// One item row. Three deliberately separate hit zones — the leading
/// check circle, the central label, and the trailing have/need toggle —
/// each with its own bounded `contentShape` and ≥ 44 pt target so taps
/// don't cross-fire. Checked items dim + strike through; "have" items
/// (not needed) read muted with a small "Have" tag.
private struct GroceryItemRow: View {
    let item: GroceryItem
    let accent: Color
    let onToggleChecked: () -> Void
    let onToggleNeeded: () -> Void

    private var display: MeasureDisplay { item.display() }

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
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

            // Center: measure + name. Non-interactive label.
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name.capitalized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(item.isChecked ? AppColor.textTertiary : AppColor.textPrimary)
                    .strikethrough(item.isChecked, color: AppColor.textTertiary)
                    .lineLimit(2)
                if !display.measure.isEmpty {
                    Text(display.measure)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColor.textTertiary)
                }
            }
            .opacity(item.needed ? 1 : 0.55)

            Spacer(minLength: AppSpacing.sm)

            // Trailing: have/need toggle, its own bounded target.
            Button(action: onToggleNeeded) {
                Text(item.needed ? "Need" : "Have")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(item.needed ? AppColor.onAccent : AppColor.textSecondary)
                    .padding(.horizontal, AppSpacing.sm)
                    .frame(minWidth: 52, minHeight: 32)
                    .background(item.needed ? accent : AppColor.surface)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(AppColor.divider.opacity(item.needed ? 0 : 0.6), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.needed ? "Mark \(item.name) as already have" : "Mark \(item.name) as needed")
        }
        .padding(.vertical, 2)
    }
}
