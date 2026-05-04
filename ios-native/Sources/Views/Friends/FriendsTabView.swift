import SwiftUI

/// Friends tab — card grid mirroring the Library's card chrome so the
/// surface feels populated even with a handful of friends. Each card
/// surfaces the friend's display name, recipe count, saves on their
/// last-cooked recipe, the cooking / last-cooked line, and a
/// thumbnail. Presence is encoded as an inline `AccentDot` next to
/// the name plus a pulsing accent border around the card when cooking.
///
/// Tapping a card pushes `FriendLibraryView`. The empty state centers a
/// llama with an Add Friend CTA that opens the same `AddFriendSheet`
/// reachable from the Profile tab's Friends section, so there's a
/// single canonical entry point for finding people regardless of where
/// the user starts.
///
/// Recipe counts come from `CloudKitService.fetchPublishedRecipeSummaries`
/// — same source `FriendLibraryView` uses on push — cached per
/// `userRecordName` for the lifetime of this view so a refresh of the
/// friends list doesn't re-fetch every friend's library on every tick.
/// The fetch runs lazily when a friend first becomes visible; until it
/// resolves the card simply omits the count rather than rendering "0
/// recipes" (which would read as a negative judgment on a friend whose
/// library hasn't loaded yet).
struct FriendsTabView: View {
    @Environment(FriendsStore.self) private var friendsStore
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(UserAccount.self) private var userAccount

    @State private var showingAddFriend = false
    @State private var recipeCounts: [String: Int] = [:]
    /// Bytes of `photo0` for each friend's `lastCookedRecipeID`, populated
    /// on the same `fetchPublishedRecipeSummaries` pass that fills
    /// `recipeCounts` so a friend's last-cooked thumbnail piggybacks on
    /// the existing per-friend round-trip — no per-card render fetch.
    @State private var cookThumbnails: [String: Data] = [:]
    /// Per-friend accumulated saves — total `RecipeImport` rows whose
    /// chain root was authored by the friend, i.e. "how many times
    /// anyone imported any recipe this friend originally created."
    /// Keyed by `userRecordName` to match the other per-friend dicts.
    /// Memoized in-memory only (not persisted) — the friend list is
    /// bounded and the value is delight-tier metadata, so a single
    /// fetch per friend per session is the right cost/complexity
    /// trade. Promote to a UserDefaults cache the day this number
    /// shows up on a second surface.
    @State private var friendTotalSaves: [String: Int] = [:]
    @State private var inFlightCounts: Set<String> = []
    @State private var inFlightSaves: Set<String> = []

    private var friendsTitle: String {
        StringCase.friendsTitle(displayName: userAccount.status.identity?.displayName)
    }

