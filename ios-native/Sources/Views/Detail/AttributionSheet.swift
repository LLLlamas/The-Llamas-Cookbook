import SwiftUI
import SwiftData

/// Sheet showing chain attribution for an imported recipe.
/// Reached from the "Originally shared by …" caption in
/// `RecipeDetailView` (slice 6's deferred tap target from
/// slice 5).
///
/// **Three slots, one shape:**
///
/// 1. **Original creator** — name + (optional) tap target if
///    they're a current friend. The tap closes this sheet
///    and navigates to their friend library — one level back
///    out to ProfileView via the `pendingFriendOpenID` signal
///    on `NavigationContext`. (Friend-library navigation is
///    a future enhancement; for now we just show the name.)
///
/// 2. **Imported on** — `Recipe.importedAt`, formatted long-
///    style so the date reads as a record rather than a
///    timestamp. Falls back to the older `sharedAt` field for
///    legacy file/link share imports that predate slice 5.
///
/// 3. **Chain hop** — when `originalSharer != originalCreator`
///    the recipe passed through one or more intermediate
///    friends. We don't store exact chain length (would
///    require a counter denorm field on PublishedRecipe), so
///    the text is qualitative: "via {Sharer}". One hop is
///    common, multiple hops produce the same line. Acceptable
///    fidelity for a delight surface.
///
/// **Read-only.** v1 just shows. Tap-the-creator-name to open
/// their library is deferred — wiring it requires
/// FriendLibraryView reachability from inside a sheet that
/// isn't itself in the friends nav stack. The
/// `friendOpenAction` closure is wired up here so a future
/// commit can light the path without re-touching the sheet
/// shape.
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
            .background(AppColor.background)
            .navigationTitle("Attribution")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(appearance.accentColor)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    /// Render path when the creator is a current friend — same
    /// row chrome as the static name path above, but the row is
    /// a button. Tapping it pops the sheet and (in v2+) navigates
    /// to their friend library. v1 just dismisses; the user can
    /// reach the library through ProfileView's friends list.
    private func friendButton(for friend: UserProfileSnapshot) -> some View {
        Button {
            Haptics.selection()
            // v1: just dismiss the sheet. v2 will route through
            // a NavigationContext signal so the user lands on
            // FriendLibraryView for this creator. The button
            // affordance reads correctly today even without the
            // navigation — users see the chevron and tap to
            // dismiss, which is the documented behavior of the
            // Done button anyway.
            dismiss()
        } label: {
            creatorNameRow(displayName: friend.displayName, accentHex: friend.accentHex)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Tap to close")
    }

    private func creatorNameRow(displayName: String, accentHex: String?) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Circle()
                .fill(creatorDot(accentHex: accentHex))
                .frame(width: 12, height: 12)
            Text(displayName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    // MARK: - Resolution helpers

    /// Slice 5 fields preferred (canonical chain attribution);
    /// fall back to the older file/link share fields for
    /// legacy imports that predate the social slice. Same
    /// two-source resolution `RecipeDetailView.provenanceLine`
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
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: date)
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
