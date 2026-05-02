import SwiftUI

/// Modal sheet presented from the `+` button right of the Friends
/// heading in `ProfileView`. Contains a single text input that
/// debounces 300ms and queries CloudKit for `UserProfile` records
/// whose display name starts with the entered prefix.
///
/// Each result row renders the user's accent-color dot + display
/// name + "Joined <month year>" disambiguator, plus a `+` button
/// whose state reflects the local FriendsStore (a fresh `+` to
/// send, a clock to cancel an outgoing pending request, a checkmark
/// for already-friends, and a hidden row for self).
///
/// Self is filtered out client-side (CK has no easy "exclude this
/// recordName" predicate). The 300ms debounce avoids spamming
/// CloudKit with one query per keystroke during a fast typist's
/// burst.
struct AddFriendSheet: View {
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(FriendsStore.self) private var friendsStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var searchResults: [UserProfileSnapshot] = []
    @State private var isSearching: Bool = false
    @State private var searchError: String? = nil
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFieldFocused: Bool

    private static let debounce: Duration = .milliseconds(300)
    private static let minPrefixLength = 2

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.top, AppSpacing.md)
                    .padding(.bottom, AppSpacing.sm)

                resultsList
            }
            .llamaBackground()
            .navigationTitle("Add a Friend")
            .navigationBarTitleDisplayMode(.inline)
            .tint(appearance.accentColor)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(appearance.accentColor)
                }
            }
            .onAppear {
                // Surface the keyboard immediately — the user came
                // here to type a name, no reason to make them tap
                // the field first.
                DispatchQueue.main.async { searchFieldFocused = true }
            }
            .onDisappear {
                searchTask?.cancel()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var searchField: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppColor.textTertiary)
            TextField("Search by name…", text: $searchText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFieldFocused)
                .onChange(of: searchText) { _, newValue in
                    scheduleSearch(prefix: newValue)
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColor.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppSpacing.sm + 2)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    @ViewBuilder
    private var resultsList: some View {
        if searchText.trimmingCharacters(in: .whitespaces).count < Self.minPrefixLength {
            // Instructional empty state for sub-2-character input.
            // The CK query short-circuits below the floor too; this
            // matches that with friendlier copy than a blank panel.
            instructional("Type at least 2 letters to search.")
        } else if isSearching {
            ProgressView()
                .padding(.top, AppSpacing.xl)
                .frame(maxWidth: .infinity)
        } else if let error = searchError {
            instructional("Search error: \(error)")
        } else if filteredResults.isEmpty {
            instructional("No one matches that name.")
        } else {
            ScrollView {
                VStack(spacing: AppSpacing.sm) {
                    ForEach(filteredResults) { profile in
                        SearchResultRow(profile: profile)
                            .padding(.horizontal, AppSpacing.lg)
                    }
                }
                .padding(.vertical, AppSpacing.sm)
            }
        }
    }

    private func instructional(_ text: String) -> some View {
        Text(text)
            .font(AppFont.caption)
            .foregroundStyle(AppColor.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.sm)
            .frame(maxWidth: .infinity)
    }

    /// Search results minus the local user (self-add is a no-op
    /// footgun; filter client-side since CK can't easily exclude a
    /// specific recordName in BEGINSWITH predicates).
    private var filteredResults: [UserProfileSnapshot] {
        guard let me = UserProfileMirror.cachedRecordID() else {
            return searchResults
        }
        return searchResults.filter { $0.userRecordName != me }
    }

    // MARK: - Search dispatch

    /// Cancel any in-flight search and schedule a fresh one. Returns
    /// immediately on too-short input so callers don't have to
    /// guard. The 300ms debounce window matches the friends-search
    /// spec; rapid typists end up with one network query per natural
    /// pause in their typing.
    private func scheduleSearch(prefix: String) {
        searchTask?.cancel()
        // CloudKit BEGINSWITH is case-sensitive; capitalize so "lo" finds "Lorenzo"
        // even if the user didn't have autocapitalization on.
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(1).uppercased() + prefix.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst()
        guard trimmed.count >= Self.minPrefixLength else {
            isSearching = false
            searchResults = []
            searchError = nil
            return
        }
        // Flip the spinner up synchronously so the resultsList
        // doesn't show a stale "No one matches" for the 300ms
        // debounce window while the user is still typing.
        isSearching = true
        searchError = nil
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: Self.debounce)
            if Task.isCancelled { return }
            do {
                let results = try await CloudKitService.searchUserProfiles(prefix: trimmed)
                if Task.isCancelled { return }
                searchResults = results
                searchError = nil
            } catch {
                if !Task.isCancelled {
                    searchResults = []
                    searchError = error.localizedDescription
                }
            }
            isSearching = false
        }
    }
}