    var body: some View {
        Group {
            if friendsStore.friends.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .llamaBackground(
            asset: "Friends_Llama_Icon_Large",
            tint: appearance.accentColor
        )
        .navigationTitle(friendsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .tint(appearance.accentColor)
        .toolbar {
            ToolbarItem(placement: .principal) {
                CookbookHeader(title: friendsTitle, accent: appearance.accentColor)
            }
            if !friendsStore.friends.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.impact(.light)
                        showingAddFriend = true
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(appearance.accentColor)
                    }
                    .accessibilityLabel("Add a friend")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.selection()
                        Task { await friendsStore.refresh() }
                    } label: {
                        if friendsStore.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(appearance.accentColor)
                        }
                    }
                    .accessibilityLabel("Refresh friends")
                    .disabled(friendsStore.isRefreshing)
                }
            }
        }
        .sheet(isPresented: $showingAddFriend) {
            AddFriendSheet()
                .environment(appearance)
                .environment(friendsStore)
        }
        .navigationDestination(for: UserProfileSnapshot.self) { friend in
            FriendLibraryView(friend: friend)
        }
        .task {
            await friendsStore.refresh()
        }
        .refreshable {
            await friendsStore.refresh()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: AppSpacing.lg) {
            Image("Friends_Llama_Icon_Large")
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 160, height: 160)
                .shadow(
                    color: appearance.accentColor.opacity(0.45),
                    radius: 160 * 0.0643,
                    x: 0,
                    y: 160 * 0.05
                )
                .accessibilityHidden(true)
            VStack(spacing: AppSpacing.xs) {
                Text("No friends yet")
                    .font(AppFont.sectionHeading)
                    .foregroundStyle(AppColor.textPrimary)
                Text("Add someone you know to see their cookbook.")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                Haptics.impact(.light)
                showingAddFriend = true
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 16, weight: .bold))
                    Text("Add Friend")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(AppColor.onAccent)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.sm + 2)
                .background(appearance.accentColor)
                .clipShape(Capsule())
                .shadow(color: appearance.accentColor.opacity(0.35), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a friend")
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: AppSpacing.md),
                    GridItem(.flexible(), spacing: AppSpacing.md)
                ],
                spacing: AppSpacing.md
            ) {
                ForEach(friendsStore.friends) { friend in
                    NavigationLink(value: friend) {
                        FriendCardView(
                            friend: friend,
                            recipeCount: recipeCounts[friend.userRecordName],
                            cookThumbnail: cookThumbnails[friend.userRecordName],
                            totalSaves: friendTotalSaves[friend.userRecordName],
                            friendsSince: friendsStore.friendsSinceByID[friend.userRecordName],
                            fallbackAccent: appearance.accentColor
                        )
                    }
                    .buttonStyle(.plain)
                    .task(id: friend.userRecordName) {
                        await loadCountIfNeeded(for: friend)
                        await loadTotalSavesIfNeeded(for: friend)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xxl)
        }
        .scrollContentBackground(.hidden)
    }

    private func loadCountIfNeeded(for friend: UserProfileSnapshot) async {
        let id = friend.userRecordName
        if recipeCounts[id] != nil || inFlightCounts.contains(id) { return }
        inFlightCounts.insert(id)
        defer { inFlightCounts.remove(id) }
        if let summaries = try? await CloudKitService.fetchPublishedRecipeSummaries(ownerID: id) {
            recipeCounts[id] = summaries.count
            // Pluck the thumbnail for the friend's last-cooked recipe out
            // of the same payload — the summaries already carry `photo0`
            // bytes so the trailing-edge thumb costs zero extra round-
            // trips. Skipped silently when the friend's last-cooked
            // recipe isn't published or has no photo.
            if let raw = friend.lastCookedRecipeID,
               let recipeID = UUID(uuidString: raw),
               let match = summaries.first(where: { $0.localRecipeID == recipeID }),
               let data = match.thumbnailData {
                cookThumbnails[id] = data
            }
        }
    }

    /// Hydrate the per-friend accumulated saves stat — total
    /// `RecipeImport` rows across every recipe this friend originally
    /// authored. No persistent cache: the value lives in `@State` for
    /// the lifetime of the view and re-fetches once per friend per
    /// session. In-flight dedupe matches `loadCountIfNeeded`.
    private func loadTotalSavesIfNeeded(for friend: UserProfileSnapshot) async {
        let key = friend.userRecordName
        guard friendTotalSaves[key] == nil, !inFlightSaves.contains(key) else { return }
        inFlightSaves.insert(key)
        defer { inFlightSaves.remove(key) }
        if let count = try? await CloudKitService.countRecipeImports(forCreatorID: key) {
            friendTotalSaves[key] = count
        }
    }
}

/// One friend tile in the Friends-tab grid. Mirrors the visual chrome
/// of `RecipeCardView` (translucent gradient surface, same stroke, same
/// shadow stack) so the two surfaces read as the same kind of object.
/// Tinted in the friend's resolved accent — title text, soft border,
/// cooking glow, save count — so visiting Marco's tile *feels like
/// Marco's* the same way `FriendLibraryView` does on push.
///
/// Presence is encoded two ways that pulse in sync: an inline
/// `AccentDot` next to the display name (filled+pulsing when cooking,
/// hollow outline when idle), and a soft accent border around the
/// card that thickens + brightens on the same `1.1s easeInOut`
/// `repeatForever(autoreverses:)` curve when cooking. The border
/// pulses in place via `strokeBorder` (no external glow shadow), so
/// the card's outer footprint is identical idle vs cooking.
private struct FriendCardView: View {
    let friend: UserProfileSnapshot
    let recipeCount: Int?
    let cookThumbnail: Data?
    /// Accumulated saves across every recipe this friend originally
    /// authored — i.e. total `RecipeImport` rows where the friend is
    /// the chain-root creator. Per-friend stat, not per-recipe. Nil
    /// while the lookup is in flight / unavailable; the saves row
    /// falls back silently when nil.
    let totalSaves: Int?
    /// When this friendship was accepted (status flipped pending →
    /// accepted on the `Friendship` record). Drives the secondary
    /// metadata line's fallback when there are no saves to show.
    /// Nil for legacy accepted records that predate the field — the
    /// line collapses silently in that case.
    let friendsSince: Date?
    let fallbackAccent: Color

