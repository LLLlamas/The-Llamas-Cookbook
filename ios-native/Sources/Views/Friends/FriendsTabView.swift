import SwiftUI

/// Friends tab — card grid mirroring the Library's card chrome so the
/// surface feels populated even with a handful of friends. Each card
/// surfaces the friend's display name, recipe count, saves on their
/// last-cooked recipe, the cooking / last-cooked line, and a
/// thumbnail. Presence is encoded as an inline `AccentDot` next to
/// the name plus a pulsing accent border around the card when cooking.
///
/// Tapping a card pushes `FriendLibraryView`. The "Your Llama" seed
/// friend (see `SeedFriend.swift`) always sits at index 0 of
/// `friendsStore.friends` regardless of CloudKit state, so the grid
/// is never empty and the toolbar's `+` is the single canonical entry
/// point for finding more people. The same sheet is reachable from
/// the Profile tab's Friends section.
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
    @Environment(LlamaProStore.self) private var proStore

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

    /// True while the user has fewer than 3 friends total (including the
    /// "Your Llama" seed, which always counts as 1). Drives the
    /// accent-tinted background watermark and the "Looking for a friend?"
    /// CTA below the grid. Flips to false — switching to the standard
    /// background — once the user has 2+ real friends (seed + 2 = 3).
    private var isBelowSocialThreshold: Bool {
        friendsStore.friends.count < 3
    }

    var body: some View {
        if !userAccount.status.isSignedIn {
            // Unsigned users land directly in the Your Llama seed cookbook
            // so they have something to browse on day one without signing in.
            // The grid (and its Add Friend / social surfaces) is intentionally
            // hidden until they're authenticated.
            FriendLibraryView(friend: SeedFriend.profile, showsBackButton: false)
        } else {
            grid
                .llamaBackground(
                    asset: proStore.plan == .yearly ? "Llama-Pro-Icon-Friends-Crown-Sunglasses" : proStore.isPro ? "Llama-Pro-Icon-Friends-Crown" : "Friends_Llama_Icon_Large",
                    tint: isBelowSocialThreshold ? appearance.cookbookTitleAccentColor : .clear
                )
                .navigationTitle(friendsTitle)
                .navigationBarTitleDisplayMode(.inline)
                .tint(appearance.cookbookTitleAccentColor)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        CookbookHeader(
                            title: friendsTitle,
                            accent: appearance.cookbookTitleAccentColor,
                            glowActive: appearance.isAccentGlowActive(.header)
                        ) {
                            Image(proStore.plan == .yearly ? "Llama-Pro-Icon-Friends-Crown-Sunglasses" : proStore.isPro ? "Llama-Pro-Icon-Friends-Crown" : "Friends_Llama_Icon")
                                .resizable()
                                .renderingMode(.original)
                                .frame(width: 52, height: 52)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Haptics.impact(.light)
                            showingAddFriend = true
                        } label: {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(appearance.cookbookTitleAccentColor)
                                .accentTextOutline()
                        }
                        .accessibilityLabel("Add a friend")
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
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            VStack(spacing: 0) {
                requestsSection

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
                                friendsSince: friendsStore.friendsSinceByID[friend.userRecordName]
                            )
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            Haptics.selection()
                        })
                        .task(id: friend.userRecordName) {
                            async let count: Void = loadCountIfNeeded(for: friend)
                            async let saves: Void = loadTotalSavesIfNeeded(for: friend)
                            _ = await (count, saves)
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.md)
                .padding(.bottom, isBelowSocialThreshold ? AppSpacing.md : AppSpacing.xxl)

                if isBelowSocialThreshold {
                    addFriendCTA
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: friendsStore.incomingRequests.isEmpty && friendsStore.outgoingRequestProfiles.isEmpty)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Requests section

    /// Compact card shown above the friend grid whenever there are
    /// incoming or outgoing pending requests. Incoming rows get
    /// deny / accept buttons; outgoing rows show a clock "Sent"
    /// indicator and a cancel button. When both lists are non-empty
    /// the card splits into "Incoming" / "Sent" sub-sections with
    /// a divider. Animates in/out as both lists change.
    @ViewBuilder
    private var requestsSection: some View {
        let hasIncoming = !friendsStore.incomingRequests.isEmpty
        let hasOutgoing = !friendsStore.outgoingRequestProfiles.isEmpty
        if hasIncoming || hasOutgoing {
            let total = friendsStore.incomingRequests.count + friendsStore.outgoingRequestProfiles.count
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.clock.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(appearance.cookbookTitleAccentColor)
                        .accentTextOutline()
                    Text("Requests")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColor.textSecondary)
                    Text("\(total)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppColor.onAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(appearance.cookbookTitleAccentColor)
                        .clipShape(Capsule())
                }
                .padding(.bottom, 2)

                if hasIncoming {
                    if hasOutgoing {
                        Text("Incoming")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppColor.textTertiary)
                            .padding(.bottom, 2)
                    }
                    ForEach(friendsStore.incomingRequests) { request in
                        RequestRow(request: request)
                    }
                }

                if hasIncoming && hasOutgoing {
                    Divider()
                        .padding(.vertical, AppSpacing.xs)
                }

                if hasOutgoing {
                    if hasIncoming {
                        Text("Sent")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppColor.textTertiary)
                            .padding(.bottom, 2)
                    }
                    ForEach(friendsStore.outgoingRequestProfiles) { request in
                        OutgoingRequestRow(request: request)
                    }
                }
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .fill(LinearGradient(
                        colors: [
                            AppColor.surfaceRaised.opacity(0.85),
                            AppColor.surface.opacity(0.85)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(appearance.cookbookTitleAccentColor.opacity(0.25), lineWidth: 1)
            )
            .liftedCard()
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xs)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Below-threshold CTA

    /// "Looking for a friend?" prompt shown below the grid until the
    /// user has 2+ real friends (seed + 2 = 3). Same sheet as the
    /// toolbar `+` button — the CTA is a second, more prominent entry
    /// point that surfaces when the grid is sparse.
    private var addFriendCTA: some View {
        VStack(spacing: AppSpacing.sm) {
            Text("Looking for a friend?")
                .font(AppFont.sectionHeading)
                .foregroundStyle(appearance.cookbookTitleAccentColor)
                .accentTextOutline()
            Text("Add friends to browse their recipes and see what they're cooking.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Haptics.impact(.light)
                showingAddFriend = true
            } label: {
                Label("Add Friend", systemImage: "person.crop.circle.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.onAccent)
                    .accentTextOutline()
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.sm + 2)
                    .background(
                        LinearGradient(
                            colors: [
                                appearance.cookbookTitleAccentColor.opacity(0.95),
                                appearance.cookbookTitleAccentColor.opacity(0.80)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.45), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: appearance.cookbookTitleAccentColor.opacity(0.35), radius: 10, y: 4)
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpacing.lg)
        .padding(.bottom, AppSpacing.xxl)
    }

    private func loadCountIfNeeded(for friend: UserProfileSnapshot) async {
        let id = friend.userRecordName
        if recipeCounts[id] != nil || inFlightCounts.contains(id) { return }
        // Seed friend: recipe count comes from the bundled JSON, no
        // CloudKit query. Last-cooked thumbnail stays nil — the seed
        // doesn't track cooks so the card falls back to the
        // `Friends_Llama_Icon` placeholder, which reads correctly.
        if SeedFriend.isSeed(friend) {
            recipeCounts[id] = SeedFriend.librarySummaries().count
            return
        }
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
        // Seed friend has no CloudKit `RecipeImport` rows to count —
        // resolve to 0 so the secondary meta line falls through to
        // the "Friends since" branch (which itself collapses because
        // the seed has no friendship `acceptedAt`).
        if SeedFriend.isSeed(friend) {
            friendTotalSaves[key] = 0
            return
        }
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

    /// Bottom-left thumbnail size. Same 52pt frame as before — the
    /// slot moved from the trailing edge to under the cooking line,
    /// but the chrome (rounded square, divider stroke, fallback
    /// chain) is unchanged so the visual "card slot" stays familiar.
    private static let thumbnailSize: CGFloat = 52

    @Environment(LlamaProStore.self) private var proStore

    /// Pulse driver for the cooking-now border (lineWidth + opacity).
    /// Mirrors `AccentDot`'s `pulse` flag and animation curve so the
    /// inline dot and the border breathe in sync.
    @State private var pulse: Bool = false

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
                    fallback: AppColor.accent,
                    isGlowing: friend.isCookingNow,
                    outlineWhenIdle: true
                )
                Text(friend.displayName)
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(friend.resolvedAccent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accentTextOutline()
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
                        .foregroundStyle(friend.resolvedAccent)
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
                    friend.resolvedAccent.opacity(
                        friend.isCookingNow ? (pulse ? 0.95 : 0.65) : 0.5
                    ),
                    lineWidth: friend.isCookingNow ? (pulse ? 2.5 : 2.0) : 1.5
                )
        )
        .liftedCard()
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
    /// 2. Otherwise → "Friends since: <date>" using the friendship's
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
                    .foregroundStyle(friend.resolvedAccent)
                Text(saves == 1 ? "1 Save" : "\(saves) Saves")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
            }
        } else if let since = friendsSince {
            Text("Friends since: \(Formatters.date.string(from: since))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColor.textTertiary)
        }
    }

    @ViewBuilder
    private var cookingLine: some View {
        if let title = friend.lastCookedTitle, !title.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "fork.knife")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
                Text("\(Text(friend.isCookingNow ? "Cooking: " : "Last Cooked: ").foregroundStyle(AppColor.textTertiary))\(Text(title).fontWeight(.semibold).foregroundStyle(friend.resolvedAccent))")
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
                        .fill(friend.resolvedAccent.opacity(0.12))
                }
            } else {
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(friend.resolvedAccent.opacity(0.12))
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
                .foregroundStyle(friend.resolvedAccent)
                .padding(7)
        } else {
            Image(SeedFriend.isSeed(friend) && proStore.plan == .yearly ? "Llama-Pro-Icon-Friends-Crown-Sunglasses" : SeedFriend.isSeed(friend) && proStore.isPro ? "Llama-Pro-Icon-Friends-Crown" : "Friends_Llama_Icon")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(friend.resolvedAccent)
                .padding(7)
        }
    }

}