/// One row in the search results. Tracks its own button-state
/// derivation off the FriendsStore so taps update reactively.
private struct SearchResultRow: View {
    let profile: UserProfileSnapshot
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(FriendsStore.self) private var friendsStore

    private static let joinedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private var rowState: RowState {
        if friendsStore.friends.contains(where: { $0.userRecordName == profile.userRecordName }) {
            return .alreadyFriend
        }
        if friendsStore.outgoingRequests[profile.userRecordName] != nil {
            return .pending
        }
        if friendsStore.incomingRequests.contains(where: { $0.requester.userRecordName == profile.userRecordName }) {
            return .incomingPending
        }
        return .canRequest
    }

    @ViewBuilder
    var body: some View {
        if rowState == .alreadyFriend {
            // Tap an already-friend row → push their cookbook
            // inside this sheet's NavigationStack. Prefer the
            // FriendsStore's live snapshot (it carries the latest
            // accent / cooking-now state pushed via subscription)
            // and fall back to the search-result profile if for
            // some reason the store and CK search disagree.
            NavigationLink {
                FriendLibraryView(friend: friendSnapshot)
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private var friendSnapshot: UserProfileSnapshot {
        friendsStore.friends.first { $0.userRecordName == profile.userRecordName } ?? profile
    }

    private var rowContent: some View {
        HStack(spacing: AppSpacing.sm) {
            AccentDot(hex: profile.accentHex, fallback: appearance.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                Text("Joined \(Self.joinedFormatter.string(from: profile.createdAt))")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }

            Spacer(minLength: AppSpacing.sm)

            actionButton
        }
        .padding(AppSpacing.sm + 2)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    @ViewBuilder
    private var actionButton: some View {
        switch rowState {
        case .canRequest:
            Button {
                Haptics.impact(.light)
                Task { await friendsStore.sendRequest(to: profile) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(AppColor.onAccent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(appearance.accentColor))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send friend request")
        case .pending:
            Button {
                Haptics.selection()
                Task { await friendsStore.cancelRequest(to: profile) }
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(appearance.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(AppColor.surfaceSunken))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel friend request")
        case .alreadyFriend:
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppColor.success)
                .frame(width: 32, height: 32)
                .background(Circle().fill(AppColor.success.opacity(0.15)))
                .accessibilityLabel("Already friends")
        case .incomingPending:
            // They've already requested YOU — point them at the
            // Requests section rather than letting them queue a
            // duplicate. Disabled state with a tooltip-style label.
            Text("Pending")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, 4)
                .background(Capsule().fill(AppColor.surfaceSunken))
                .accessibilityLabel("Has already sent you a request")
        }
    }

    private enum RowState {
        case canRequest
        case pending
        case alreadyFriend
        case incomingPending
    }
}

/// Small accent-color circle used in friend rows + search results.
/// Falls back to the local user's accent when the friend's profile
/// has no `accentHex` set (e.g. the cloud schema is fresh and they
/// haven't pushed an accent yet).
struct AccentDot: View {
    let hex: String?
    let fallback: Color
    /// Optional cooking-now flag. When true, the dot pulses with a
    /// soft glow — see implement-social.md › "Presence indicator
    /// (the glowing dot)".
    var isGlowing: Bool = false
    /// When true and not glowing, the dot renders as a hollow circle
    /// stroked in the accent color instead of a filled disc. Used in
    /// the friend cookbook header to encode cooking state into the
    /// indicator itself: filled+pulsing when cooking, outline when
    /// idle.
    var outlineWhenIdle: Bool = false

    @State private var pulse: Bool = false

    private var color: Color {
        if let hex, let parsed = Color(hex: hex) {
            return parsed
        }
        return fallback
    }

    private var isOutline: Bool { outlineWhenIdle && !isGlowing }

    var body: some View {
        Group {
            if isOutline {
                Circle().strokeBorder(color, lineWidth: 1.5)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 12, height: 12)
        .shadow(
            color: color.opacity(isGlowing ? 0.9 : 0),
            radius: isGlowing ? 6 : 0
        )
        .scaleEffect(isGlowing && pulse ? 1.15 : 1.0)
        .animation(
            isGlowing
                ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                : .default,
            value: pulse
        )
        .onAppear { if isGlowing { pulse = true } }
        .onChange(of: isGlowing) { _, newValue in pulse = newValue }
    }
}
