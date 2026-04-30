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

        guard let friendships = try? await CloudKitService.fetchFriendships(for: me) else {
            return
        }

        var newFriends: [UserProfileSnapshot] = []
        var newIncoming: [PendingRequest] = []
        var newOutgoing: [String: String] = [:]

        for friendship in friendships {
            guard let otherID = friendship.otherUserID(from: me) else { continue }

            switch friendship.status {
            case .accepted:
                if let profile = try? await CloudKitService.fetchUserProfile(userRecordName: otherID) {
                    newFriends.append(profile)
                }
            case .pending:
                if friendship.requesterID == me {
                    // Outgoing — track by other-user-id for the
                    // `+`-button state in the search popover. We
                    // don't need the profile; the popover already
                    // has it.
                    newOutgoing[otherID] = friendship.recordName
                } else {
                    // Incoming — need the requester's profile to
                    // render the row.
                    if let profile = try? await CloudKitService.fetchUserProfile(userRecordName: otherID) {
                        newIncoming.append(PendingRequest(
                            friendshipRecordName: friendship.recordName,
                            requester: profile
                        ))
                    }
                }
            }
        }

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
        // Already-friend / already-requested guards. Cheap local
        // check; avoids a duplicate Friendship record on rapid
        // double-tap. (Server-side dedup is the spec's deferred
        // problem — see implement-social.md.)
        if friends.contains(where: { $0.userRecordName == other.userRecordName }) { return }
        if outgoingRequests[other.userRecordName] != nil { return }

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
        guard let recordName = outgoingRequests[other.userRecordName] else { return }
        outgoingRequests.removeValue(forKey: other.userRecordName)
        // Skip the network call when only an optimistic placeholder
        // ever landed (the send is in flight or failed).
        guard !recordName.hasPrefix("pending-") else { return }
        try? await CloudKitService.deleteFriendship(recordName: recordName)
    }

    /// Approve an incoming friend request. Flips the CK record's
    /// status and re-fetches so the new friend appears in the
    /// `friends` list and disappears from `incomingRequests`.
    func acceptRequest(_ pending: PendingRequest) async {
        try? await CloudKitService.approveFriendRequest(
            recordName: pending.friendshipRecordName
        )
        // Optimistic local update so the row vanishes immediately
        // (the refresh below will reconcile).
        incomingRequests.removeAll { $0.id == pending.id }
        friends.append(pending.requester)
        friends.sort { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        await refresh()
    }

    /// Deny an incoming friend request — destructively removes the
    /// CK record so the requester just sees their pending entry
    /// vanish on next refresh. No notification fires (per spec —
    /// "saves face").
    func denyRequest(_ pending: PendingRequest) async {
        try? await CloudKitService.deleteFriendship(
            recordName: pending.friendshipRecordName
        )
        incomingRequests.removeAll { $0.id == pending.id }
    }

    /// Remove an accepted friend. Either side can do this. Local
    /// removal is optimistic; refresh reconciles. The other side
    /// won't be notified — they discover via their own friends list
    /// missing the entry on next refresh.
    func removeFriend(_ friend: UserProfileSnapshot) async {
        guard let me = UserProfileMirror.cachedRecordID() else { return }
        guard let friendships = try? await CloudKitService.fetchFriendships(for: me) else {
            return
        }
        let target = friendships.first { f in
            f.status == .accepted && f.otherUserID(from: me) == friend.userRecordName
        }
        guard let target else { return }
        try? await CloudKitService.deleteFriendship(recordName: target.recordName)
        friends.removeAll { $0.userRecordName == friend.userRecordName }
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
    }
}
