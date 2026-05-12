import Foundation
import Observation

/// Observable cache of the local user's social graph: accepted
/// friends + incoming pending requests + outgoing pending requests.
/// Mirrors the existing `CookingSession` / `AppearanceSettings`
/// pattern — instantiated once in `LlamasCookbookApp`, propagated
/// via `.environment(...)` from `RootView`.
///
/// **Why a store and not just per-view fetching.** Friends data is
/// surfaced in three places (the friends list, the requests
/// section, the search popover's `+` button state) and recomputed
/// on every action. Centralizing the cache means one CK round-trip
/// after each mutation refreshes every consumer at once via
/// SwiftUI's @Observable propagation.
///
/// **Refresh model.** Caller fires `refresh()` from `ProfileView`'s
/// `.task` and from any sheet-dismiss / scene-active hook that
/// should pick up newly-arrived friend requests. Background
/// CKSubscription pushes (slice 6) will eventually trigger refresh
/// automatically; for slice 2, foreground / sheet-open is the
/// trigger.
///
/// **Best-effort semantics.** Underlying CloudKit failures are
/// swallowed silently — the local cache stays at its last successful
/// state. Mutations (sendRequest, acceptRequest, etc.) optimistically
/// re-`refresh()` after the CK write so the UI reflects the new
/// state quickly.
@MainActor
@Observable
final class FriendsStore {
    /// Snapshots of accepted friends, pre-sorted alphabetically by
    /// `displayName` (case-insensitive, locale-aware) so the
    /// `ProfileView` Friends list renders in scroll-friendly order.
    ///
    /// **Always carries the synthetic "Your Llama" seed friend at
    /// index 0.** See `SeedFriend.swift` — the seed is local-only
    /// (no CloudKit record, no Friendship row) and exists so a
    /// brand-new user has something to browse and import from on
    /// day one. It survives every `refresh()` / `clearOnSignOut`
    /// because it isn't sourced from the social graph; it is
    /// prepended unconditionally after the rest of the list is
    /// reconciled. Counts toward `friends.count`, so a fresh user
    /// starts at 1/3 toward `isBelowSocialThreshold`.
    private(set) var friends: [UserProfileSnapshot] = [SeedFriend.profile]

    /// Pending requests where the local user is the **recipient** —
    /// "X wants to be your friend." Each entry pairs the friendship
    /// record name (so Approve/Deny can target it) with the
    /// requester's profile (for display name + accent dot rendering).
    private(set) var incomingRequests: [PendingRequest] = []

    /// Pending requests the local user has **sent** but not yet had
    /// approved. Maps `otherUserRecordName -> friendshipRecordName`
    /// so the search popover's `+` button can flip to a "clock /
    /// Pending" state for already-requested users and the user can
    /// cancel without another query round-trip.
    private(set) var outgoingRequests: [String: String] = [:]

    /// Profile-resolved counterpart to `outgoingRequests` — same set
    /// of pending sends, but with the recipient's profile snapshot
    /// resolved so the Profile sheet's Requests section can render
    /// "Sent to {Name}" rows alongside incoming requests. Sorted
    /// alphabetically by display name.
    private(set) var outgoingRequestProfiles: [PendingRequest] = []

    /// When each accepted friendship started, keyed by the friend's
    /// `userRecordName`. Sourced from the `Friendship` record's
    /// `acceptedAt` (the moment status flipped from pending →
    /// accepted, which is semantically "the friendship began" — not
    /// when the request was sent). Lives parallel to `friends` rather
    /// than as a property on `UserProfileSnapshot` because the date is
    /// a property of the *relationship*, not the profile, and the
    /// profile snapshot is also returned by `searchUserProfiles` where
    /// no friendship exists. Nil for legacy accepted records that
    /// predate the `acceptedAt` field.
    private(set) var friendsSinceByID: [String: Date] = [:]

