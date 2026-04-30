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
/// rather than relying on the cached `Recipe.importCountCache` —
/// the cache holds just the count, not the per-row identities.
/// `LlamaProgressIndicator` covers the load, with a graceful
/// empty-state for "nobody yet" and an error state for CK
/// failures.
struct ImportersListSheet: View {
    @Environment(AppearanceSettings.self) private var appearance
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
            .navigationTitle("Importers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(appearance.accentColor)
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
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(2)
            Text(headerSubtitle)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var headerSubtitle: String {
        switch imports.count {
        case 0: return "No imports yet."
        case 1: return "1 friend has imported this recipe."
        default: return "\(imports.count) friends have imported this recipe."
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
            Text("Loading importers…")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
            Spacer().frame(height: AppSpacing.xl)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppColor.textTertiary)
            Text("Nobody has imported this recipe yet.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
            Text("Friends who add this to their cookbook will show up here.")
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

    private func importerRow(record: RecipeImportRecord) -> some View {
        HStack(spacing: AppSpacing.sm) {
            // Small filled circle in the user's accent color —
            // matches the friends-list visual language. We don't
            // have the importer's actual `accentHex` in the audit
            // row (it's not denormalized there — would balloon the
            // schema for a render-detail nicety), so we render
            // with the local user's accent. Acceptable: the dot
            // here is an indication of "a friend" rather than
            // "this specific friend's identity color."
            Circle()
                .fill(appearance.accentColor)
                .frame(width: 10, height: 10)
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
        }
        .padding(AppSpacing.sm + 2)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    /// Relative-date formatter — "2h ago", "3d ago", "Apr 14".
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
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
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
                loadError = "Couldn't load importers right now."
            }
        }
    }
}
