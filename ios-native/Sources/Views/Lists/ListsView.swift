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
                ) {
                    Image(systemName: "checklist")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(accent)
                        .accentTextOutline()
                }
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
            ForEach(lists) { list in
                NavigationLink(value: list) {
                    GroceryListRow(list: list, accent: accent)
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
                    .background(accent)
                    .clipShape(Capsule())
                    .shadow(color: accent.opacity(0.35), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.top, AppSpacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func createList() {
        let trimmed = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Grocery List" : trimmed
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
    let list: GroceryList
    let accent: Color

    private var itemCount: Int { list.items.count }
    private var toBuyCount: Int { list.items.filter { $0.needed && !$0.isChecked }.count }

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "basket.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 40, height: 40)
                .background(accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))

            VStack(alignment: .leading, spacing: 2) {
                Text(list.name)
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(summaryLine)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
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

            Text(Formatters.date.string(from: list.updatedAt))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.textTertiary)
        }
        .padding(AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [AppColor.surfaceRaised.opacity(0.85), AppColor.surface.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(accent.opacity(0.18), lineWidth: 1)
        )
        .liftedCard()
    }

    private var summaryLine: String {
        if itemCount == 0 { return "Empty" }
        let items = itemCount == 1 ? "1 item" : "\(itemCount) items"
        if toBuyCount == 0 { return "\(items) · all set" }
        return "\(items) · \(toBuyCount) to buy"
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
