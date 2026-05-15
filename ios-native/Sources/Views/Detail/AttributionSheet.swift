import SwiftUI
import SwiftData

/// Sheet showing chain attribution for an imported recipe.
/// Reached from the "Originally shared by …" caption in
/// `RecipeDetailView`.
///
/// **Three slots, one shape:**
///
/// 1. **Original creator** — name, plus a NavigationLink push to
///    their `FriendLibraryView` when they're a current friend.
///    The sheet's own NavigationStack hosts the push (same
///    pattern as `ImportersListSheet`), so the user drills in
///    and pops back without dismissing first. Non-friends
///    render as plain text.
///
/// 2. **Imported on** — `Recipe.importedAt`, formatted as a
///    date so it reads as a record rather than a timestamp.
///    Falls back to the older `sharedAt` field for legacy
///    file/link share imports that predate chain attribution.
///
/// 3. **Chain hop** — when `originalSharer != originalCreator`
///    the recipe passed through one or more intermediate
///    friends. We don't store exact chain length (would
///    require a counter denorm field on PublishedRecipe), so
///    the text is qualitative: "via {Sharer}". One hop is
///    common, multiple hops produce the same line. Acceptable
///    fidelity for a delight surface.
struct AttributionSheet: View {
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(FriendsStore.self) private var friendsStore
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    creatorSection
                    importDateSection
                    if let hopText = chainHopText {
                        chainSection(hopText: hopText)
                    }
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.md)
                .padding(.bottom, AppSpacing.xxl)
            }
            .llamaBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Done")
                            .foregroundStyle(appearance.accentColor)
                            .accentTextOutline()
                    }
                }
            }
        }
    }

    // MARK: - Creator section

    private var creatorSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("ORIGINAL CREATOR")
                .eyebrowStyle(AppColor.textTertiary)
            if let friend = friendForCreator() {
                friendButton(for: friend)
            } else {
                creatorNameRow(displayName: creatorDisplayName, accentHex: nil)
            }
        }
        .surfaceCard()
    }

    /// Render path when the creator is a current friend — wraps the
    /// name row in a NavigationLink that pushes their cookbook.
    /// Mirrors `ImportersListSheet`'s in-sheet push pattern: the
    /// sheet's own NavigationStack hosts the FriendLibraryView, so
    /// the user can drill in and pop back without dismissing first.
    private func friendButton(for friend: UserProfileSnapshot) -> some View {
        NavigationLink {
            FriendLibraryView(friend: friend)
        } label: {
            creatorNameRow(displayName: friend.displayName, accentHex: friend.accentHex, showsChevron: true)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(friend.displayName)'s cookbook")
    }

    private func creatorNameRow(displayName: String, accentHex: String?, showsChevron: Bool = false) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Circle()
                .fill(creatorDot(accentHex: accentHex))
                .frame(width: 12, height: 12)
            Text(displayName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
    }

    private func creatorDot(accentHex: String?) -> Color {
        if let hex = accentHex, let color = Color(hex: hex) {
            return color
        }
        return appearance.accentColor
    }

    // MARK: - Import date section

    private var importDateSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("IMPORTED")
                .eyebrowStyle(AppColor.textTertiary)
            Text(formattedImportDate)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
        }
        .surfaceCard()
    }

    // MARK: - Chain section

    private func chainSection(hopText: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("VIA")
                .eyebrowStyle(AppColor.textTertiary)
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(appearance.accentColor)
                Text(hopText)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .surfaceCard()
    }

    // MARK: - Resolution helpers

    /// Chain-attribution fields preferred (canonical chain
    /// attribution); fall back to the older file/link share
    /// fields for legacy imports that predate chain attribution.
    /// Same two-source resolution `RecipeDetailView.provenanceLine`
    /// uses, kept aligned so both surfaces always agree.
    private var creatorDisplayName: String {
        if let friend = friendsStore.friends.first(where: {
            $0.userRecordName == recipe.originalCreatorUserRecordName
        }) {
            // Prefer live profile data — the friend may have
            // changed their display name since the recipe was
            // imported, and we want to surface the current
            // value. Falls back to the denormalized name when
            // the creator isn't (or no longer is) a friend.
            return friend.displayName
        }
        if let name = RecipeShare.cappedDisplayName(recipe.originalCreatorDisplayName) {
            return name
        }
        if let name = RecipeShare.cappedDisplayName(recipe.sharedBy) {
            return name
        }
        return "Unknown"
    }

    /// Returns the friend snapshot if the chain root is in the
    /// local user's friends list — drives the tappable name row.
    /// Nil for imports from non-friends or for the legacy
    /// file/link share path (which doesn't carry a userRecordName).
    private func friendForCreator() -> UserProfileSnapshot? {
        guard let creatorID = recipe.originalCreatorUserRecordName else {
            return nil
        }
        return friendsStore.friends.first { $0.userRecordName == creatorID }
    }

    private var formattedImportDate: String {
        let date = recipe.importedAt ?? recipe.sharedAt ?? recipe.createdAt
        return Formatters.date.string(from: date)
    }

    /// "via Sharer" line, only when the chain has at least one
    /// intermediate hop (sharer is different from creator). Nil
    /// when sharer == creator (direct import — no chain) or
    /// when sharer info isn't recorded (legacy import path).
    private var chainHopText: String? {
        guard let sharerName = RecipeShare.cappedDisplayName(recipe.originalSharerDisplayName),
              let sharerID = recipe.originalSharerUserRecordName,
              let creatorID = recipe.originalCreatorUserRecordName,
              sharerID != creatorID
        else { return nil }
        return "Passed through \(sharerName)"
    }
}
