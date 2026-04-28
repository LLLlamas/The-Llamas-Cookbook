import Foundation
import CloudKit

/// Thin wrapper around `CKContainer.publicCloudDatabase` for the
/// permalink-share flow. Sender uploads a `RecipeShare` record (envelope
/// JSON as `CKAsset` so it carries inline photos cleanly); recipient
/// fetches by random 6-char record ID to materialize the recipe
/// locally. No friend codes, no inbox, no push — just "share a link"
/// mechanics with photos hosted on Apple's CDN. See
/// Implementing-User-Sign-In.md §0 (architecture pivot 2026-04-28).
///
/// Account semantics (important):
/// - **iCloud sign-in is required** to write or read records on the
///   public DB. iPhone users are effectively always signed in, but the
///   "no iCloud account" state must surface gracefully — we fall back
///   to the local URL form on the sender side and a clear error on
///   the receiver side.
/// - **Sign-in-with-Apple is NOT required** for this feature. The
///   `RecipeShare` record carries the sender's display name from
///   `OwnerProfile.userName` for attribution; ownership of authored
///   records is tracked via CloudKit's auto-stamped
///   `creatorUserRecordID` field, so a future "delete my shares"
///   cascade doesn't need an explicit `senderAppleSub` column.
///
/// CloudKit Dashboard schema for `RecipeShare`:
/// - `envelope` — Asset (the LCRecipeShareV1 JSON, photos inline)
/// - `senderDisplayName` — String (for inbox / outbox UI; nil-safe)
/// - `recipeTitle` — String (peek without downloading the asset)
/// - `createdAt` — Date/Time (TTL anchor + sort key, queryable)
///
/// Indexes: `createdAt` queryable + sortable; `___createdBy` (the
/// auto-field; queryable so the deleteAccount cascade can find the
/// user's authored records without a custom column).
enum CloudKitService {
    /// Container identifier — MUST match the entitlement at
    /// `Resources/LlamasCookbook.entitlements` and the container
    /// configured in Apple Developer Portal under the App ID's iCloud
    /// capability. Three places, one string, no drift.
    static let containerID = "iCloud.com.llamascookbook.app"

    /// Record type for the share-permalink hosting. Single record type
    /// in the schema for now.
    static let recipeShareRecordType = "RecipeShare"

    /// Length of the random share-record ID surfaced in the permalink
    /// URL. 6 chars from a 32-char alphabet → ~1B namespace; collision
    /// probability per generation at 1k active shares is ~1e-6.
    /// Two-attempt retry on save covers the rare case.
    static let recordIDLength = 6

    /// Alphabet for record IDs: uppercase A-Z + digits, with `I`,
    /// `O`, `0`, `1` removed so a recipient typing the link by hand
    /// (rare but possible) doesn't confuse lookalikes. Mirrors the
    /// "no I/O/0/1" rule from the original friend-code plan §3 — same
    /// rationale, different surface.
    static let recordIDAlphabet: [Character] = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// Public-DB-only — we never touch the private DB. Public DB
    /// records are addressable by anyone who knows the random record
    /// ID; that's exactly what we want for permalink shares.
    static var container: CKContainer {
        CKContainer(identifier: containerID)
    }

    static var publicDB: CKDatabase {
        container.publicCloudDatabase
    }

