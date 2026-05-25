import SwiftUI

/// Sheet listing every friend who has imported one of the local
/// user's own recipes. Reached from the "Imported by N" chip on
/// `RecipeDetailView`. Each row: importer display name + relative
/// import date, sorted newest first.
///
/// **Why a separate sheet rather than a popover.** The list can
/// have 0 entries (nobody yet), 1 entry, or many — sheet detents
/// (`.medium` / `.large`) handle the dynamic content height
/// gracefully and stay readable at any size. Popovers cap content
/// height awkwardly on iPhone.
///
/// **Read-only — no actions.** v1 just shows the list. Future
/// enhancements (deep-link into the importer's friend library if
/// they're a current friend, "thank" affordance, etc.) deferred.
///
/// **Network etiquette.** The sheet does its own fetch on appear
/// rather than relying on `ImportCountCache` — that cache holds
/// just the count, not the per-row identities.
/// `LlamaProgressIndicator` covers the load, with a graceful
/// empty-state for "nobody yet" and an error state for CK
/// failures.
struct ImportersListSheet: View {
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(FriendsStore.self) private var friendsStore
    @Environment(\.dismiss) private var dismiss

    /// Chain-root recipe id — the query field. For own-authored
    /// recipes, callers pass `recipe.id.uuidString` (since
    /// `originalRecipeID` is nil for these). For imported
    /// recipes, the chip doesn't render at all, so this view
    /// only ever sees the own-recipe case.
    let originalRecipeID: String

    /// Recipe title for the sheet's header — denormalized so the
    /// sheet doesn't need a SwiftData reference. Caller passes
    /// `recipe.title`.
    let recipeTitle: String

    /// Bound to the parent's `presentationDetents(_:selection:)` so
    /// pushing into a friend's cookbook can expand the sheet to
    /// `.large` (the saves list itself reads fine at `.medium`, but a
    /// cookbook's recipe cards need the full sheet to avoid forcing a
    /// drag-up gesture). The saves landing screen returns to
    /// `.medium` on pop via `.onDisappear` on the destination.
    @Binding var detent: PresentationDetent

    @State private var imports: [RecipeImportRecord] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    @State private var hasLoadedOnce: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    headerCard
                    content
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.md)
                .padding(.bottom, AppSpacing.xxl)
            }
            .llamaBackground()
            .navigationTitle("Saves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Haptics.selection()
                        dismiss()
                    } label: {
                        Text("Done")
                            .foregroundStyle(appearance.accentColor)
                            .accentTextOutline()
                    }
                }
            }
            .task {
                if !hasLoadedOnce {
                    await load()
                }
            }
            .refreshable {
                await load()
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("RECIPE")
                .eyebrowStyle(AppColor.textTertiary)
            Text(StringCase.titleCase(recipeTitle))
                .font(AppFont.sectionHeading)
                .foregroundStyle(appearance.accentColor)
                .lineLimit(2)
            Text(headerSubtitle)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
        }
        .surfaceCard()
    }

    private var headerSubtitle: String {
        switch imports.count {
        case 0: return "No saves yet."
        case 1: return "1 Cook has saved this recipe."
        default: return "\(imports.count) Cooks have saved this recipe."
        }
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        if isLoading && imports.isEmpty {
            loadingState
        } else if let loadError, imports.isEmpty {
            errorState(message: loadError)
        } else if imports.isEmpty {
            emptyState
        } else {
            importsList
        }
    }

    private var loadingState: some View {
        VStack(spacing: AppSpacing.md) {
            Spacer().frame(height: AppSpacing.xl)
            LlamaProgressIndicator(size: 60, accent: appearance.accentColor)
            Text("Loading saves…")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
            Spacer().frame(height: AppSpacing.xl)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: "bookmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppColor.textTertiary)
            Text("Nobody has saved this recipe yet.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
            Text("Cooks who add this to their cookbook will show up here.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xxl)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(AppColor.textTertiary)
            Text(message)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Haptics.selection()
                Task { await load() }
            } label: {
                Text("Try again")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.onAccent)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.sm)
                    .background(appearance.accentColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xxl)
    }

    private var importsList: some View {
        VStack(spacing: AppSpacing.xs) {
            ForEach(imports) { record in
                importerRow(record: record)
            }
        }
    }

    /// Look up the importer in the local FriendsStore — when matched,
    /// the row renders in the friend's accent color and becomes a tap
    /// target for their cookbook. When unmatched (former friend, or
    /// importer the user has never been connected to), the row renders
    /// in the local accent and stays passive.
    private func friendSnapshot(for record: RecipeImportRecord) -> UserProfileSnapshot? {
        friendsStore.friends.first { $0.userRecordName == record.importerID }
    }

    @ViewBuilder
    private func importerRow(record: RecipeImportRecord) -> some View {
        if let snapshot = friendSnapshot(for: record) {
            NavigationLink {
                FriendLibraryView(friend: snapshot)
                    // Expand the sheet so a cookbook's recipe cards
                    // are visible without an explicit drag-up. Pop
                    // back collapses to `.medium` again so the saves
                    // list looks the way it did on first present.
                    .onAppear { detent = .large }
                    .onDisappear { detent = .medium }
            } label: {
                importerRowContent(record: record, friend: snapshot)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens \(snapshot.displayName)'s cookbook")
        } else {
            importerRowContent(record: record, friend: nil)
        }
    }

    private func importerRowContent(record: RecipeImportRecord, friend: UserProfileSnapshot?) -> some View {
        // Use the canonical `UserProfileSnapshot.resolvedAccent` helper
        // (terracotta fallback) instead of re-inlining + falling back
        // to the signed-in user's accent — importers we don't know
        // should show the brand color, not "my" color.
        let resolvedAccent: Color = friend?.resolvedAccent ?? AppColor.accent
        let isCooking = friend?.isCookingNow ?? false
        return HStack(spacing: AppSpacing.sm) {
            Group {
                if isCooking {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(resolvedAccent)
                } else {
                    Circle()
                        .stroke(resolvedAccent, lineWidth: 1.5)
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 14, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.importerDisplayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                Text(relativeImportDate(record.importedAt))
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }
            Spacer(minLength: 0)
            if friend != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
        .padding(AppSpacing.sm + 2)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    /// Relative-date formatter — "2h ago", "3d ago", "Apr 14, 2026".
    /// Switches to absolute past 7 days so older imports stay
    /// readable; relative inside that window for the "this is
    /// happening recently" delight surface.
    private func relativeImportDate(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 7 * 24 * 3600 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return Formatters.date.string(from: date)
    }

    // MARK: - Fetch

    private func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        do {
            let fetched = try await CloudKitService.fetchRecipeImports(
                forOriginalRecipeID: originalRecipeID
            )
            imports = fetched
            loadError = nil
        } catch {
            // Don't blank previous results on a transient refetch
            // error — keep showing what we had while the user
            // decides whether to retry.
            if imports.isEmpty {
                loadError = "Couldn't load saves right now."
            }
        }
    }
}