    /// True while a `refresh()` is in flight. Prevents overlapping
    /// fetches when the user yanks the popover open / closed
    /// rapidly. Also drives a small spinner in the Friends section
    /// header on first load.
    private(set) var isRefreshing: Bool = false

    /// Timestamp of the most recent `refresh()` invocation. Stamped at
    /// the *start* of refresh (not the end) so a long-running fetch
    /// doesn't open a re-trigger window for `refreshIfStale` while
    /// it's still in flight — combined with the `isRefreshing` guard,
    /// this means rapid re-foregrounds never stack concurrent fetches.
    private(set) var lastRefreshAt: Date?

    /// Last-error diagnostic from `refresh()`. Normally `refresh`
    /// swallows CK errors silently so a transient blip doesn't blank
    /// the friends list — but during onboarding / schema deployment
    /// it's load-bearing to know *why* nothing is showing up. Surfaced
    /// in `ProfileView` as a small inline banner under the Requests
    /// header when non-nil.
    private(set) var lastRefreshError: String? = nil

    /// Diagnostic snapshot from the most recent successful `refresh()`.
    /// Surfaced inline in `ProfileView` so the user can spot mismatches
    /// between what CloudKit Console shows and what the app sees
    /// (e.g. their cached `me` ID not matching `userA`/`userB` on any
    /// Friendship record). Cleared on sign-out / clearOnSignOut.
    private(set) var lastRefreshDiagnostic: String? = nil

    /// Token for the block-based push observer. NotificationCenter
    /// retains block observers until removed, so setup is explicitly
    /// idempotent.
    @ObservationIgnored
    private var remotePushObserver: NSObjectProtocol?

    /// Pending request with everything the UI needs to render:
    /// approve/deny target (`friendshipRecordName`) + requester
    /// avatar/name (`requester`).
    struct PendingRequest: Identifiable, Hashable {
        let friendshipRecordName: String
        let requester: UserProfileSnapshot
        var id: String { friendshipRecordName }
    }

    // MARK: - Refresh

