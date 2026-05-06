import Foundation
import CloudKit

/// Remote snapshot of a user's `UserProfile` record from the public
/// CloudKit database. Returned by `CloudKitService.fetchUserProfile`;
/// consumed by Friends UI in slice 4+ to render friends' display
/// names, accent colors, last-cooked lines, and presence-now glow.
///
/// Frozen-in-time — call sites refresh by re-fetching, not by holding
/// a reference. SwiftData's `@Model` machinery doesn't apply here;
/// these records live in CloudKit, not the local store.
struct UserProfileSnapshot: Identifiable, Hashable {
    let userRecordName: String
    let displayName: String
    let accentHex: String?
    let createdAt: Date
    let lastCookedAt: Date?
    let lastCookedRecipeID: String?
    let lastCookedTitle: String?
    let cookingStartedAt: Date?

    var id: String { userRecordName }

    /// Whether this user is considered "cooking right now" for the
    /// glowing-dot indicator. The 6-hour ceiling is a stale-state
    /// guard: most cook sessions are well under 4 hours, but if the
    /// app is force-killed mid-cook the field stays set on the cloud
    /// until the user reopens the app and ends the session, so we
    /// time-box the glow client-side. See implement-social.md ›
    /// "Presence indicator (the glowing dot)".
    var isCookingNow: Bool {
        guard let started = cookingStartedAt else { return false }
        return Date().timeIntervalSince(started) < 6 * 3600
    }

    /// Decode a CloudKit record into a snapshot. Used by both
    /// `fetchUserProfile` (single fetch by ID) and
    /// `searchUserProfiles` (query result iteration). Defensive about
    /// missing fields — `displayName` falls back to empty string and
    /// `createdAt` to .now so a malformed record (older schema, etc.)
    /// still produces a usable value rather than throwing.
    init(record: CKRecord, userRecordName: String) {
        self.userRecordName = userRecordName
        self.displayName = record["displayName"] as? String ?? ""
        self.accentHex = record["accentHex"] as? String
        self.createdAt = record["createdAt"] as? Date ?? Date()
        self.lastCookedAt = record["lastCookedAt"] as? Date
        self.lastCookedRecipeID = record["lastCookedRecipeID"] as? String
        self.lastCookedTitle = record["lastCookedTitle"] as? String
        self.cookingStartedAt = record["cookingStartedAt"] as? Date
    }
}

extension CloudKitService {
    // MARK: - UserProfile

    /// CloudKit record type for the per-user profile mirror. Field
    /// schema (deployed Dev → Prod ahead of TestFlight, per the
    /// "Schema deployment ritual" in implement-social.md):
    ///
    /// - `displayName` — String, queryable (slice 2's name search)
    /// - `accentHex` — String, optional. User's accent color hex.
    /// - `createdAt` — Date/Time, queryable + sortable. Set at first
    ///   write; preserved across re-upserts.
    /// - `lastCookedAt` — Date/Time, optional, queryable + sortable.
    /// - `lastCookedRecipeID` — String, optional.
    /// - `lastCookedTitle` — String, optional. Denormalized so
    ///   friends can render the line without fetching the full
    ///   recipe.
    /// - `cookingStartedAt` — Date/Time, optional. Drives the
    ///   glowing-dot indicator.
    ///
    /// Record name: the iCloud user record name returned by
    /// `fetchCurrentUserRecordID()` — opaque per-Apple-ID identifier
    /// scoped to our container. Matching the recordName to the
    /// iCloud user ID gives us "exactly one profile per user" without
    /// a uniqueness query.
    static let userProfileRecordType = "UserProfile"

    /// Prefix applied to UserProfile recordNames to avoid collision
    /// with CloudKit's built-in `Users` system record type. The
    /// system `Users` record's recordName IS the iCloud user record
    /// name, so saving a custom record with the same recordName
    /// fetches the system record back and rejects our custom
    /// fields ("Cannot create or modify field 'accentHex' in record
    /// Users in productions schema"). Prefixing decouples our
    /// recordName from the system one while still giving us
    /// "exactly one profile per user" via deterministic addressing.
    /// External callers continue to pass raw iCloud user record
    /// names — the prefix is applied / stripped inside this file.
    private static let userProfileRecordNamePrefix = "profile_"