    /// One-shot probe of the user's iCloud account state. Returns
    /// `.available` when the device is signed into iCloud and the app
    /// can read/write its records; anything else means the cloud-share
    /// path is unavailable for this user right now.
    ///
    /// Used by the sender's share menu to decide between the cloud
    /// upload path (when `.available`) and the existing local URL form
    /// (otherwise). Async — wraps Apple's callback API in
    /// `CheckedContinuation` for clean call sites.
    static func accountStatus() async -> CKAccountStatus {
        await withCheckedContinuation { continuation in
            container.accountStatus { status, _ in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Upload

    /// Uploads `envelope` to the public DB as a new `RecipeShare`
    /// record and returns the random 6-char record name. Caller mints
    /// `llamascookbook://share/<recordName>` from this.
    ///
    /// Encoding: full envelope JSON (photos inline as base64) → temp
    /// file → `CKAsset`. CloudKit handles the binary upload as part
    /// of `save`. Temp file cleaned up regardless of save outcome.
    ///
    /// Retries once on `serverRecordChanged` (record-name collision)
    /// with a fresh ID; beyond that, the rare collision becomes a
    /// thrown error and the caller falls back to the local URL form.
    static func uploadShare(
        _ envelope: LCRecipeShareV1,
        senderDisplayName: String?
    ) async throws -> String {
        let json = try makeEncoder().encode(envelope)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(UUID().uuidString).json")
        try json.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Two attempts — collision is vanishingly unlikely (~1e-6 at
        // 1k records) but cheap to retry once on a fresh ID.
        for attempt in 0..<2 {
            let recordName = generateRecordID()
            let recordID = CKRecord.ID(recordName: recordName)
            let record = CKRecord(recordType: recipeShareRecordType, recordID: recordID)
            record["envelope"] = CKAsset(fileURL: tempURL)
            if let name = senderDisplayName, !name.isEmpty {
                record["senderDisplayName"] = name as NSString
            }
            record["recipeTitle"] = envelope.recipe.title as NSString
            record["createdAt"] = envelope.share.createdAt as NSDate

            do {
                _ = try await publicDB.save(record)
                appendToOutbox(recordName)
                return recordName
            } catch let ckError as CKError where ckError.code == .serverRecordChanged && attempt == 0 {
                // Collision on this random ID — retry once.
                continue
            }
            // Any other error (or a second collision) propagates.
        }
        // Shouldn't reach here — the loop either returns or throws.
        throw CloudKitServiceError.exhaustedRetries
    }

    // MARK: - Fetch

    /// Fetches a `RecipeShare` by record name and reconstructs the
    /// envelope. Throws `CloudKitServiceError.envelopeMissing` if the
    /// asset / file is unreachable; rethrows the underlying CKError
    /// otherwise (network failure, no-such-record, account
    /// unavailable). Caller maps these to user-facing messages.
    static func fetchShare(recordName: String) async throws -> LCRecipeShareV1 {
        let recordID = CKRecord.ID(recordName: recordName)
        let record = try await publicDB.record(for: recordID)

        guard let asset = record["envelope"] as? CKAsset,
              let assetURL = asset.fileURL else {
            throw CloudKitServiceError.envelopeMissing
        }
        let data = try Data(contentsOf: assetURL)
        // Route through the canonical decoder so schema-version
        // checking and friendly error mapping stay consistent with the
        // file / URL paths.
        return try RecipeShare.decode(fileData: data)
    }

    // MARK: - Delete

    /// Deletes the `RecipeShare` at `recordName`. Used by the
    /// account-deletion cascade and by future "revoke share" UI.
    /// Idempotent — deleting a missing record throws
    /// `CKError.unknownItem`, which the caller can swallow.
    static func deleteShare(recordName: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        _ = try await publicDB.deleteRecord(withID: recordID)
    }

    // MARK: - Outbox / cascade

    /// UserDefaults key for the local outbox — flat array of record
    /// names this device has uploaded. Used by `deleteAuthoredShares`
    /// (the Delete-Account cascade) to find what to clean up. Local
    /// to this install: a fresh reinstall has an empty outbox even if
    /// records still exist in CloudKit. The future TTL janitor (~14
    /// days) covers anything stranded that way.
    private static let outboxKey = "cloudShareOutbox.v1"

    /// Best-effort cascade for `UserAccount.deleteAccount()`. Walks
    /// the local outbox, deletes each cloud record, then clears the
    /// outbox. Per-record failures are swallowed so one network blip
    /// doesn't strand the whole cleanup — the user's expectation is
    /// "press button, my data is gone," and a partial cascade still
    /// improves on no cascade.
    static func deleteAuthoredShares() async {
        let names = outboxRecordNames()
        for name in names {
            try? await deleteShare(recordName: name)
        }
        clearOutbox()
    }

    static func outboxRecordNames() -> [String] {
        UserDefaults.standard.stringArray(forKey: outboxKey) ?? []
    }

    private static func appendToOutbox(_ recordName: String) {
        var outbox = outboxRecordNames()
        outbox.append(recordName)
        UserDefaults.standard.set(outbox, forKey: outboxKey)
    }

    private static func clearOutbox() {
        UserDefaults.standard.removeObject(forKey: outboxKey)
    }

    // MARK: - Helpers

    private static func generateRecordID() -> String {
        String((0..<recordIDLength).map { _ in
            recordIDAlphabet.randomElement()!
        })
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

enum CloudKitServiceError: LocalizedError {
    case envelopeMissing
    case exhaustedRetries

    var errorDescription: String? {
        switch self {
        case .envelopeMissing:
            return "This recipe share is missing data."
        case .exhaustedRetries:
            return "Couldn't generate a unique share ID. Try again."
        }
    }
}
