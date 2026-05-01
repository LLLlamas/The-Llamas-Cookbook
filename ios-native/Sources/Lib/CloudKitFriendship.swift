import Foundation
import CloudKit

/// Snapshot of a `Friendship` record from the public CloudKit DB.
/// Returned by the friendship CRUD methods on `CloudKitService`;
/// consumed by `FriendsStore` for the cached friend / requests state.
///
/// Symmetric: `userA` / `userB` are the lexicographically-sorted pair
/// of iCloud user record names. This guarantees one record per pair
/// regardless of who initiated. Status is `pending` until the
/// recipient approves; `accepted` afterward. Deny is destructive
/// (record is deleted).
struct FriendshipRecord: Identifiable, Hashable {
    /// CloudKit recordName of this `Friendship` record. Used for
    /// targeted updates (approve flips status), deletes (cancel /
    /// deny / unfriend), and as a stable id for SwiftUI lists.
    let recordName: String
    let userA: String
    let userB: String
    let requesterID: String
    let status: Status
    let acceptedAt: Date?

    var id: String { recordName }

    enum Status: String {
        case pending
        case accepted
    }

    /// The other participant's user record name from `me`'s point of
    /// view. Returns `nil` when `me` doesn't appear in this friendship
    /// (defensive; in practice we only ever fetch friendships involving
    /// the local user).
    func otherUserID(from me: String) -> String? {
        if userA == me { return userB }
        if userB == me { return userA }
        return nil
    }
}

extension CloudKitService {
    // MARK: - Friendship

    /// CloudKit record type for friendships. Field schema (deployed
    /// Dev → Prod ahead of TestFlight):
    /// - `userA` — String, queryable. Lexicographically smaller of
    ///   the two user record names.
    /// - `userB` — String, queryable. The larger one.
    /// - `requesterID` — String. Whoever originated the request.
    /// - `status` — String, queryable. `"pending"` | `"accepted"`.
    /// - `acceptedAt` — Date/Time, optional, sortable.
    static let friendshipRecordType = "Friendship"

    /// Lexicographic sort guarantees the (userA, userB) pair is the
    /// same regardless of who initiated, so the symmetric one-record-
    /// per-pair invariant works without a uniqueness index.
    static func sortedUserPair(_ a: String, _ b: String) -> (String, String) {
        a < b ? (a, b) : (b, a)
    }

    /// Send a friend request. Creates a `Friendship` record with
    /// `status = pending` and `requesterID = me`. Returns the new
    /// record's name so the caller can stash it for cancel-by-id
    /// later. Caller is responsible for guarding against duplicate
    /// sends (we don't dedupe at the CK layer — see
    /// implement-social.md › "Already-friends / already-pending
    /// handling").
    static func sendFriendRequest(
        from me: String,
        to other: String
    ) async throws -> String {
        let (userA, userB) = sortedUserPair(me, other)
        let record = CKRecord(recordType: friendshipRecordType)
        record["userA"] = userA as NSString
        record["userB"] = userB as NSString
        record["requesterID"] = me as NSString
        record["status"] = FriendshipRecord.Status.pending.rawValue as NSString
        let saved = try await publicDB.save(record)
        return saved.recordID.recordName
    }

    /// Approve a pending request — flip `status` to `accepted`,
    /// stamp `acceptedAt`. The record's recordName is whatever
    /// CloudKit assigned at send-time; the caller (recipient) reads
    /// it out of their incoming-requests list.
    static func approveFriendRequest(
        recordName: String,
        currentUserID: String
    ) async throws {
        let id = CKRecord.ID(recordName: recordName)
        let record = try await publicDB.record(for: id)
        guard let userA = record["userA"] as? String,
              let userB = record["userB"] as? String,
              let requesterID = record["requesterID"] as? String,
              (currentUserID == userA || currentUserID == userB),
              currentUserID != requesterID
        else {
            throw CloudKitServiceError.notAuthorized
        }
        record["status"] = FriendshipRecord.Status.accepted.rawValue as NSString
        record["acceptedAt"] = Date() as NSDate
        _ = try await publicDB.save(record)
    }

