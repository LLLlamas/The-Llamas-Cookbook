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
    private(set) var friends: [UserProfileSnapshot] = []

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

    /// True while a `refresh()` is in flight. Prevents overlapping
    /// fetches when the user yanks the popover open / closed
    /// rapidly. Also drives a small spinner in the Friends section
    /// header on first load.
    private(set) var isRefreshing: Bool = false

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
            // render stale friends from a previous session.
            friends = []
            incomingRequests = []
            outgoingRequests = [:]
            return
        }

        let friendships: [FriendshipRecord]
        do {
            friendships = try await CloudKitService.fetchFriendships(for: me)
            lastRefreshError = nil
        } catch {
            lastRefreshError = (error as NSError).userInfo["ServerErrorDescription"] as? String
                ?? error.localizedDescription
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

        var newFriends: [UserProfileSnapshot] = []
        var newIncoming: [PendingRequest] = []
        var newOutgoing: [String: String] = [:]
        var skippedNoProfile = 0

        for (otherID, friendship) in byOtherID {
            switch friendship.status {
            case .accepted:
                if let profile = try? await CloudKitService.fetchUserProfile(userRecordName: otherID) {
                    newFriends.append(profile)
                }
            case .pending:
                if friendship.requesterID == me {
                    newOutgoing[otherID] = friendship.recordName
                } else {
                    if let profile = try? await CloudKitService.fetchUserProfile(userRecordName: otherID) {
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

        friends = newFriends
        incomingRequests = newIncoming
        outgoingRequests = newOutgoing
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
        friends.append(pending.requester)
        friends.sort { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
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
        guard let me = UserProfileMirror.cachedRecordID() else { return }
        let otherID = friend.userRecordName
        await CloudKitService.deleteAllFriendshipsBetween(me, and: otherID)
        friends.removeAll { $0.userRecordName == otherID }
        outgoingRequests.removeValue(forKey: otherID)
        incomingRequests.removeAll { $0.requester.userRecordName == otherID }
    }

    // MARK: - Sign-in lifecycle

    /// Wipe local state. Called from `ProfileView` immediately after
    /// `userAccount.signOut()` / `deleteAccount()` so the UI doesn't
    /// flash the previous user's friends list before the next
    /// refresh fires (or, if signed out for good, never).
    func clearOnSignOut() {
        friends = []
        incomingRequests = []
        outgoingRequests = [:]
        lastRefreshError = nil
        lastRefreshDiagnostic = nil
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
