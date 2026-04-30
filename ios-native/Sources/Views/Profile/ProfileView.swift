import SwiftUI
import SwiftData
import AuthenticationServices

/// Profile sheet — primary surface for the social slice. Reached from
/// `LibraryView`'s person-circle toolbar button. Sheet-presented (same
/// pattern as `AccentColorPicker`) so dismiss is a swipe-down or the
/// Done button.
///
/// Layout (signed-in):
///
///   ┌──────────────────────────────────────────┐
///   │ [⚙]                              [Done]  │  ← cog (leading) + Done (trailing)
///   │              [llama logo]                │
///   │            {Name} Cookbook               │  ← title; first word reflects display name
///   │           [ Display Name ✎ ]             │  ← editable card below; commit updates title
///   │         Last cooked: <Title>             │  ← only when set
///   │                                          │
///   │  Requests (N)                            │  ← always visible when signed-in;
///   │  [● Name           [Deny] [Approve]]     │     empty-state placeholder when N=0
///   │                                          │
///   │  Friends                          [+]    │  ← + opens AddFriendSheet
///   │  [● Name              ]              A   │  ← A–Z scrub on right
///   │  [● Name              ]              B   │
///   │  ...                                  C  │
///   └──────────────────────────────────────────┘
///
/// The cog icon owns Sign Out + Delete Account.
///
/// Title binding: the "Llamas" word in the header is bound to the
/// signed-in user's display name — committing the DISPLAY NAME card's
/// inline editor flows through `commitNameEdit` → identity update →
/// header re-render with `{newName} Cookbook`. Signed-out state falls
/// back to the literal "Llamas Cookbook" branding.
struct ProfileView: View {
    @Environment(UserAccount.self) private var userAccount
    @Environment(OwnerProfile.self) private var ownerProfile
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(FriendsStore.self) private var friendsStore
    @Environment(\.dismiss) private var dismiss

    /// All recipes — used only to derive `lastCookedRecipe` for the
    /// "Last cooked: …" line. SwiftData lazy-loads, and ProfileView
    /// is sheet-only (not on every frame), so the cost is acceptable.
    /// Sort happens in `lastCookedRecipe` rather than the @Query
    /// because SwiftData's optional-keypath sort handling has been
    /// finicky across iOS 17/18; in-memory sort over a small set is
    /// reliably correct.
    @Query private var allRecipes: [Recipe]

