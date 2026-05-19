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
    /// False when the view is the navigation-stack root (e.g. the
    /// Friends tab for unsigned users). Hides the custom back button
    /// since there's nothing to go back to.
    var showsBackButton: Bool = true

    @Environment(\.dismiss)      private var dismiss
    @Environment(UserAccount.self) private var userAccount

    @State private var summaries: [PublishedRecipeSummary] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    @State private var hasLoadedOnce: Bool = false
    /// Active category filter — `nil` means "All". Tag pills come from
    /// the `tags` denormalized onto each `PublishedRecipeSummary`
    /// (Part 1 of the friend-parity work); same convention as the home
    /// library's tag filter.
    @State private var categoryFilter: String? = nil
    /// Fires the letter-scrubber tick as the user free-scrolls across
    /// section boundaries — same feel as the home library and the
    /// `LetterIndex` strip. Reset on filter change.
    @State private var scrollTicker = ScrollSectionTicker()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            friendHeader
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xs)
                .padding(.bottom, AppSpacing.sm)

            if !showsBackButton && !userAccount.status.isSignedIn {
                signInBanner
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.sm)
            }

            CategoryFilterStrip(
                categories: allCategories,
                totalCount: summaries.count,
                countFor: { tag in summaries.filter { $0.tags.contains(tag) }.count },
                selection: $categoryFilter,
                accent: friend.resolvedAccent
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
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()
        .tint(friend.resolvedAccent)
        .toolbar {
            if showsBackButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.selection()
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(friend.resolvedAccent)
                            .accentTextOutline()
                            .frame(width: 30, height: 30)
                    }
                    .accessibilityLabel("Back")
                }
            }
            ToolbarItem(placement: .principal) {
                // Friend cookbook surfaces tint in the friend's accent
                // (CLAUDE.md › UX guardrails) — pass the friend's
                // resolved accent, not the local user's accentColor.
                CookbookHeader(
                    title: StringCase.cookbookTitle(displayName: friend.displayName),
                    accent: friend.resolvedAccent
                ) {
                    Image("Friends_Llama_Icon")
                        .resizable()
                        .renderingMode(.original)
                        .frame(width: 52, height: 52)
                }
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

    // MARK: - Sign-in banner (unsigned root path only)

    /// Compact card shown at the top of the seed cookbook when the
    /// user is not signed in. Encourages iCloud/SIWA without blocking
    /// access to the sample recipes below.
    private var signInBanner: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(friend.resolvedAccent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in to connect with friends")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                Text("Browse the starter recipes below, then sign in with Apple (Profile tab) to add friends and share recipes directly.")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(friend.resolvedAccent.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(friend.resolvedAccent.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
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
                Text("\(Text(friend.isCookingNow ? "Currently Cooking: " : "Last cooked: ").foregroundStyle(AppColor.textTertiary))\(Text(title).fontWeight(.semibold).foregroundStyle(friend.resolvedAccent))")
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
                fallback: friend.resolvedAccent,
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
                    // Spacing bumped to match the home library so the
                    // focused card's 4% scale-up doesn't overlap its
                    // neighbors mid-scroll.
                    LazyVStack(spacing: AppSpacing.md + 4) {
                        ForEach(filteredSummaries) { summary in
                            NavigationLink {
                                FriendRecipeDetailView(friend: friend, summary: summary)
                            } label: {
                                FriendRecipeCard(
                                    summary: summary,
                                    accent: friend.resolvedAccent
                                )
                            }
                            .buttonStyle(.plain)
                            .cardScrollTransition()
                            // Section-boundary scroll haptic — ticks
                            // once per letter-section change, matching
                            // the `LetterIndex` scrub feel.
                            .scrollSectionHaptic(
                                section: LetterIndex.bucket(for: summary.recipeTitle),
                                ticker: scrollTicker
                            )
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
                .onChange(of: categoryFilter) { _, _ in
                    // A filter switch swaps the whole row set — clear
                    // the ticker so the new list settles silently.
                    scrollTicker.reset()
                }

                LetterIndex(
                    letters: LetterIndex.allLetters,
                    populated: populatedLetters,
                    accent: friend.resolvedAccent,
                    externalHighlightLetter: nil,
                    scrollFocusLetter: nil
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
            .foregroundStyle(friend.resolvedAccent)
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
                .foregroundStyle(friend.resolvedAccent.opacity(0.5))
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
                    .background(friend.resolvedAccent)
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
        // Seed friend: hydrate from the bundled JSON, skip the
        // network entirely. No throw path — the cached summaries
        // are produced at decode time, so an empty list here means
        // the seed JSON shipped empty (developer error caught at
        // build time).
        if SeedFriend.isSeed(friend) {
            summaries = SeedFriend.librarySummaries()
            loadError = nil
            return
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

    /// Shared `UIFont` for the description row. Mirrors
    /// `RecipeCardView.summaryFont` so own-library and friend-library
    /// cards measure and render the description identically.
    private static let summaryFont: UIFont = .systemFont(ofSize: 10.5, weight: .medium)

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
                Text(StringCase.titleCase(summary.recipeTitle))
                    .font(AppFont.sectionHeading)
                    .foregroundStyle(accent)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .accentTextOutline()
                    .shadow(color: AppColor.shadow, radius: 1.5, x: 0, y: 1)

                if !summary.tags.isEmpty {
                    TagChipsRow(tags: summary.tags, accent: accent)
                        .padding(.top, 2)
                }

                if let description = summary.summary, !description.isEmpty {
                    ShrinkingDescriptionView(
                        text: description,
                        font: Self.summaryFont,
                        color: AppColor.textSecondary
                    )
                }

                Spacer(minLength: AppSpacing.xs)

                Text("Updated \(Formatters.date.string(from: summary.updatedAt))")
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
                    AppColor.surfaceRaised.opacity(0.95),
                    AppColor.surface.opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            // Top-edge highlight — matches `RecipeCardView` so own-
            // library and friend-library cards read as the same kind
            // of object. See RecipeCardView for the full rationale.
            LinearGradient(
                colors: [Color.white.opacity(0.18), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            AppColor.divider.opacity(0.6),
                            AppColor.divider.opacity(0.85)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        // Glossy glare — same sweep-in + scroll-reactive shine as the
        // home library's `RecipeCardView`, so a friend's cookbook reads
        // as the same kind of surface. Clip radius matches the card's.
        .cardGlare(cornerRadius: AppRadius.lg)
        .liftedCard()
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
        .accentTextOutline()
    }
}
