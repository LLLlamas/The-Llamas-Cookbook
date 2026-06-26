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
    /// Drives the "pick another name" alert when a rename is rejected by
    /// the profanity screen.
    @State private var nameRejected = false
    /// Item whose "?" swap helper sheet is open, if any.
    @State private var swapSheetItem: GroceryItem?
    @FocusState private var addFieldFocused: Bool

    private var accent: Color { appearance.cookbookTitleAccentColor }

    /// Trimmed, nil-if-empty new-item text. Used by both the add bar's
    /// enabled/opacity state and `addItem`, so the trim runs once per body
    /// pass instead of three inline copies.
    private var trimmedNewItem: String? { Optional(newItemName).trimmedIfNonEmpty }

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
        .alert("Pick another name", isPresented: $nameRejected) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(ContentModeration.blockedMessage)
        }
        .sheet(item: $swapSheetItem) { sheetItem in
            GrocerySwapSheet(
                item: sheetItem,
                accent: accent,
                onApply: { applySwap(sheetItem, $0) },
                onClear: { clearSwap(sheetItem) }
            )
        }
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
                            onToggleNeeded: { toggleNeeded(item) },
                            onToggleOutOfStock: { toggleOutOfStock(item) },
                            onTapSwap: { swapSheetItem = item }
                        )
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
        guard let trimmed = trimmedNewItem else { return }
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

    /// "!" — the shopper flags an item as can't-find / out of stock. Local
    /// today; once grocery-list sharing/sync ships this is what surfaces a
    /// substitution request to the list owner.
    private func toggleOutOfStock(_ item: GroceryItem) {
        item.outOfStock.toggle()
        list.touch()
        if item.outOfStock { Haptics.warning() } else { Haptics.selection() }
    }

    /// "?" swap helper applied a substitution (curated or hand-written).
    private func applySwap(_ item: GroceryItem, _ swap: String) {
        item.substitution = Optional(swap).trimmedIfNonEmpty
        list.touch()
        Haptics.success()
    }

    private func clearSwap(_ item: GroceryItem) {
        item.substitution = nil
        list.touch()
        Haptics.selection()
    }

    private func deleteItems(_ items: [GroceryItem], at offsets: IndexSet) {
        Haptics.impact(.rigid)
        for index in offsets {
            modelContext.delete(items[index])
        }
        list.touch()
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
    }
}

/// One item row. Deliberately separate, bounded hit zones so taps never
/// cross-fire (the minimized Cook-Mode pill fall-through is the cautionary
/// precedent): the leading in-cart check circle, the central label, and a
/// trailing cluster of three — the "?" swap helper, the "!" can't-find
/// flag, and the have/need toggle. Checked items dim + strike through;
/// "have" items (not needed) read muted. A set substitution shows a green
/// "Swap: …" line; an unanswered out-of-stock flag shows a "Couldn't find
/// it" line.
private struct GroceryItemRow: View {
    let item: GroceryItem
    let accent: Color
    let onToggleChecked: () -> Void
    let onToggleNeeded: () -> Void
    let onToggleOutOfStock: () -> Void
    let onTapSwap: () -> Void

    private var display: MeasureDisplay { item.display() }
    private var swap: String { item.substitution ?? "" }
    private var hasSwap: Bool { !swap.isEmpty }

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

            // Center: measure + name + swap / can't-find state. Non-interactive.
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
                if hasSwap {
                    Label("Swap: \(swap)", systemImage: "arrow.2.squarepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColor.success)
                        .lineLimit(1)
                } else if item.outOfStock {
                    Label("Couldn't find it", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColor.destructive)
                }
            }
            .opacity(item.needed ? 1 : 0.55)

            Spacer(minLength: AppSpacing.xs)

            // Trailing cluster: swap helper "?" and can't-find "!" sit side
            // by side (both always visible — no tap-to-reveal), then the
            // have/need toggle. Each its own bounded target.
            HStack(spacing: 2) {
                Button(action: onTapSwap) {
                    Image(systemName: hasSwap ? "questionmark.circle.fill" : "questionmark.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(hasSwap ? AppColor.success : accent.opacity(0.8))
                        .frame(width: 34, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Find a swap for \(item.name)")

                Button(action: onToggleOutOfStock) {
                    Image(systemName: item.outOfStock ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(item.outOfStock ? AppColor.destructive : AppColor.textTertiary)
                        .frame(width: 34, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.outOfStock
                    ? "Clear can't-find flag on \(item.name)"
                    : "Flag \(item.name) as can't find or out of stock")

                Button(action: onToggleNeeded) {
                    Text(item.needed ? "Need" : "Have")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(item.needed ? AppColor.onAccent : AppColor.textSecondary)
                        .padding(.horizontal, AppSpacing.sm)
                        .frame(minWidth: 50, minHeight: 32)
                        .modifier(GlassChipBackground(isActive: item.needed, accent: accent))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.needed ? "Mark \(item.name) as already have" : "Mark \(item.name) as needed")
            }
        }
        .padding(.vertical, 2)
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