    @State private var nameDraft: String = ""
    @State private var isEditingName: Bool = false
    @State private var showingDeleteConfirm: Bool = false
    @State private var showingSettings: Bool = false
    @State private var showingAddFriend: Bool = false
    @State private var pendingFriendRemoval: UserProfileSnapshot? = nil
    @State private var letterScrollAnchor: String? = nil
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: AppSpacing.lg) {
                        header

                        switch userAccount.status {
                        case .signedOut, .signingIn:
                            // Apple's button surfaces its own modal; we
                            // share visual treatment between .signedOut
                            // and .signingIn. iOS 18 occasionally drops
                            // the SignInWithAppleButton onCompletion on
                            // swipe-down dismiss and strands status at
                            // .signingIn — `cancelInFlightSignIn()` in
                            // .task recovers.
                            signedOutBody
                        case .signedIn(let identity):
                            signedInBody(identity: identity)
                        case .signInFailed(let message):
                            VStack(spacing: AppSpacing.md) {
                                signedOutBody
                                errorBanner(message: message)
                            }
                        }

                        Spacer(minLength: AppSpacing.xl)
                    }
                    .padding(AppSpacing.lg)
                }
                .scrollContentBackground(.hidden)
                .llamaBackground()
                .overlay(alignment: .trailing) {
                    // Letter index for the friends list. Only meaningful
                    // when signed in AND the friends list has enough
                    // entries to scroll — under ~5 friends, the strip
                    // is more visual noise than help, so suppress it
                    // until the threshold is crossed.
                    if userAccount.status.isSignedIn && friendsStore.friends.count >= 5 {
                        LetterIndex(
                            letters: LetterIndex.allLetters,
                            populated: populatedFriendLetters,
                            accent: appearance.accentColor,
                            externalHighlightLetter: nil
                        ) { letter in
                            guard let target = firstFriend(atOrAfter: letter) else { return }
                            Haptics.selection()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(friendRowID(target), anchor: .top)
                            }
                        }
                        .padding(.trailing, 4)
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .tint(appearance.accentColor)
            .toolbar {
                if userAccount.status.isSignedIn {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Haptics.selection()
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(appearance.accentColor)
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(appearance.accentColor)
                }
            }
            .alert(
                "Delete account?",
                isPresented: $showingDeleteConfirm
            ) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    userAccount.deleteAccount()
                    friendsStore.clearOnSignOut()
                    showingSettings = false
                }
            } message: {
                Text("This signs you out, removes your friends, and forgets your in-app identity. Recipes saved on this device will not be removed.")
            }
            .alert(
                "Remove friend?",
                isPresented: friendRemovalAlertPresented,
                presenting: pendingFriendRemoval
            ) { friend in
                Button("Cancel", role: .cancel) {
                    pendingFriendRemoval = nil
                }
                Button("Remove", role: .destructive) {
                    let toRemove = friend
                    pendingFriendRemoval = nil
                    Task { await friendsStore.removeFriend(toRemove) }
                }
            } message: { friend in
                Text("\(friend.displayName) will be removed from your friends list. You won't see each other's cookbooks in Friends.")
            }
            .sheet(isPresented: $showingSettings) {
                settingsSheet
            }
            .sheet(isPresented: $showingAddFriend) {
                AddFriendSheet()
                    .environment(appearance)
                    .environment(friendsStore)
            }
            .task {
                userAccount.cancelInFlightSignIn()
                await friendsStore.refresh()
            }
            .onChange(of: userAccount.status.isSignedIn) { _, newValue in
                // React to sign-in transitions so the friends list
                // re-pulls the moment SIWA settles. `refresh()`
                // falls back to fetching the iCloud user record ID
                // directly when the mirror cache is still empty
                // (i.e. `bindAfterSignIn` hasn't completed yet), so
                // no artificial delay is needed.
                if newValue {
                    Task { await friendsStore.refresh() }
                }
                // Sign-out path: ProfileView's explicit Sign Out /
                // Delete handlers already call
                // friendsStore.clearOnSignOut(), so no work here.
            }
            .onChange(of: friendsStore.friends.count) { oldCount, newCount in
                // First-friend transition (0 → 1+): backfill every
                // existing recipe to CloudKit so the friend has
                // something to look at on day one. The service's
                // bulk-publish path is idempotent + UserDefaults-
                // gated, so subsequent first-friend events on the
                // same install no-op. ProfileView holds the @Query
                // for recipes already (used by Last Cooked), so
                // this is the natural firing site.
                if oldCount == 0 && newCount > 0 {
                    let snapshot = allRecipes
                    Task {
                        await LibraryMirrorService.shared.bulkPublishIfNeeded(
                            recipes: snapshot
                        )
                    }
                }
            }
        }
    }

    // MARK: - Header

    /// Header is anchored by the llama logo; the title underneath
    /// reads `{displayName} Cookbook` when signed-in, falling back
    /// to the literal "Llamas Cookbook" branding for signed-out
    /// state. The displayName flows from `identity.displayName`,
    /// so committing the DISPLAY NAME card's inline editor
    /// re-renders the title automatically.
    private var header: some View {
        VStack(spacing: AppSpacing.sm) {
            LlamaLogo(size: 96, shadowColor: appearance.accentColor)
            Text(headerTitle)
                .font(AppFont.recipeTitle)
                .foregroundStyle(appearance.accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, AppSpacing.md)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSpacing.md)
    }

    private var headerTitle: String {
        StringCase.cookbookTitle(displayName: userAccount.status.identity?.displayName)
    }

    // MARK: - Signed-out body (unchanged from slice 1)

    private var signedOutBody: some View {
        VStack(spacing: AppSpacing.lg) {
            Text("Sign in to send recipes to friends")
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.center)

            Text("Optional — only needed to send recipes directly to friends in the app. The file and link share options keep working without an account.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.md)

            SignInWithAppleButton(.signIn) { request in
                SignInWithAppleService.configure(request)
            } onCompletion: { result in
                do {
                    let credential = try SignInWithAppleService.processCompletion(result)
                    userAccount.completeSignIn(
                        with: credential,
                        ownerProfile: ownerProfile,
                        accentHex: appearance.accentColor.toHex
                    )
                    Haptics.success()
                    // The friends-list refresh happens via the
                    // `.onChange(of: status.isSignedIn)` handler at
                    // the NavigationStack level — no explicit fire
                    // here.
                } catch {
                    userAccount.failSignIn(with: error)
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .padding(.horizontal, AppSpacing.md)
        }
        .padding(.vertical, AppSpacing.lg)
        .frame(maxWidth: .infinity)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    // MARK: - Signed-in body

    @ViewBuilder
    private func signedInBody(identity: UserAccount.UserIdentity) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            displayNameRow(identity: identity)

            if let lastCooked = lastCookedRecipe {
                lastCookedLine(recipe: lastCooked)
            }

            requestsSection

            friendsSection
        }
    }

    // MARK: - Display name row

    /// Editable display-name card. The committed value drives the
    /// `{displayName} Cookbook` header above via `commitNameEdit` →
    /// `userAccount.updateDisplayName` → `identity.displayName`
    /// re-read in `headerTitle`.
    private func displayNameRow(identity: UserAccount.UserIdentity) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("DISPLAY NAME")
                .eyebrowStyle(AppColor.textTertiary)
            HStack(spacing: AppSpacing.sm) {
                if isEditingName {
                    TextField("Your name", text: $nameDraft)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($nameFieldFocused)
                        .font(AppFont.sectionHeading)
                        .foregroundStyle(AppColor.textPrimary)
                        .onSubmit { commitNameEdit() }
                    Button {
                        commitNameEdit()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(appearance.accentColor)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(identity.displayName)
                        .font(AppFont.sectionHeading)
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer(minLength: 0)
                    Button {
                        nameDraft = identity.displayName
                        isEditingName = true
                        DispatchQueue.main.async { nameFieldFocused = true }
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(appearance.accentColor)
                            .frame(width: 32, height: 32)
                            .background(AppColor.surfaceSunken)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit display name")
                }
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    // MARK: - Last cooked

    /// Most-recently-cooked recipe in the local library. Powers the
    /// "Last cooked: <Title>" line below Display Name. Driven off the
    /// local SwiftData store rather than the cloud-side
    /// `UserProfile.lastCookedTitle` since both are kept in sync by
    /// `UserProfileMirror.recordCookCompleted` and the local query is
    /// faster. In-memory filter+max keeps the predicate simple and
    /// avoids SwiftData's optional-keypath sort quirks.
    private var lastCookedRecipe: Recipe? {
        allRecipes
            .filter { $0.lastCookedAt != nil }
            .max(by: { ($0.lastCookedAt ?? .distantPast) < ($1.lastCookedAt ?? .distantPast) })
    }

    private func lastCookedLine(recipe: Recipe) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: "fork.knife")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.textTertiary)
            Text("Last cooked: ")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
            +
            Text(recipe.title)
                .font(AppFont.caption.weight(.semibold))
                .foregroundStyle(appearance.accentColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.sm)
    }

    // MARK: - Requests section

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("REQUESTS (\(friendsStore.incomingRequests.count))")
                .eyebrowStyle(AppColor.textTertiary)

            if friendsStore.incomingRequests.isEmpty {
                emptyRequestsBody
            } else {
                VStack(spacing: AppSpacing.xs) {
                    ForEach(friendsStore.incomingRequests) { request in
                        requestRow(request: request)
                    }
                }
            }
        }
    }

    private var emptyRequestsBody: some View {
        VStack(spacing: AppSpacing.xs) {
            Text("No new requests.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
            Text("Friend requests will appear here.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.lg)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func requestRow(request: FriendsStore.PendingRequest) -> some View {
        HStack(spacing: AppSpacing.sm) {
            AccentDot(
                hex: request.requester.accentHex,
                fallback: appearance.accentColor,
                isGlowing: request.requester.isCookingNow
            )
            Text(request.requester.displayName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: AppSpacing.sm)
            Button {
                Haptics.selection()
                Task { await friendsStore.denyRequest(request) }
            } label: {
                Text("Deny")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.sm)
                            .stroke(AppColor.divider, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            Button {
                Haptics.success()
                Task { await friendsStore.acceptRequest(request) }
            } label: {
                Text("Approve")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppColor.onAccent)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 6)
                    .background(appearance.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpacing.sm + 2)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    // MARK: - Friends section

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("FRIENDS")
                    .eyebrowStyle(AppColor.textTertiary)
                if friendsStore.isRefreshing && friendsStore.friends.isEmpty {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.leading, AppSpacing.xs)
                }
                Spacer(minLength: 0)
                Button {
                    Haptics.impact(.light)
                    showingAddFriend = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(AppColor.onAccent)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(appearance.accentColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a friend")
            }

            if friendsStore.friends.isEmpty {
                emptyFriendsBody
            } else {
                VStack(spacing: AppSpacing.xs) {
                    ForEach(friendsStore.friends) { friend in
                        friendRow(friend: friend)
                            .id(friendRowID(friend))
                    }
                }
            }
        }
    }

    private var emptyFriendsBody: some View {
        VStack(spacing: AppSpacing.xs) {
            Text("No friends yet.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
            Text("Tap + to find someone you know.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.lg)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func friendRow(friend: UserProfileSnapshot) -> some View {
        // NavigationLink pushes the friend's library inside the
        // Profile sheet's NavigationStack. Tap navigates; long-
        // press opens the contextMenu (Remove). `.buttonStyle(.plain)`
        // keeps the row's visual treatment intact — without it, the
        // link would tint the row's content text.
        NavigationLink {
            FriendLibraryView(friend: friend)
        } label: {
            HStack(spacing: AppSpacing.sm) {
                AccentDot(
                    hex: friend.accentHex,
                    fallback: appearance.accentColor,
                    isGlowing: friend.isCookingNow
                )
                Text(friend.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
            }
            .padding(AppSpacing.sm + 2)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                pendingFriendRemoval = friend
            } label: {
                Label("Remove friend", systemImage: "person.fill.xmark")
            }
        }
    }

    // MARK: - Settings sheet (cog menu)

    private var settingsSheet: some View {
        NavigationStack {
            VStack(spacing: AppSpacing.md) {
                Spacer().frame(height: AppSpacing.md)

                Button {
                    Haptics.selection()
                    userAccount.signOut()
                    friendsStore.clearOnSignOut()
                    showingSettings = false
                } label: {
                    settingsButtonLabel(title: "Sign out", role: .neutral)
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.warning()
                    showingDeleteConfirm = true
                } label: {
                    settingsButtonLabel(title: "Delete account", role: .destructive)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, AppSpacing.lg)
            .llamaBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .tint(appearance.accentColor)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingSettings = false }
                        .foregroundStyle(appearance.accentColor)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func settingsButtonLabel(title: String, role: SettingsButtonRole) -> some View {
        let foreground: Color = role == .destructive ? AppColor.destructive : AppColor.textSecondary
        let stroke: Color = role == .destructive ? AppColor.destructive.opacity(0.5) : AppColor.divider
        return Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.sm + 4)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(stroke, lineWidth: 1)
            )
    }

    private enum SettingsButtonRole {
        case neutral
        case destructive
    }

    // MARK: - Misc helpers

    private func errorBanner(message: String) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColor.destructive)
            Text(message)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.md)
        .background(AppColor.destructive.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.destructive.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func commitNameEdit() {
        userAccount.updateDisplayName(nameDraft)
        if let identity = userAccount.status.identity {
            ownerProfile.userName = identity.displayName
        }
        isEditingName = false
        nameFieldFocused = false
        Haptics.success()
    }

    private var friendRemovalAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingFriendRemoval != nil },
            set: { if !$0 { pendingFriendRemoval = nil } }
        )
    }

    // MARK: - Letter-index plumbing for friends list

    private var populatedFriendLetters: Set<String> {
        Set(friendsStore.friends.map { LetterIndex.bucket(for: $0.displayName) })
    }

    /// Stable id used by the `ScrollViewReader` to scroll to a
    /// specific friend row when the user scrubs a letter. Prefixed
    /// with `friend-` so it can't collide with any other id space
    /// SwiftUI synthesizes inside the same scroll view.
    private func friendRowID(_ friend: UserProfileSnapshot) -> String {
        "friend-\(friend.userRecordName)"
    }

    /// Find the first friend whose section letter is `letter` or the
    /// next populated letter after it. Mirrors `LibraryView`'s
    /// firstRecipe(atOrAfter:) behavior so taps on dimmed letters
    /// remain useful instead of no-ops.
    private func firstFriend(atOrAfter letter: String) -> UserProfileSnapshot? {
        guard let startIndex = LetterIndex.allLetters.firstIndex(of: letter) else { return nil }
        let populated = populatedFriendLetters
        for candidate in LetterIndex.allLetters[startIndex...] where populated.contains(candidate) {
            return friendsStore.friends.first { LetterIndex.bucket(for: $0.displayName) == candidate }
        }
        return nil
    }
}
