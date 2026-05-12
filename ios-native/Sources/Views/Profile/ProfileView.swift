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
    /// How this view is being hosted. The legacy presentation is the
    /// `LibraryView` toolbar sheet, which renders a Done button and
    /// dismisses on tap. The bottom-tab presentation hides Done (the
    /// tab bar is the affordance to leave) and wraps the same content
    /// in a navigation-stack-friendly shape so pushes (e.g. tapping
    /// the Last Cooked line) work the same way the friend-library
    /// surfaces do.
    enum Presentation {
        case sheet
        case tab
    }

    var presentation: Presentation = .sheet

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

    /// Diagnostic state for the "Re-sync profile" button — exposes
    /// CloudKit upsert errors that would otherwise be silently
    /// swallowed by the fire-and-forget bind path. Tracks in-flight
    /// state so the button can show a spinner, and the most recent
    /// result so the user can see whether their record landed.
    @State private var isResyncingProfile: Bool = false
    @State private var resyncResultMessage: String? = nil
    @State private var resyncSucceeded: Bool = false

    /// Diagnostic state for the "Re-publish library" button — drives
    /// the spinner and the inline result message that surfaces
    /// per-recipe success/failure counts plus the first CKError so
    /// the user can see whether their bulk publish actually landed.
    @State private var isRepublishingLibrary: Bool = false
    @State private var republishResultMessage: String? = nil
    @State private var republishSucceeded: Bool = false

    var body: some View {
        // When presented as a sheet from LibraryView's toolbar, we own
        // our own NavigationStack so the friend-library push has
        // somewhere to land. When hosted as a bottom-tab, RootView's
        // tab provides the NavigationStack — nesting another one here
        // would double the chrome and break navigation pushes.
        Group {
            if presentation == .sheet {
                NavigationStack { content }
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
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
            .navigationDestination(for: Recipe.self) { recipe in
                RecipeDetailView(recipe: recipe)
            }
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
                                .accentTextOutline()
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                if presentation == .sheet {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Text("Done")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(appearance.accentColor)
                                .accentTextOutline()
                        }
                    }
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
                // First-real-friend transition: backfill every
                // existing recipe to CloudKit so the friend has
                // something to look at on day one. The service's
                // bulk-publish path is idempotent + UserDefaults-
                // gated, so subsequent first-friend events on the
                // same install no-op. ProfileView holds the @Query
                // for recipes already (used by Last Cooked), so
                // this is the natural firing site.
                //
                // The synthetic "Your Llama" seed friend ships pre-
                // installed and parks `friends.count` at 1 from
                // install onward, so the comparison fires on the
                // 1 → 2+ transition (= first real friend added)
                // rather than the bare 0 → 1+ one.
                if oldCount <= 1 && newCount > 1 {
                    let snapshot = allRecipes
                    Task {
                        await LibraryMirrorService.shared.bulkPublishIfNeeded(
                            recipes: snapshot
                        )
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
                .accentTextOutline()
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
        // Wrapped in a NavigationLink so tapping the eyebrow pushes
        // the recipe's Detail. `.buttonStyle(.plain)` removes the
        // default link tinting / chrome — the inner Text stack keeps
        // the exact font, size, and color it had before, the link
        // affordance is purely behavioral.
        NavigationLink(value: recipe) {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
                Text("\(Text("Last cooked: ").foregroundStyle(AppColor.textTertiary))\(Text(recipe.title).fontWeight(.semibold).foregroundStyle(appearance.accentColor))")
                    .font(AppFont.caption)
                    .accentTextOutline()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Requests section

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Text("REQUESTS (\(friendsStore.incomingRequests.count + friendsStore.outgoingRequestProfiles.count))")
                    .eyebrowStyle(AppColor.textTertiary)
                Spacer(minLength: 0)
                Button {
                    Haptics.selection()
                    Task { await friendsStore.refresh() }
                } label: {
                    if friendsStore.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(appearance.accentColor)
                            .accentTextOutline()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh friends and requests")
                .disabled(friendsStore.isRefreshing)
            }

            if friendsStore.incomingRequests.isEmpty && friendsStore.outgoingRequestProfiles.isEmpty {
                emptyRequestsBody
            } else {
                VStack(spacing: AppSpacing.xs) {
                    ForEach(friendsStore.incomingRequests) { request in
                        requestRow(request: request)
                    }
                    ForEach(friendsStore.outgoingRequestProfiles) { request in
                        outgoingRequestRow(request: request)
                    }
                }
            }
        }
    }

    /// Row for an outgoing pending request — same identity treatment
    /// as the incoming row (accent dot + display name) but with a
    /// "Sent" pill in place of Approve and a Cancel button instead
    /// of Deny. Cancel deletes the friendship record so the
    /// recipient sees the request silently disappear.
    private func outgoingRequestRow(request: FriendsStore.PendingRequest) -> some View {
        HStack(spacing: AppSpacing.sm) {
            AccentDot(
                hex: request.requester.accentHex,
                fallback: appearance.accentColor,
                isGlowing: request.requester.isCookingNow
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(request.requester.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Sent")
                        .font(AppFont.caption)
                }
                .foregroundStyle(AppColor.textTertiary)
            }
            Spacer(minLength: AppSpacing.sm)
            Button {
                Haptics.selection()
                Task { await friendsStore.cancelRequest(to: request.requester) }
            } label: {
                Text("Cancel")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.textSecondary)
                    .accentTextOutline()
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.sm)
                            .stroke(AppColor.divider, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel friend request")
        }
        .padding(AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
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
                        .accentTextOutline()
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
                    isGlowing: friend.isCookingNow,
                    outlineWhenIdle: true
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                        .lineLimit(1)
                    if friend.isCookingNow {
                        // Live-presence subtitle while a friend is in
                        // cook mode. Fork-and-knife glyph plus the
                        // recipe title in the friend's resolved accent
                        // — same eyebrow language as the cookbook
                        // header so the two surfaces read as the same
                        // signal. Older sessions started before the
                        // title-on-start write are surfaced without a
                        // title ("Currently Cooking") rather than
                        // collapsing the row entirely, so presence
                        // doesn't disappear just because the friend's
                        // record predates the field write.
                        HStack(spacing: 4) {
                            Image(systemName: "fork.knife")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(AppColor.textTertiary)
                            if let title = friend.lastCookedTitle, !title.isEmpty {
                                Text("\(Text("Currently Cooking: ").foregroundStyle(AppColor.textTertiary))\(Text(title).fontWeight(.semibold).foregroundStyle(resolvedAccent(for: friend)))")
                                    .font(AppFont.caption)
                                    .lineLimit(1)
                            } else {
                                Text("Currently Cooking")
                                    .font(AppFont.caption)
                                    .foregroundStyle(AppColor.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
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
            // No remove affordance on the synthetic "Your Llama"
            // seed friend — it isn't a real Friendship row, can't be
            // unfriended, and `friendsStore.removeFriend` already
            // no-ops for it. Suppressing the menu entry avoids
            // surfacing a destructive control that silently does
            // nothing.
            if !SeedFriend.isSeed(friend) {
                Button(role: .destructive) {
                    pendingFriendRemoval = friend
                } label: {
                    Label("Remove friend", systemImage: "person.fill.xmark")
                }
            }
        }
    }

    /// Decode the friend's saved accent hex, falling back to the
    /// local user's accent if missing or malformed. Used for the
    /// "Cooking: <title>" subtitle so the cooked-recipe title pops
    /// in the friend's color rather than borrowing yours.
    private func resolvedAccent(for friend: UserProfileSnapshot) -> Color {
        if let hex = friend.accentHex, let parsed = Color(hex: hex) {
            return parsed
        }
        return appearance.accentColor
    }

    // MARK: - Settings sheet (cog menu)

    private var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    Spacer().frame(height: AppSpacing.sm)

                    if let identity = userAccount.status.identity {
                        cloudSyncRow(identity: identity)
                        republishLibraryRow
                    }

                    VStack(spacing: AppSpacing.md) {
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
                    }

                    Spacer(minLength: AppSpacing.lg)
                }
                .padding(.horizontal, AppSpacing.lg)
            }
            .scrollContentBackground(.hidden)
            .llamaBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .tint(appearance.accentColor)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { showingSettings = false } label: {
                        Text("Done")
                            .foregroundStyle(appearance.accentColor)
                            .accentTextOutline()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .environment(userAccount)
        .environment(friendsStore)
        .environment(appearance)
    }

    /// Force-republish-library diagnostic. The bulk publish on first-
    /// friend transition runs once per install and silently swallows
    /// errors — if that pass ran while the CloudKit schema was still
    /// half-deployed, every recipe failed to publish AND the gate
    /// flipped to "done" so it never retried. This button resets the
    /// gate and re-uploads every recipe, surfacing the per-recipe
    /// success/failure counts so the user can confirm the recovery
    /// actually worked.
    private var republishLibraryRow: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("LIBRARY SYNC")
                .eyebrowStyle(AppColor.textTertiary)
            HStack(spacing: AppSpacing.sm) {
                if let message = republishResultMessage {
                    Image(systemName: republishSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(republishSucceeded ? AppColor.success : AppColor.destructive)
                    Text(message)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                } else {
                    Text("Re-upload all your recipes so friends can see them in your cookbook.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(3)
                }
                Spacer(minLength: AppSpacing.sm)
                Button {
                    Task { await republishLibrary() }
                } label: {
                    if isRepublishingLibrary {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(appearance.accentColor)
                            .frame(width: 32, height: 32)
                            .background(AppColor.surfaceSunken)
                            .clipShape(Circle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRepublishingLibrary)
                .accessibilityLabel("Re-publish library to cloud")
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

    private func republishLibrary() async {
        isRepublishingLibrary = true
        let recipes = allRecipes
        let result = await LibraryMirrorService.shared.republishLibrary(recipes: recipes)
        isRepublishingLibrary = false
        if result.failed == 0 && result.firstError == nil {
            republishSucceeded = true
            republishResultMessage = "Published \(result.succeeded) recipe\(result.succeeded == 1 ? "" : "s"). Friends should see your full cookbook within a minute."
        } else {
            republishSucceeded = false
            var msg = "Published \(result.succeeded) of \(result.succeeded + result.failed)."
            if let firstError = result.firstError {
                msg += " First error: \(firstError)"
            }
            republishResultMessage = msg
        }
    }

    /// Diagnostic + manual-recovery row for the cloud `UserProfile`
    /// bind. The fire-and-forget bind paths (cold launch, sign-in)
    /// silently swallow CloudKit errors so the rest of the app never
    /// blocks on iCloud being available; this row is the explicit
    /// "tell me if my profile is actually in the cloud" affordance.
    /// Tapping it runs the same upsert and surfaces the result inline
    /// (success checkmark or the actual CKError message), so the
    /// user can self-diagnose iCloud-not-signed-in, missing-schema-
    /// field, or network failures without an Xcode console.
    private func cloudSyncRow(identity: UserAccount.UserIdentity) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("CLOUD SYNC")
                .eyebrowStyle(AppColor.textTertiary)
            HStack(spacing: AppSpacing.sm) {
                if let message = resyncResultMessage {
                    Image(systemName: resyncSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(resyncSucceeded ? AppColor.success : AppColor.destructive)
                    Text(message)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                } else {
                    Text("Push your profile to CloudKit so friends can find you in search.")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(3)
                }
                Spacer(minLength: AppSpacing.sm)
                Button {
                    Task { await resyncProfile(identity: identity) }
                } label: {
                    if isResyncingProfile {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(appearance.accentColor)
                            .frame(width: 32, height: 32)
                            .background(AppColor.surfaceSunken)
                            .clipShape(Circle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(isResyncingProfile)
                .accessibilityLabel("Re-sync profile to cloud")
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

    private func resyncProfile(identity: UserAccount.UserIdentity) async {
        isResyncingProfile = true
        let error = await UserProfileMirror.bindAndReturnError(
            displayName: identity.displayName,
            accentHex: appearance.accentColor.toHex
        )
        isResyncingProfile = false
        if let error {
            resyncSucceeded = false
            resyncResultMessage = error
        } else {
            resyncSucceeded = true
            resyncResultMessage = "Profile synced. Friends searching \"\(identity.displayName)\" should find you within a minute."
        }
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
