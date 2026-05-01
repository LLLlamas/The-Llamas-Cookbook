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

    private var friendAccent: Color {
        if let hex = friend.accentHex, let color = Color(hex: hex) {
            return color
        }
        return AppColor.accent
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                friendHeader

                content
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xxl)
        }
        .llamaBackground()
        .navigationTitle(StringCase.cookbookTitle(displayName: friend.displayName))
        .navigationBarTitleDisplayMode(.inline)
        .tint(friendAccent)
        .task {
            // First load only — subsequent .task fires on view
            // re-appear, but we let .refreshable / explicit retry
            // handle those rather than racing the cached data off
            // screen.
            if !hasLoadedOnce {
                await loadLibrary()
            }
        }
        .refreshable {
            await loadLibrary()
        }
    }

    // MARK: - Header

    /// Single centered line directly under the navigation title — the
    /// fork-and-knife glyph, the friend's most recently cooked recipe
    /// title, and a presence indicator. The dot is filled and pulses
    /// in the friend's accent when they're cooking right now, and
    /// renders as a hollow outline (same color, no fill) when they're
    /// not. Hidden entirely when the friend has no last-cooked recipe
    /// yet — the indicator alone has no anchor to read against.
    @ViewBuilder
    private var friendHeader: some View {
        if let lastCookedTitle = friend.lastCookedTitle, !lastCookedTitle.isEmpty {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
                (Text("Last cooked: ")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
                + Text(lastCookedTitle)
                    .font(AppFont.caption.weight(.semibold))
                    .foregroundStyle(friendAccent))
                    .lineLimit(1)
                AccentDot(
                    hex: friend.accentHex,
                    fallback: friendAccent,
                    isGlowing: friend.isCookingNow,
                    outlineWhenIdle: true
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, AppSpacing.xs)
        }
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
        } else {
            recipeList
        }
    }

    private var recipeList: some View {
        LazyVStack(spacing: AppSpacing.md) {
            ForEach(summaries) { summary in
                NavigationLink {
                    FriendRecipeDetailView(friend: friend, summary: summary)
                } label: {
                    FriendRecipeCard(
                        summary: summary,
                        accent: friendAccent
                    )
                }
                .buttonStyle(.plain)
            }
        }
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
                loadError = "Couldn't load this cookbook."
            }
        }
    }
}

/// Recipe card for a friend's library list. Slimmer than
/// `RecipeCardView` — we don't have photo thumbnails (the summary
/// doesn't carry them, and one network round-trip per card to
/// fetch them would be wasteful), so the card leans on the title
/// and updated-on date instead.
private struct FriendRecipeCard: View {
    let summary: PublishedRecipeSummary
    let accent: Color

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy"
        return f
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

                Text("Updated \(Self.shortDate.string(from: summary.updatedAt))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.textTertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColor.textTertiary)
                .padding(.top, 6)
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
}