    /// Delete a `Friendship` record. Used by all three "this
    /// friendship is over" paths — cancel my outgoing pending
    /// request, deny an incoming request, unfriend an accepted
    /// connection. Idempotent — `unknownItem` is treated as success
    /// (already gone is the post-condition we want).
    ///
    /// Per the spec, deny is silent on the requester's end — they
    /// just see the request silently disappear from their pending
    /// state on next refresh. No notification.
    static func deleteFriendship(
        recordName: String,
        currentUserID: String
    ) async throws {
        let id = CKRecord.ID(recordName: recordName)
        let record: CKRecord
        do {
            record = try await publicDB.record(for: id)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            return
        }
        guard let userA = record["userA"] as? String,
              let userB = record["userB"] as? String,
              currentUserID == userA || currentUserID == userB
        else {
            throw CloudKitServiceError.notAuthorized
        }
        do {
            _ = try await publicDB.deleteRecord(withID: id)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            return
        }
    }

    /// Fetch every `Friendship` record involving the given user — both
    /// pending (incoming + outgoing) and accepted, in either userA or
    /// userB position. The single round-trip lets `FriendsStore`
    /// categorize once and avoid duplicate per-status queries.
    ///
    /// Follows CloudKit cursors so large friend lists don't silently
    /// stop at the first query page.
    static func fetchFriendships(for userRecordName: String) async throws -> [FriendshipRecord] {
        // CloudKit's query predicate language doesn't support `OR`
        // across two different fields, so the symmetric "find every
        // friendship where I'm either userA or userB" lookup runs as
        // two separate queries that we merge + dedupe by recordName.
        // The userA/userB pair is also lexicographically sorted at
        // write time, so for any given pair only one of the two
        // queries can return the record — but we dedupe defensively
        // in case a future write path lands on the unsorted side.
        let queryA = CKQuery(
            recordType: friendshipRecordType,
            predicate: NSPredicate(format: "userA == %@", userRecordName)
        )
        let queryB = CKQuery(
            recordType: friendshipRecordType,
            predicate: NSPredicate(format: "userB == %@", userRecordName)
        )
        async let resultsA = queryAllRecords(matching: queryA)
        async let resultsB = queryAllRecords(matching: queryB)
        let combined = try await resultsA + resultsB

        var seen: Set<String> = []
        var results: [FriendshipRecord] = []
        results.reserveCapacity(combined.count)
        for (id, result) in combined {
            guard case .success(let record) = result else { continue }
            guard !seen.contains(id.recordName) else { continue }
            seen.insert(id.recordName)
            guard let userA = record["userA"] as? String,
                  let userB = record["userB"] as? String,
                  let requesterID = record["requesterID"] as? String,
                  let statusRaw = record["status"] as? String,
                  let status = FriendshipRecord.Status(rawValue: statusRaw)
            else { continue }
            let acceptedAt = record["acceptedAt"] as? Date
            results.append(FriendshipRecord(
                recordName: id.recordName,
                userA: userA,
                userB: userB,
                requesterID: requesterID,
                status: status,
                acceptedAt: acceptedAt
            ))
        }
        return results
    }

    /// Cascade-delete every `Friendship` record this user is part
    /// of. Called from `UserAccount.deleteAccount`. Best-effort —
    /// individual delete failures are swallowed; the next launch's
    /// outbox-style cleanup will eventually catch stragglers.
    /// (Currently we don't have a friendship-deletion outbox; if
    /// reviewers find stranded records during account-deletion
    /// testing, we'll add one.)
    static func deleteAllFriendships(for userRecordName: String) async {
        guard let records = try? await fetchFriendships(for: userRecordName) else {
            return
        }
        for friendship in records {
            try? await deleteFriendship(
                recordName: friendship.recordName,
                currentUserID: userRecordName
            )
        }
    }

    /// Delete every `Friendship` record between two users — used as
    /// post-action cleanup when a user pair lands in an inconsistent
    /// state (mutual outgoing requests, leftover pendings after
    /// accept/remove, duplicate requests sent before the dedup
    /// fetch was healthy). Optionally preserve a single record by
    /// recordName (e.g. the just-accepted one). Best-effort; per-
    /// record failures are swallowed so a transient blip doesn't
    /// strand the user mid-cleanup.
    static func deleteAllFriendshipsBetween(
        _ me: String,
        and other: String,
        preservingRecordName: String? = nil
    ) async {
        guard let records = try? await fetchFriendships(for: me) else {
            return
        }
        for friendship in records {
            guard friendship.otherUserID(from: me) == other else { continue }
            if friendship.recordName == preservingRecordName { continue }
            try? await deleteFriendship(
                recordName: friendship.recordName,
                currentUserID: me
            )
        }
    }
}