    /// Pull the latest social graph from CloudKit. One query for
    /// every Friendship involving me, then one fetch per
    /// `accepted` partner / `incoming pending` requester to
    /// populate display names + accents. Outgoing pending entries
    /// only need the friendship record name (the `+`-button state
    /// doesn't need the other user's profile because we already
    /// have it from the search results).
    ///
    /// Best-effort — silently no-ops when iCloud isn't bound (no
    /// cached recordID) or any underlying call fails. Doesn't clear
    /// state on failure: a transient network blip shouldn't make
    /// the friends list disappear.
    func refresh() async {
        // Re-entrancy guard. Set BEFORE the first await — otherwise
        // two near-simultaneous callers (e.g. .task + .onChange of
        // sign-in status) could both pass a "not refreshing" check
        // and proceed to fetch concurrently, racing on the result
        // assignments below. The class is `@MainActor`-isolated, so
        // assigning the flag here is atomic with respect to other
        // refresh calls.
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshAt = Date()
        defer { isRefreshing = false }

        // Resolve the local user's iCloud record name. Prefer the
        // mirror cache (written by `bindAfterSignIn`) for the warm
        // case; fall back to a fresh `fetchCurrentUserRecordID`
        // round-trip when the cache is empty — happens immediately
        // after sign-in if `bindAfterSignIn` hasn't completed yet,
        // or when the user is signed in to iCloud but never made it
        // through SIWA. Without the fallback, the friends list would
        // stay empty post-sign-in until the user closed and re-
        // opened ProfileView (so .task could re-fire).
        let me: String?
        if let cached = UserProfileMirror.cachedRecordID() {
            me = cached
        } else {
            me = await CloudKitService.fetchCurrentUserRecordID()
        }

        guard let me else {
            // No iCloud at all — flush local state so the UI doesn't
            // render stale friends from a previous session. The
            // synthetic seed friend stays put so the Friends tab is
            // never empty even when CloudKit is unreachable.
            friends = [SeedFriend.profile]
            incomingRequests = []
            outgoingRequests = [:]
            return
        }

        let friendships: [FriendshipRecord]
        do {
            friendships = try await CloudKitService.fetchFriendships(for: me)
            lastRefreshError = nil
        } catch {
            lastRefreshError = AppMetadata.describeServerError(error)
            return
        }

        // Collapse multiple records for the same user pair into one
        // logical relationship. CloudKit doesn't enforce uniqueness
        // (no unique index on the userA/userB pair), so duplicates
        // can land when the dedup-fetch in `sendRequest` was failing
        // (early-onboarding schema state) or when both users
        // mutual-requested at the same time. Precedence: accepted >
        // pending; among pendings keep the first one we encounter so
        // refresh is deterministic. Stale duplicates get swept off
        // the server in the cleanup pass below.
        var byOtherID: [String: FriendshipRecord] = [:]
        var staleRecords: [FriendshipRecord] = []
        for friendship in friendships {
            guard let otherID = friendship.otherUserID(from: me) else { continue }
            if let existing = byOtherID[otherID] {
                let keepNew: Bool
                switch (friendship.status, existing.status) {
                case (.accepted, .pending): keepNew = true
                case (.pending, .accepted): keepNew = false
                default: keepNew = false  // both same status — keep first
                }
                if keepNew {
                    staleRecords.append(existing)
                    byOtherID[otherID] = friendship
                } else {
                    staleRecords.append(friendship)
                }
            } else {
                byOtherID[otherID] = friendship
            }
        }

        // Resolve every unique counterpart profile in parallel. Without
        // this, refreshing a 25-friend graph fires 25 sequential
        // CloudKit round-trips and stalls the Profile sheet for
        // seconds on a slow connection. `fetchUserProfile` is a
        // stateless static `async throws`, safe to invoke
        // concurrently — CloudKit accepts parallel reads on the
        // public DB.
        let otherIDs = Array(byOtherID.keys)
        var profilesByID: [String: UserProfileSnapshot] = [:]
        await withTaskGroup(of: (String, UserProfileSnapshot?).self) { group in
            for otherID in otherIDs {
                group.addTask {
                    let snapshot = try? await CloudKitService.fetchUserProfile(userRecordName: otherID)
                    return (otherID, snapshot)
                }
            }
            for await (otherID, snapshot) in group {
                if let snapshot { profilesByID[otherID] = snapshot }
            }
        }

        var newFriends: [UserProfileSnapshot] = []
        var newFriendsSince: [String: Date] = [:]
        var newIncoming: [PendingRequest] = []
        var newOutgoing: [String: String] = [:]
        var newOutgoingProfiles: [PendingRequest] = []
        var skippedNoProfile = 0

        for (otherID, friendship) in byOtherID {
            switch friendship.status {
            case .accepted:
                if let profile = profilesByID[otherID] {
                    newFriends.append(profile)
                    if let acceptedAt = friendship.acceptedAt {
                        newFriendsSince[otherID] = acceptedAt
                    }
                }
            case .pending:
                if friendship.requesterID == me {
                    // Outgoing — track in the dict (search popover
                    // button state) AND resolve the profile so the
                    // Requests section can render a "Sent to X" row.
                    newOutgoing[otherID] = friendship.recordName
                    if let profile = profilesByID[otherID] {
                        newOutgoingProfiles.append(PendingRequest(
                            friendshipRecordName: friendship.recordName,
                            requester: profile
                        ))
                    }
                } else {
                    if let profile = profilesByID[otherID] {
                        newIncoming.append(PendingRequest(
                            friendshipRecordName: friendship.recordName,
                            requester: profile
                        ))
                    } else {
                        skippedNoProfile += 1
                    }
                }
            }
        }

        // Background sweep — delete duplicate records so the server
        // converges to one record per pair. Non-blocking; a failed
        // delete just means the next refresh will sweep again.
        if !staleRecords.isEmpty {
            Task.detached {
                for stale in staleRecords {
                    try? await CloudKitService.deleteFriendship(
                        recordName: stale.recordName,
                        currentUserID: me
                    )
                }
            }
        }

        let mePreview = String(me.prefix(20))
        lastRefreshDiagnostic = "me=\(mePreview)… fetched=\(friendships.count) accepted=\(newFriends.count) incoming=\(newIncoming.count) outgoing=\(newOutgoing.count) skipped(no profile)=\(skippedNoProfile) deduped=\(staleRecords.count)"

        newFriends.sort { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        newIncoming.sort { lhs, rhs in
            lhs.requester.displayName.localizedStandardCompare(rhs.requester.displayName) == .orderedAscending
        }
        newOutgoingProfiles.sort { lhs, rhs in
            lhs.requester.displayName.localizedStandardCompare(rhs.requester.displayName) == .orderedAscending
        }

        // Seed friend always rides at index 0, ahead of the alpha-
        // sorted CloudKit friends. Keeps "Your Llama" reachable from
        // a fresh install or a signed-out session, and gives the
        // grid a familiar anchor on every refresh.
        friends = [SeedFriend.profile] + newFriends
        friendsSinceByID = newFriendsSince
        incomingRequests = newIncoming
        outgoingRequests = newOutgoing
        outgoingRequestProfiles = newOutgoingProfiles
    }

    /// Conditional refresh used by the scene-active hook. Fires
    /// `refresh()` only when the previous run is older than
    /// `minimumAge` (or has never run). The 30s default is the
    /// debounce floor for foreground-driven presence refreshes —
    /// short enough that a user re-opening the app after lunch sees
    /// fresh "Cooking: <title>" eyebrows on friend cards, long enough
    /// that rapid tab-switching / lockscreen peeks don't hammer the
    /// public CloudKit DB. The `isRefreshing` guard inside `refresh()`
    /// is still the source of truth for re-entrancy; this helper just
    /// avoids the no-op call when nothing meaningful has elapsed.
    func refreshIfStale(minimumAge: TimeInterval = 30) async {
        if let last = lastRefreshAt,
           Date().timeIntervalSince(last) < minimumAge {
            return
        }
        await refresh()
    }

    // MARK: - Mutations

    /// Send a friend request to `other`. Optimistically inserts a
    /// placeholder into `outgoingRequests` so the search popover's
    /// `+` button flips immediately; then awaits the CK save and
    /// replaces the placeholder with the real friendship record name
    /// (which Cancel needs). On failure, rolls back the optimistic
    /// entry.
    func sendRequest(to other: UserProfileSnapshot) async {
        guard let me = UserProfileMirror.cachedRecordID() else { return }
        // Self-request guard — defense in depth; the popover also
        // filters self out before showing the row.
        guard other.userRecordName != me else { return }
        // Local-cache guards covering the three "no new request
        // needed" states: already friends, my outgoing pending
        // already exists, or they've already requested me (sender
        // should accept their request rather than sending one back,
        // which would create a duplicate pending pair).
        if friends.contains(where: { $0.userRecordName == other.userRecordName }) { return }
        if outgoingRequests[other.userRecordName] != nil { return }
        if incomingRequests.contains(where: { $0.requester.userRecordName == other.userRecordName }) {
            return
        }
        // Remote backstop. If this query fails (transient network,
        // CK throttling), we'd rather fail-closed than silently
        // create a duplicate Friendship record — the duplicates we
        // already have in production were caused by this exact
        // path failing while the schema was deploying.
        guard let remoteFriendships = try? await CloudKitService.fetchFriendships(for: me) else {
            return
        }
        if remoteFriendships.contains(where: { $0.otherUserID(from: me) == other.userRecordName }) {
            await refresh()
            return
        }

        // Optimistic placeholder — uses a sentinel record name so we
        // can detect an in-flight send and not double-issue. Real
        // record name overwrites it on success.
        let placeholder = "pending-\(UUID().uuidString)"
        outgoingRequests[other.userRecordName] = placeholder

        do {
            let recordName = try await CloudKitService.sendFriendRequest(
                from: me,
                to: other.userRecordName
            )
            outgoingRequests[other.userRecordName] = recordName
        } catch {
            outgoingRequests.removeValue(forKey: other.userRecordName)
        }
    }

    /// Cancel a previously-sent friend request. Reads the friendship
    /// record name from the local outgoing cache, deletes the CK
    /// record, then removes the entry. Idempotent at the CK layer
    /// (deleteFriendship swallows `unknownItem`).
    func cancelRequest(to other: UserProfileSnapshot) async {
        guard let me = UserProfileMirror.cachedRecordID() else { return }
        guard let recordName = outgoingRequests[other.userRecordName] else { return }
        outgoingRequests.removeValue(forKey: other.userRecordName)
        outgoingRequestProfiles.removeAll {
            $0.requester.userRecordName == other.userRecordName
        }
        // Skip the network call when only an optimistic placeholder
        // ever landed (the send is in flight or failed).
        guard !recordName.hasPrefix("pending-") else { return }
        try? await CloudKitService.deleteFriendship(
            recordName: recordName,
            currentUserID: me
        )
    }

    /// Approve an incoming friend request. Flips the CK record's
    /// status and re-fetches so the new friend appears in the
    /// `friends` list and disappears from `incomingRequests`.
    /// After accepting, sweeps any duplicate pending records for
    /// the same user pair so the server converges to one accepted
    /// record (mutual-request and pre-dedup-fetch duplicates would
    /// otherwise leave behind ghost pendings).
    func acceptRequest(_ pending: PendingRequest) async {
        guard let me = UserProfileMirror.cachedRecordID() else { return }
        try? await CloudKitService.approveFriendRequest(
            recordName: pending.friendshipRecordName,
            currentUserID: me
        )
        // Optimistic local update so the row vanishes immediately
        // (the refresh below will reconcile).
        incomingRequests.removeAll { $0.id == pending.id }
        outgoingRequests.removeValue(forKey: pending.requester.userRecordName)
        outgoingRequestProfiles.removeAll {
            $0.requester.userRecordName == pending.requester.userRecordName
        }
        friends.append(pending.requester)
        // Sort everything except the seed friend, then re-pin the
        // seed at index 0 so accept-driven inserts can't dislodge
        // it. Mirrors the post-refresh ordering.
        let seed = friends.first { SeedFriend.isSeed($0) }
        var rest = friends.filter { !SeedFriend.isSeed($0) }
        rest.sort { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        friends = (seed.map { [$0] } ?? []) + rest
        // Match the CK write — `approveFriendRequest` stamps
        // `acceptedAt = Date()` server-side, so the optimistic local
        // entry uses the same instant. The next refresh reconciles
        // against the authoritative server value (within a few ms).
        friendsSinceByID[pending.requester.userRecordName] = Date()
        // Cascade-delete duplicate friendship records for this pair
        // (everything except the just-accepted one). Detached so the
        // accept feels instant and a slow sweep doesn't block the
        // refresh below.
        let otherID = pending.requester.userRecordName
        let preserve = pending.friendshipRecordName
        Task.detached {
            await CloudKitService.deleteAllFriendshipsBetween(
                me, and: otherID, preservingRecordName: preserve
            )
        }
        await refresh()
    }

    /// Deny an incoming friend request — destructively removes the
    /// CK record so the requester just sees their pending entry
    /// vanish on next refresh. No notification fires (per spec —
    /// "saves face"). Also sweeps any duplicate pending records for
    /// the same pair so a denied user can re-request cleanly later
    /// without colliding with the leftover ghosts.
    func denyRequest(_ pending: PendingRequest) async {
        guard let me = UserProfileMirror.cachedRecordID() else { return }
        let otherID = pending.requester.userRecordName
        try? await CloudKitService.deleteFriendship(
            recordName: pending.friendshipRecordName,
            currentUserID: me
        )
        incomingRequests.removeAll { $0.id == pending.id }
        outgoingRequests.removeValue(forKey: otherID)
        outgoingRequestProfiles.removeAll { $0.requester.userRecordName == otherID }
        Task.detached {
            await CloudKitService.deleteAllFriendshipsBetween(me, and: otherID)
        }
    }

    /// Remove an accepted friend. Either side can do this. Local
    /// removal is optimistic; refresh reconciles. The other side
    /// won't be notified — they discover via their own friends list
    /// missing the entry on next refresh. Wipes EVERY friendship
    /// record for the pair (accepted + any leftover pendings) so
    /// either user can immediately re-request without the local
    /// dedup guards rejecting them due to a stale record.
    func removeFriend(_ friend: UserProfileSnapshot) async {
        // The synthetic seed friend has no CloudKit record to delete
        // and is never removable from the UI — bail before touching
        // either side. Belt-and-suspenders; the friend card / detail
        // surfaces don't expose a remove affordance on the seed.
        guard !SeedFriend.isSeed(friend) else { return }
        guard let me = UserProfileMirror.cachedRecordID() else { return }
        let otherID = friend.userRecordName
        await CloudKitService.deleteAllFriendshipsBetween(me, and: otherID)
        friends.removeAll { $0.userRecordName == otherID }
        friendsSinceByID.removeValue(forKey: otherID)
        outgoingRequests.removeValue(forKey: otherID)
        outgoingRequestProfiles.removeAll { $0.requester.userRecordName == otherID }
        incomingRequests.removeAll { $0.requester.userRecordName == otherID }
    }

    // MARK: - Sign-in lifecycle

    /// Wipe local state. Called from `ProfileView` immediately after
    /// `userAccount.signOut()` / `deleteAccount()` so the UI doesn't
    /// flash the previous user's friends list before the next
    /// refresh fires (or, if signed out for good, never).
    func clearOnSignOut() {
        // Seed friend survives sign-out — it lives in the bundle,
        // not in the just-cleared CloudKit graph. Without this the
        // post-sign-out Friends tab would render fully empty for
        // the brief moment before .task fires a refresh.
        friends = [SeedFriend.profile]
        friendsSinceByID = [:]
        incomingRequests = []
        outgoingRequests = [:]
        outgoingRequestProfiles = []
        lastRefreshError = nil
        lastRefreshDiagnostic = nil
        lastRefreshAt = nil
    }

    // MARK: - Push observation

    /// Begin observing CloudKit subscription pushes. Called once
    /// from `RootView.task` so the store's lifetime tracks the
    /// app's. Setup is idempotent so repeated tasks don't register
    /// duplicate block observers.
    ///
    /// On each push that matches the friendship subscription we
    /// fire a `refresh()`. The fetch is deduplicated server-side
    /// against in-flight refreshes (the `isRefreshing` guard) so
    /// rapid-fire pushes don't stampede CloudKit. The signed-out
    /// case is a free no-op since `refresh()` early-returns when
    /// the mirror cache is empty.
    func observeRemotePushes() {
        guard remotePushObserver == nil else { return }
        // The `MainActor` jump is required — NotificationCenter
        // delivers on the queue that posted, which AppDelegate's
        // remote-notification path reaches via the URL session
        // queue. The `Task { @MainActor in ... }` re-anchors us
        // before touching `@Observable` state.
        remotePushObserver = NotificationCenter.default.addObserver(
            forName: CloudKitSubscriptions.didFireNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            guard let kindRaw = note.userInfo?["kind"] as? String,
                  let kind = CloudKitSubscriptions.FiredKind(rawValue: kindRaw)
            else { return }
            // We only care about friendship pushes here; the
            // recipe-import pushes get handled in
            // `RecipeDetailView`'s onReceive — observer per
            // consumer, no spurious cross-component refreshes.
            guard kind == .friendship else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    deinit {
        if let remotePushObserver {
            NotificationCenter.default.removeObserver(remotePushObserver)
        }
    }
}