/// One incoming-request row in the requests section header.
/// Compact: filled accent dot + serif display name on the left,
/// deny (xmark) / accept (checkmark) circle buttons on the right.
/// `isProcessing` disables both buttons for the brief window
/// between tap and the store's optimistic row removal.
private struct RequestRow: View {
    let request: FriendsStore.PendingRequest

    @Environment(FriendsStore.self) private var friendsStore
    @State private var isProcessing = false

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            AccentDot(
                hex: request.requester.accentHex,
                fallback: AppColor.accent,
                isGlowing: false,
                outlineWhenIdle: false
            )
            Text(request.requester.displayName)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(request.requester.resolvedAccent)
                .accentTextOutline()
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            HStack(spacing: AppSpacing.xs) {
                // Deny
                Button {
                    Haptics.impact(.light)
                    isProcessing = true
                    Task { await friendsStore.denyRequest(request) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColor.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(AppColor.surface.opacity(0.9))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(AppColor.divider.opacity(0.5), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)

                // Accept
                Button {
                    Haptics.success()
                    isProcessing = true
                    Task { await friendsStore.acceptRequest(request) }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColor.onAccent)
                        .frame(width: 30, height: 30)
                        .background(request.requester.resolvedAccent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(request.requester.resolvedAccent.opacity(0.07))
        )
    }
}

/// One outgoing-request row in the requests section header.
/// Compact: outline accent dot (pending state) + serif display
/// name on the left, a muted clock + "Sent" label and a cancel
/// circle on the right. `isProcessing` disables the cancel button
/// for the brief window before the store's optimistic removal.
private struct OutgoingRequestRow: View {
    let request: FriendsStore.PendingRequest

    @Environment(FriendsStore.self) private var friendsStore
    @State private var isProcessing = false

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            AccentDot(
                hex: request.requester.accentHex,
                fallback: AppColor.accent,
                isGlowing: false,
                outlineWhenIdle: true
            )
            Text(request.requester.displayName)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(request.requester.resolvedAccent)
                .accentTextOutline()
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
                Text("Sent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
            }

            Button {
                Haptics.impact(.light)
                isProcessing = true
                Task { await friendsStore.cancelRequest(to: request.requester) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(AppColor.surface.opacity(0.9))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(AppColor.divider.opacity(0.5), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(request.requester.resolvedAccent.opacity(0.05))
        )
    }
}

#Preview {
    NavigationStack { FriendsTabView() }
        .environment(FriendsStore())
        .environment(AppearanceSettings())
}