    private static func userProfileRecordID(for userRecordName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: userProfileRecordNamePrefix + userRecordName)
    }

    private static func userRecordName(fromProfileRecordID id: CKRecord.ID) -> String {
        let name = id.recordName
        if name.hasPrefix(userProfileRecordNamePrefix) {
            return String(name.dropFirst(userProfileRecordNamePrefix.count))
        }
        return name
    }

    /// Fetches the current iCloud user's stable record name for this
    /// container. This is the identifier friends use to address each
    /// other in the social schema — `Friendship.userA/userB` and the
    /// recordNames of `UserProfile` records all derive from this.
    ///
    /// Returns nil if iCloud is signed out or any underlying CKError
    /// occurs. Callers treat nil as "social features unavailable for
    /// this user/session right now" and silently no-op; the local
    /// app continues to function without the cloud-side mirror.
    /// Matches the existing share flow's iCloud-unavailable
    /// degradation pattern.
    static func fetchCurrentUserRecordID() async -> String? {
        do {
            let recordID = try await container.userRecordID()
            return recordID.recordName
        } catch {
            return nil
        }
    }

    /// Read a `UserProfile` record by its userRecordName. Returns nil
    /// when the record doesn't exist (user has SIWA but never
    /// surfaced an iCloud session, or hasn't opened the app since
    /// the social slice landed). Throws on network / authorization
    /// errors so callers can distinguish "not yet" from "temporarily
    /// can't reach."
    static func fetchUserProfile(userRecordName: String) async throws -> UserProfileSnapshot? {
        let recordID = userProfileRecordID(for: userRecordName)
        do {
            let record = try await publicDB.record(for: recordID)
            return UserProfileSnapshot(record: record, userRecordName: userRecordName)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            return nil
        }
    }

    /// Search the public database for `UserProfile` records whose
    /// `displayName` starts with `prefix`. Case-insensitive. Used by
    /// the Friends search popover in slice 2's `ProfileView`.
    ///
    /// `prefix` shorter than 2 characters returns an empty array
    /// without a network round-trip — a 1-character search matches
    /// far too many users to be useful and would burn CK quota.
    /// Results are limited to 20 to keep the popover scrollable but
    /// not endless; tightening the search input is the way to find
    /// a specific person.
    ///
    /// Filtering of self (the searcher's own profile) and
    /// already-friended / pending users is the caller's
    /// responsibility — the FriendsStore strips them before the
    /// popover renders so the `+` button can flip to the right state
    /// (Pending / Friends / hidden).
    static func searchUserProfiles(prefix: String) async throws -> [UserProfileSnapshot] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let predicate = NSPredicate(format: "displayName BEGINSWITH %@", trimmed)
        let query = CKQuery(recordType: userProfileRecordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "displayName", ascending: true)]
        let (matchResults, _) = try await publicDB.records(
            matching: query,
            resultsLimit: 20
        )
        return matchResults.compactMap { (id, result) in
            guard case .success(let record) = result else { return nil }
            return UserProfileSnapshot(
                record: record,
                userRecordName: userRecordName(fromProfileRecordID: id)
            )
        }
    }

    /// Upsert the caller's own `UserProfile` record. Fetches the
    /// existing record (or constructs a fresh one) and runs `apply`
    /// to set the fields the caller cares about, then saves. Other
    /// fields on the record are preserved across the round-trip —
    /// so a `cookingStartedAt`-only update from one device doesn't
    /// clobber `lastCookedTitle` written by a different device.
    ///
    /// `createdAt` is set on initial creation only; re-upserts
    /// preserve the original value so "Joined April 2026" stays
    /// stable across device re-syncs.
    ///
    /// Cross-device race conditions on the same user's profile are
    /// extraordinarily rare (require simultaneous edits on iPhone
    /// + iPad inside the same network round-trip) and last-write-
    /// wins is the right resolution if they happen — the user is
    /// the only writer of their own profile, so there's no
    /// adversarial overwrite to defend against.
    static func upsertUserProfile(
        userRecordName: String,
        apply: (CKRecord) -> Void
    ) async throws {
        let recordID = userProfileRecordID(for: userRecordName)
        let record: CKRecord
        do {
            record = try await publicDB.record(for: recordID)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            record = CKRecord(recordType: userProfileRecordType, recordID: recordID)
            record["createdAt"] = Date() as NSDate
        }
        apply(record)
        _ = try await publicDB.save(record)
    }

    /// Delete the caller's `UserProfile` record. Used by the
    /// account-deletion cascade. Idempotent — `unknownItem` is
    /// treated as success (the record's already gone, which is the
    /// post-condition we want).
    static func deleteUserProfile(userRecordName: String) async throws {
        let recordID = userProfileRecordID(for: userRecordName)
        do {
            _ = try await publicDB.deleteRecord(withID: recordID)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            return
        }
    }

    /// Account-deletion cascade variant — enqueues the UserProfile
    /// record into `CloudPendingDeleteQueue` (with the right
    /// `profile_` prefixed recordName) and drains. Lets the cascade
    /// in `UserAccount.deleteAccount` route through the same
    /// retry-on-launch path as the other cloud cleanups, so a
    /// network blip mid-delete doesn't strand the row.
    static func enqueueUserProfileDeletion(userRecordName: String) async {
        let recordID = userProfileRecordID(for: userRecordName)
        CloudPendingDeleteQueue.enqueue(
            recordType: userProfileRecordType,
            recordName: recordID.recordName
        )
        await CloudPendingDeleteQueue.drain()
    }
}
