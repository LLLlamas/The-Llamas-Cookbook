import SwiftUI

/// Read-only view of a friend's library — pushed from the friend
/// row in `ProfileView`. Fetches `PublishedRecipeSummary` records
/// for `friend.userRecordName` from CloudKit and renders a card
/// list. Tapping a card pushes `FriendRecipeDetailView`.
///
/// **Visual identity.** Renders in the friend's accent color (their
/// `UserProfile.accentHex`) so visiting Marco's cookbook *feels
/// like Marco's*. We apply via `.tint(...)` at the root, which
/// covers SwiftUI primitives (back chevron, link underlines, the
/// accent on title text). The known UIKit-appearance carve-outs
/// from `CLAUDE.md` (page control, ShareSheet) won't follow the
/// scoped tint, but they don't appear on this surface.
///
/// **Loading model.** Fetch on `.task`; render `ProgressView`
/// during the first load when there's nothing cached. Subsequent
/// re-appearances refetch in the background — old data stays on
/// screen so the list doesn't flicker. A failed fetch surfaces a
/// retry button rather than a blocking alert (the friend's library
/// being unreachable is a soft failure).
///
/// **Slice 4 scope.** Read-only. Tap pushes detail. Long-press is
/// reserved for future "save to my book" affordance. No pull-to-
/// refresh, no search, no tag chips — those land in later passes
/// once the basic flow proves out.
struct FriendLibraryView: View {
    let friend: UserProfileSnapshot

    @State private var summaries: [PublishedRecipeSummary] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    @State private var hasLoadedOnce: Bool = false
    /// Active category filter — `nil` means "All". Tag pills come from
    /// the `tags` denormalized onto each `PublishedRecipeSummary`
    /// (Part 1 of the friend-parity work); same convention as the home
    /// library's tag filter.
    @State private var categoryFilter: String? = nil

    private var friendAccent: Color {
        if let hex = friend.accentHex, let color = Color(hex: hex) {
            return color
        }
        return AppColor.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            friendHeader
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xs)
                .padding(.bottom, AppSpacing.sm)