    /// Bottom-left thumbnail size. Same 52pt frame as before — the
    /// slot moved from the trailing edge to under the cooking line,
    /// but the chrome (rounded square, divider stroke, fallback
    /// chain) is unchanged so the visual "card slot" stays familiar.
    private static let thumbnailSize: CGFloat = 52

    /// Pulse driver for the cooking-now border (lineWidth + opacity).
    /// Mirrors `AccentDot`'s `pulse` flag and animation curve so the
    /// inline dot and the border breathe in sync.
    @State private var pulse: Bool = false

    private var friendAccent: Color {
        if let hex = friend.accentHex, let color = Color(hex: hex) {
            return color
        }
        return fallbackAccent
    }

    /// Has the friend cooked something we know the title of? Drives
    /// fallback selection in the thumbnail slot — `LlamaLogo` for "they
    /// cooked something but it had no photo" vs. `Friends_Llama_Icon`
    /// for "they've never cooked anything." The slot itself is always
    /// rendered so the card layout stays uniform across friends.
    private var hasLastCookedTitle: Bool {
        guard let title = friend.lastCookedTitle, !title.isEmpty else { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .center, spacing: AppSpacing.xs) {
            // Top row — accent dot + display name on a single baseline.
            // Mirrors `FriendLibraryView.headerLabel`, which pairs
            // `AccentDot` with text via a default-center HStack; the
            // 12pt circle reads cleanly against a 24pt serif title at
            // standard center alignment without needing baseline tuning.
            // The HStack has intrinsic width and centers as a unit
            // under the parent VStack's `.center` alignment, same as
            // the metadata rows below.
            HStack(spacing: AppSpacing.xs) {
                AccentDot(
                    hex: friend.accentHex,
                    fallback: fallbackAccent,
                    isGlowing: friend.isCookingNow,
                    outlineWhenIdle: true
                )
                Text(friend.displayName)
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(friendAccent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: -0.4, y: 0)
                    .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0.4, y: 0)
                    .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0, y: -0.4)
                    .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0, y: 0.4)
                    .shadow(color: AppColor.shadow, radius: 1.5, x: 0, y: 1)
            }

            // Recipe count — small caption directly under the name, in
            // the same muted-tertiary tone `RecipeCardView`'s `dateStack`
            // uses for secondary metadata. The leading `book.closed.fill`
            // glyph is the same icon the previous `recipeCountBadge` pill
            // used (and matches the "this many recipes" convention the
            // app reads as elsewhere) — kept inline + tertiary-tinted so
            // it reads as secondary metadata, not an accent affordance.
            // Renders nothing while the count is still loading rather
            // than flashing "0 Recipes."
            if let count = recipeCount {
                HStack(spacing: 4) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(friendAccent)
                    Text(count == 1 ? "1 Recipe" : "\(count) Recipes")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColor.textTertiary)
                }
            }

            // Secondary metadata row. Reserved with a fixed minHeight
            // so collapsing this line doesn't shift the cooking line
            // up — combined with the card's `minHeight: 150`, this
            // keeps every card the same height regardless of state.
            secondaryMetaLine
                .frame(minHeight: 14, alignment: .center)

            // Cooking-status eyebrow — kept verbatim from the previous
            // pass (copy + styling) since the line itself is the rule
            // CLAUDE.md calls out under "lastCookedTitle doubles as
            // live 'Cooking: <title>' eyebrow during a cook."
            cookingLine

            Spacer(minLength: 0)

            // Thumbnail centered horizontally under the text stack so
            // it shares the card's vertical axis with the title and
            // metadata rows. Only the inner content changes with the
            // fallback chain (cooked photo → LlamaLogo → Friends_Llama_Icon).
            thumbnailSlot
        }
        .padding(AppSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .top)
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
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        // Soft accent border in the friend's accent — always present,
        // and pulses (lineWidth + opacity) when cooking instead of
        // throwing an external glow shadow. `strokeBorder` strokes
        // inside the rect, so the card's outer footprint stays
        // identical idle vs cooking — the active state reads through
        // a thicker, brighter, breathing border on the same 1.1s
        // easeInOut autoreverse curve `AccentDot` uses, so the dot
        // and border pulse in sync.
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(
                    friendAccent.opacity(
                        friend.isCookingNow ? (pulse ? 0.95 : 0.65) : 0.5
                    ),
                    lineWidth: friend.isCookingNow ? (pulse ? 2.5 : 2.0) : 1.5
                )
        )
        .shadow(color: AppColor.shadow, radius: 14, x: 0, y: 4)
        .shadow(color: AppColor.shadowSoft, radius: 2, x: 0, y: 1)
        .animation(
            friend.isCookingNow
                ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                : .default,
            value: pulse
        )
        .onAppear { if friend.isCookingNow { pulse = true } }
        .onChange(of: friend.isCookingNow) { _, newValue in pulse = newValue }
    }

    /// Thin metadata row between the recipe count and the cooking
    /// eyebrow. Two states, in order:
    ///
    /// 1. Saves > 0 → bookmark glyph + count, matching the chip
    ///    `RecipeDetailView` uses for "Imported by N" so the two
    ///    surfaces share a visual vocabulary for save activity.
    /// 2. Otherwise → "Friends since: M/D/YY" using the friendship's
    ///    `acceptedAt` date (when status flipped to accepted, i.e.
    ///    when the friendship actually began). Falls back to empty
    ///    if the date is unavailable (legacy records that predate
    ///    the `acceptedAt` field) — the line collapses to its
    ///    `minHeight` reservation upstream so the card height stays
    ///    uniform.
    @ViewBuilder
    private var secondaryMetaLine: some View {
        if let saves = totalSaves, saves > 0 {
            HStack(spacing: 4) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(friendAccent)
                Text(saves == 1 ? "1 Save" : "\(saves) Saves")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
            }
        } else if let since = friendsSince {
            Text("Friends since: \(Self.shortDate.string(from: since))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColor.textTertiary)
        }
    }

    /// Shared formatter — `M/d/yy` matches the short-date convention
    /// used by `RecipeCardView` and `FriendLibraryView` for compact
    /// card metadata. Fixed format (rather than `dateStyle: .short`)
    /// so the line stays narrow enough to coexist with the cooking
    /// eyebrow on a half-width grid cell across locales.
    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy"
        return f
    }()

    @ViewBuilder
    private var cookingLine: some View {
        if let title = friend.lastCookedTitle, !title.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "fork.knife")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
                Text("\(Text(friend.isCookingNow ? "Cooking: " : "Last Cooked: ").foregroundStyle(AppColor.textTertiary))\(Text(title).fontWeight(.semibold).foregroundStyle(friendAccent))")
                    .font(AppFont.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        } else if friend.isCookingNow {
            HStack(spacing: 4) {
                Image(systemName: "fork.knife")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
                Text("Cooking now")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
    }

    /// Bottom-left thumbnail slot. Always rendered at `thumbnailSize`
    /// with the same `AppRadius.md` clip + 0.5pt divider stroke as
    /// `FriendRecipeCard`'s photo treatment, so the card's visual
    /// "card slot" stays identical regardless of which fallback
    /// branch fires. Inner content follows the fallback chain:
    ///
    /// 1. `cookThumbnail` data present → render the photo.
    /// 2. `lastCookedTitle` present but no thumbnail → `LlamaLogo`
    ///    tinted in the friend's accent (cooked something, no photo).
    /// 3. Neither → `Friends_Llama_Icon` (52pt variant) tinted in the
    ///    friend's accent (never cooked anything).
    @ViewBuilder
    private var thumbnailSlot: some View {
        Group {
            if let data = cookThumbnail {
                RecipeImageView(
                    data: data,
                    contentMode: .fill,
                    cornerRadius: AppRadius.md
                ) {
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .fill(friendAccent.opacity(0.12))
                }
            } else {
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(friendAccent.opacity(0.12))
                    .overlay(fallbackLlama)
            }
        }
        .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider.opacity(0.7), lineWidth: 0.5)
        )
    }

    /// Inner llama silhouette for the no-photo fallbacks. Both branches
    /// render an alpha-derived silhouette tinted in the friend's accent
    /// — `LlamaLogoTemplate` (template-rendering variant of the brand
    /// artwork) for friends who cooked something without a photo, and
    /// `Friends_Llama_Icon` (tab-bar variant) for friends who haven't
    /// cooked anything yet. Same scaling, same interior padding, so the
    /// two fallbacks read as the same kind of placeholder.
    @ViewBuilder
    private var fallbackLlama: some View {
        if hasLastCookedTitle {
            Image("LlamaLogoTemplate")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(friendAccent)
                .padding(7)
        } else {
            Image("Friends_Llama_Icon")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(friendAccent)
                .padding(7)
        }
    }

}

#Preview {
    NavigationStack { FriendsTabView() }
        .environment(FriendsStore())
        .environment(AppearanceSettings())
}
