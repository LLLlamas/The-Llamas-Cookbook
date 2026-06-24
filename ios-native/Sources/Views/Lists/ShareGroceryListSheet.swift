import SwiftUI

/// Pick which friend(s) to share a grocery list with. The list goes live
/// on CloudKit (`GroceryListShare`) and a mirror appears in each
/// recipient's Lists tab; from then on every check-off syncs both ways and
/// recipients get a push when it changes. This is the "send the list to my
/// husband so he can shop it" flow.
///
/// Friends come from `FriendsStore` (the synthetic "Your Llama" seed is
/// filtered out — you can't share a real list with a bundled demo friend).
/// Re-opening on an already-shared list pre-selects the current recipients,
/// so this doubles as "change who it's shared with."
struct ShareGroceryListSheet: View {
    let list: GroceryList
    let ownerName: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(FriendsStore.self) private var friendsStore
    @Environment(GroceryListStore.self) private var groceryStore

    @State private var selectedIDs: Set<String>
    @State private var isSharing = false
    @State private var failed = false

    private var accent: Color { appearance.cookbookTitleAccentColor }

    /// Real friends only — the seed friend has no CloudKit identity to
    /// share to.
    private var friends: [UserProfileSnapshot] {
        friendsStore.friends.filter { !SeedFriend.isSeed($0) }
    }

    private var isSignedIntoCloud: Bool {
        UserProfileMirror.cachedRecordID() != nil
    }

    init(list: GroceryList, ownerName: String) {
        self.list = list
        self.ownerName = ownerName
        _selectedIDs = State(initialValue: Set(list.sharedRecipientIDs))
    }

    var body: some View {
        NavigationStack {
            Group {
                if !isSignedIntoCloud {
                    notSignedInState
                } else if friends.isEmpty {
                    noFriendsState
                } else {
                    friendList
                }
            }
            .llamaBackground()
            .navigationTitle("Share list")
            .navigationBarTitleDisplayMode(.inline)
            .tint(accent)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(accent)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSignedIntoCloud && !friends.isEmpty {
                    shareButton
                }
            }
            .overlay { if isSharing { sharingOverlay } }
            .alert("Couldn't share", isPresented: $failed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Sharing needs iCloud and a network connection. Please try again.")
            }
        }
    }

    // MARK: - Friend list

    private var friendList: some View {
        List {
            Section {
                ForEach(friends) { friend in
                    Button {
                        toggle(friend)
                    } label: {
                        friendRow(friend)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Pick who's shopping")
            } footer: {
                Text("They'll see this list in their Lists tab, get a heads-up when it changes, and every check-off syncs back to you live.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func friendRow(_ friend: UserProfileSnapshot) -> some View {
        let selected = selectedIDs.contains(friend.userRecordName)
        return HStack(spacing: AppSpacing.sm) {
            Circle()
                .fill(friend.resolvedAccent)
                .frame(width: 30, height: 30)
                .overlay(
                    Text(initial(for: friend.displayName))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppColor.onAccent)
                )
            Text(friend.displayName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(selected ? accent : AppColor.textTertiary)
        }
        .contentShape(Rectangle())
    }

    private func initial(for name: String) -> String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    // MARK: - Share button

    private var shareButton: some View {
        Button {
            Task { await share() }
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .bold))
                Text(shareButtonLabel)
                    .font(.system(size: 17, weight: .bold))
            }
            .foregroundStyle(AppColor.onAccent)
            .accentTextOutline()
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.md)
            .background(selectedIDs.isEmpty ? AppColor.textTertiary : accent)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(.lifted)
        .disabled(selectedIDs.isEmpty || isSharing)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
        .background(.regularMaterial)
    }

    private var shareButtonLabel: String {
        let n = selectedIDs.count
        if n == 0 { return "Choose a friend" }
        if n == 1 { return "Share with 1 friend" }
        return "Share with \(n) friends"
    }

    // MARK: - Empty states

    private var noFriendsState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "person.2")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(accent.opacity(0.85))
                .accentTextOutline()
                .llamaFloat()
            Text("No friends yet")
                .font(AppFont.sectionHeading)
                .foregroundStyle(accent)
                .accentTextOutline()
            Text("Add a friend from the Friends tab first, then come back to share this list with them.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notSignedInState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(accent.opacity(0.85))
                .accentTextOutline()
                .llamaFloat()
            Text("Sign in to share")
                .font(AppFont.sectionHeading)
                .foregroundStyle(accent)
                .accentTextOutline()
            Text("Sharing a list with a friend needs iCloud. Sign in from your Profile, then try again.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sharingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: AppSpacing.md) {
                LlamaProgressIndicator(size: 96, accent: accent)
                Text("Sending to the store…")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
            .padding(AppSpacing.xl)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .transition(.opacity)
    }

    // MARK: - Actions

    private func toggle(_ friend: UserProfileSnapshot) {
        Haptics.selection()
        if selectedIDs.contains(friend.userRecordName) {
            selectedIDs.remove(friend.userRecordName)
        } else {
            selectedIDs.insert(friend.userRecordName)
        }
    }

    private func share() async {
        let selected = friends.filter { selectedIDs.contains($0.userRecordName) }
        guard !selected.isEmpty else { return }
        isSharing = true
        let ids = selected.map(\.userRecordName)
        let label = selected.map(\.displayName).joined(separator: ", ")
        let ok = await groceryStore.shareList(
            list,
            withRecipientIDs: ids,
            recipientLabel: label,
            ownerName: ownerName
        )
        isSharing = false
        if ok {
            Haptics.success()
            dismiss()
        } else {
            Haptics.warning()
            failed = true
        }
    }
}