            CategoryFilterStrip(
                categories: allCategories,
                totalCount: summaries.count,
                countFor: { tag in summaries.filter { $0.tags.contains(tag) }.count },
                selection: $categoryFilter,
                accent: friendAccent
            )
            .background(AppColor.background)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AppColor.divider)
                    .frame(height: 1)
            }

            content
        }
        .llamaBackground()
        .navigationTitle(StringCase.cookbookTitle(displayName: friend.displayName))
        .navigationBarTitleDisplayMode(.inline)
        .tint(friendAccent)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Friend cookbook surfaces tint in the friend's accent
                // (CLAUDE.md › UX guardrails) — pass `friendAccent`,
                // not the local user's appearance.accentColor.
                CookbookHeader(
                    title: StringCase.cookbookTitle(displayName: friend.displayName),
                    accent: friendAccent
                )
            }
        }
        .task {
            // First load only — subsequent .task fires on view
            // re-appear, but we let .refreshable / explicit retry
            // handle those rather than racing the cached data off
            // screen.
            if !hasLoadedOnce {
                await loadLibrary()
            }
        }
    }

    // MARK: - Header

    /// Single centered line directly under the navigation title — the
    /// fork-and-knife glyph, an optional cooking-now / last-cooked
    /// title, and a presence indicator. The dot is filled and pulses
    /// in the friend's accent when they're cooking right now, and
    /// renders as a hollow outline (same color, no fill) when they're
    /// idle. The eyebrow text surfaces the recipe in flight as
    /// "Cooking: <title>" while they're in cook mode (the title is
    /// stamped into `lastCookedTitle` on cook start), then collapses
    /// back to "Last cooked: <title>" once the cook ends. Empty
    /// state (new friend, never cooked anything in-app, not cooking)
    /// shows just the glyph + dot — no "Not cooked yet" copy, which
    /// reads as a negative judgment on someone who simply hasn't
    /// played around with the app yet.
    private var friendHeader: some View {
        // When the friend's last-cooked recipe is one we've also
        // pulled into `summaries`, wrap the eyebrow in a tap target
        // that pushes its `FriendRecipeDetailView`. Same visual
        // treatment as ProfileView's "Last cooked" link — exact same
        // font / size / color as before, link affordance is purely
        // behavioral. When no summary match is available (still
        // loading, or the cooked recipe was deleted from the friend's
        // cookbook), the eyebrow falls through to the original
        // non-tappable form.
        Group {
            if let summary = lastCookedSummary {
                NavigationLink {
                    FriendRecipeDetailView(friend: friend, summary: summary)
                } label: {
                    headerLabel
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                headerLabel
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var headerLabel: some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: "fork.knife")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.textTertiary)
            if let title = friend.lastCookedTitle, !title.isEmpty {
                Text("\(Text(friend.isCookingNow ? "Currently Cooking: " : "Last cooked: ").foregroundStyle(AppColor.textTertiary))\(Text(title).fontWeight(.semibold).foregroundStyle(friendAccent))")
                    .font(AppFont.caption)
                    .lineLimit(1)
            } else if friend.isCookingNow {
                // Fallback for cooks that started before the title-on-
                // start write existed — `cookingStartedAt` is set but
                // `lastCookedTitle` is empty/stale. Surface presence
                // without a title rather than rendering a dangling
                // "Currently Cooking: " or just a bare dot.
                Text("Currently Cooking")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }
            AccentDot(
                hex: friend.accentHex,
                fallback: friendAccent,
                isGlowing: friend.isCookingNow,
                outlineWhenIdle: true
            )
        }
    }

    /// The published-recipe summary that matches the friend's
    /// `lastCookedRecipeID`, when both sides are available. Returns
    /// nil while summaries are loading or when the friend's last-
    /// cooked recipe has since been removed from their cookbook
    /// (in which case the eyebrow stays as a plain non-tappable
    /// label rather than dead-ending the user on a 404).
    private var lastCookedSummary: PublishedRecipeSummary? {
        guard let raw = friend.lastCookedRecipeID,
              let id = UUID(uuidString: raw)
        else { return nil }
        return summaries.first { $0.localRecipeID == id }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading && summaries.isEmpty {
            // First load with nothing on screen — center a spinner.
            // Subsequent refreshes leave existing cards in place
            // (handled by `refreshable` which doesn't blank the
            // list).
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
                .padding(.top, AppSpacing.xxl)
        } else if let loadError, summaries.isEmpty {
            errorState(message: loadError)
        } else if summaries.isEmpty {
            emptyState
        } else if filteredSummaries.isEmpty {
            emptyFilterState
        } else {
            recipeList
        }
    }

    private var recipeList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(spacing: AppSpacing.md) {
                        ForEach(filteredSummaries) { summary in
                            NavigationLink {
                                FriendRecipeDetailView(friend: friend, summary: summary)
                            } label: {
                                FriendRecipeCard(
                                    summary: summary,
                                    accent: friendAccent
                                )
                            }
                            .buttonStyle(.plain)
                            .id(summary.id)
                        }
                    }
                    // Right padding leaves room for the letter index so
                    // it doesn't overlap card content — mirrors the
                    // home library's recipeList paddings.
                    .padding(.leading, AppSpacing.lg)
                    .padding(.trailing, AppSpacing.lg + 16)
                    .padding(.top, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.xxl)
                }
                .scrollContentBackground(.hidden)
                .refreshable {
                    await loadLibrary()
                }

                LetterIndex(
                    letters: LetterIndex.allLetters,
                    populated: populatedLetters,
                    accent: friendAccent,
                    externalHighlightLetter: nil
                ) { letter in
                    guard let target = firstSummary(atOrAfter: letter) else { return }
                    Haptics.selection()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(target.id, anchor: .top)
                    }
                }
                .padding(.trailing, 2)
            }
        }
    }

    private var emptyFilterState: some View {
        VStack(spacing: AppSpacing.md) {
            Text("No recipes tagged \"\(StringCase.titleCase(categoryFilter ?? ""))\"")
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.center)
            Button("Clear filter") {
                categoryFilter = nil
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.sm)
            .background(AppColor.surface)
            .foregroundStyle(friendAccent)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived

    private var allCategories: [String] {
        var set = Set<String>()
        for s in summaries { for t in s.tags { set.insert(t) } }
        return set.sorted()
    }

    private var filteredSummaries: [PublishedRecipeSummary] {
        guard let tag = categoryFilter else { return summaries }
        return summaries.filter { $0.tags.contains(tag) }
    }

    private var populatedLetters: Set<String> {
        Set(filteredSummaries.map { LetterIndex.bucket(for: $0.recipeTitle) })
    }

    /// Walk the alphabet from `letter` forward and return the first
    /// summary whose bucket matches a populated letter. Same fall-
    /// through behaviour as the home library — tapping `#` with no
    /// non-letter recipes scrolls to A.
    private func firstSummary(atOrAfter letter: String) -> PublishedRecipeSummary? {
        guard let startIndex = LetterIndex.allLetters.firstIndex(of: letter) else { return nil }
        let populated = populatedLetters
        for candidate in LetterIndex.allLetters[startIndex...] where populated.contains(candidate) {
            return filteredSummaries.first { LetterIndex.bucket(for: $0.recipeTitle) == candidate }
        }
        return nil
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: "book.closed")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(friendAccent.opacity(0.5))
            Text("\(friend.displayName) hasn't shared any recipes yet.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xxl)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(AppColor.textTertiary)
            Text(message)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Haptics.selection()
                Task { await loadLibrary() }
            } label: {
                Text("Try again")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.onAccent)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.sm)
                    .background(friendAccent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xxl)
    }

    // MARK: - Fetch

    private func loadLibrary() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        do {
            let fetched = try await CloudKitService.fetchPublishedRecipeSummaries(
                ownerID: friend.userRecordName
            )
            summaries = fetched
            loadError = nil
        } catch {
            // Don't blank existing summaries on a transient error —
            // the user keeps seeing the last-known list while the
            // banner explains why a refresh failed. Only surface
            // the error UI when there's nothing to fall back to.
            if summaries.isEmpty {
                loadError = AppMetadata.describeServerError(error)
            }
        }
    }
}

