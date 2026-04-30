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
    static func approveFriendRequest(recordName: String) async throws {
        let id = CKRecord.ID(recordName: recordName)
        let record = try await publicDB.record(for: id)
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
    static func deleteFriendship(recordName: String) async throws {
        let id = CKRecord.ID(recordName: recordName)
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
    /// Result limit is the CK default (currently 100, but Apple
    /// reserves the right to change). At realistic friend counts
    /// (single digits to low hundreds) one page is plenty; if we
    /// ever blow that, paginate via the `cursor` returned by
    /// `records(matching:)`.
    static func fetchFriendships(for userRecordName: String) async throws -> [FriendshipRecord] {
        let predicate = NSPredicate(
            format: "userA == %@ OR userB == %@",
            userRecordName, userRecordName
        )
        let query = CKQuery(recordType: friendshipRecordType, predicate: predicate)
        let (matchResults, _) = try await publicDB.records(matching: query)
        var results: [FriendshipRecord] = []
        results.reserveCapacity(matchResults.count)
        for (id, result) in matchResults {
            guard case .success(let record) = result else { continue }
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
            try? await deleteFriendship(recordName: friendship.recordName)
        }
    }
}
