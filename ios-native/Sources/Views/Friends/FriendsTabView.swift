import SwiftUI

/// Friends tab — card grid mirroring the Library's card chrome so the
/// surface feels populated even with a handful of friends. Each card
/// surfaces the friend's display name, presence dot, cooking /
/// last-cooked line, and the count of recipes they've published.
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

    @State private var showingAddFriend = false
    @State private var recipeCounts: [String: Int] = [:]
    @State private var inFlightCounts: Set<String> = []

    var body: some View {
        Group {
            if friendsStore.friends.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .llamaBackground()
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .tint(appearance.accentColor)
        .toolbar {
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
            Image("Friends_Llama_Icon")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 160, height: 160)
                .foregroundStyle(appearance.accentColor)
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
                            fallbackAccent: appearance.accentColor
                        )
                    }
                    .buttonStyle(.plain)
                    .task(id: friend.userRecordName) {
                        await loadCountIfNeeded(for: friend)
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
        }
    }
}

/// One friend tile in the Friends-tab grid. Mirrors the visual chrome
/// of `RecipeCardView` (translucent gradient surface, same stroke, same
/// shadow stack) so the two surfaces read as the same kind of object.
/// Tinted in the friend's resolved accent — title text + presence dot
/// + recipe-count badge — so visiting Marco's tile *feels like Marco's*
/// the same way `FriendLibraryView` does on push.
private struct FriendCardView: View {
    let friend: UserProfileSnapshot
    let recipeCount: Int?
    let fallbackAccent: Color

    private var friendAccent: Color {
        if let hex = friend.accentHex, let color = Color(hex: hex) {
            return color
        }
        return fallbackAccent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .top, spacing: AppSpacing.xs) {
                Text(friend.displayName)
                    .font(AppFont.sectionHeading)
                    .foregroundStyle(friendAccent)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: -0.4, y: 0)
                    .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0.4, y: 0)
                    .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0, y: -0.4)
                    .shadow(color: AppColor.textPrimary.opacity(0.22), radius: 0, x: 0, y: 0.4)
                    .shadow(color: AppColor.shadow, radius: 1.5, x: 0, y: 1)
                Spacer(minLength: 0)
                AccentDot(
                    hex: friend.accentHex,
                    fallback: fallbackAccent,
                    isGlowing: friend.isCookingNow,
                    outlineWhenIdle: true
                )
            }

            cookingLine

            Spacer(minLength: 0)

            recipeCountBadge
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
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

    @ViewBuilder
    private var cookingLine: some View {
        if let title = friend.lastCookedTitle, !title.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
                (Text(friend.isCookingNow ? "Cooking: " : "Last cooked: ")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
                + Text(title)
                    .font(AppFont.caption.weight(.semibold))
                    .foregroundStyle(friendAccent))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        } else if friend.isCookingNow {
            HStack(spacing: 4) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
                Text("Cooking now")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var recipeCountBadge: some View {
        if let count = recipeCount {
            HStack(spacing: 4) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(count == 1 ? "1 recipe" : "\(count) recipes")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(AppColor.accentDeep)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 3)
            .background(Capsule().fill(friendAccent.opacity(0.15)))
        }
    }
}

#Preview {
    NavigationStack { FriendsTabView() }
        .environment(FriendsStore())
        .environment(AppearanceSettings())
}