/// Recipe card for a friend's library list. Mirrors `RecipeCardView`'s
/// two-column layout (title + dates left, square thumbnail right) so a
/// friend's cookbook reads as the same kind of surface as the home
/// library. Thumbnails come from `PublishedRecipeSummary.thumbnailData`
/// — populated from the record's `photo0` asset on fetch — with a
/// graceful photo-glyph fallback when the recipe has no photos yet.
private struct FriendRecipeCard: View {
    let summary: PublishedRecipeSummary
    let accent: Color

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy"
        return f
    }()

    /// One-line height of the description font (10.5pt medium).
    /// Mirrors `RecipeCardView.summaryLineHeight` so the friend card
    /// clamps the description row identically — the trailing-shrink
    /// renderer paints the wrapped first word back onto line 1, so
    /// visible content is always exactly one line.
    private static let summaryLineHeight: CGFloat = {
        let font = UIFont.systemFont(ofSize: 10.5, weight: .medium)
        return ceil(font.lineHeight)
    }()

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
                Text(StringCase.titleCase(summary.recipeTitle))
                    .font(AppFont.sectionHeading)
                    .foregroundStyle(accent)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    // Same letterpressed treatment as `RecipeCardView`
                    // so the title reads as the same kind of object
                    // when navigating between own-library and
                    // friend-library cards.
                    .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: -0.4, y: 0)
                    .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0.4, y: 0)
                    .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0, y: -0.4)
                    .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0, y: 0.4)
                    .shadow(color: AppColor.shadow, radius: 1.5, x: 0, y: 1)

                if !summary.tags.isEmpty {
                    TagChipsRow(tags: summary.tags, accent: accent)
                        .padding(.top, 2)
                }

                if let description = summary.summary, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(2)
                        .textRenderer(TrailingShrinkRenderer(source: description))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(height: Self.summaryLineHeight, alignment: .top)
                        .clipped()
                }

                Spacer(minLength: AppSpacing.xs)

                Text("Updated \(Self.shortDate.string(from: summary.updatedAt))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppColor.textTertiary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            thumbnail
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    AppColor.surfaceRaised.opacity(0.85),
                    AppColor.surface.opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(AppColor.divider.opacity(0.6), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .shadow(color: AppColor.shadow, radius: 14, x: 0, y: 4)
        .shadow(color: AppColor.shadowSoft, radius: 2, x: 0, y: 1)
    }

    private var thumbnail: some View {
        Group {
            if let data = summary.thumbnailData {
                RecipeImageView(
                    data: data,
                    contentMode: .fill,
                    cornerRadius: AppRadius.md
                )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .fill(accent.opacity(0.12))
                    LlamaLogo(size: 56, shadowColor: accent)
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider.opacity(0.7), lineWidth: 0.5)
        )
    }
}
