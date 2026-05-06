import Foundation
import CloudKit

/// Thin wrapper around `CKContainer.publicCloudDatabase` for the
/// permalink-share flow. Sender uploads a `RecipeShare` record (envelope
/// JSON as `CKAsset` so it carries inline photos cleanly); recipient
/// fetches by random record ID to materialize the recipe
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

    /// Universal-Link host for the share-preview flow. Cloudflare
    /// Pages serves the `/r/<recordName>` route as an OG-tagged
    /// HTML page so Messages renders a rich preview bubble (recipe
    /// title + photo) on the recipient's side — custom URL schemes
    /// can't carry a rich preview through Messages, so we use a
    /// real HTTPS Universal Link instead. MUST match the
    /// `applinks:` value in `LlamasCookbook.entitlements` and the
    /// `webcredentials` / `applinks` host in
    /// `cloudflare-pages/.well-known/apple-app-site-association`.
    /// Three places, one string, no drift.
    static let shareLinkHost = "llamascookbook.pages.dev"

    /// Path prefix for share Universal Links. Mints to
    /// `https://<shareLinkHost>/<shareLinkPathPrefix>/<recordName>`.
    /// Kept distinct from "share" so the path doesn't collide with
    /// any future site sections (`/share` could become a marketing
    /// page).
    static let shareLinkPathPrefix = "r"

    /// Record type for the share-permalink hosting. Single record type
    /// in the schema for now.
    static let recipeShareRecordType = "RecipeShare"

    /// Length of the random share-record ID surfaced in the permalink
    /// URL. Twelve chars from the non-ambiguous 32-character alphabet
    /// gives about 60 bits of entropy, which is a better fit for public,
    /// unlisted links. Cloudflare still accepts legacy 6-char links.
    static let recordIDLength = 12

    /// Maximum number of per-photo `CKAsset` fields (`photo0` …
    /// `photo<maxCloudPhotoCount-1>`) we attach to a single record.
    /// Photos beyond this cap are dropped from the upload — the
    /// cloud-share recipient sees them as missing thumbnails. Realistic
    /// ceiling for a recipe is well under 20 (4-photo gallery cap +
    /// up to 3 photos per step × ~5 steps with photos = ~19), so the
    /// cap is mostly defensive. CloudKit Dashboard schema must declare
    /// `photo0` … `photo19` as Asset fields (all optional) to back
    /// this; the schema deploy is a one-time portal trip.
    static let maxCloudPhotoCount = 20

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

    typealias QueryMatchResult = (CKRecord.ID, Result<CKRecord, any Error>)

    /// CloudKit's async query API returns one page plus an optional
    /// cursor. Shared social paths use this helper so larger friend
    /// lists, import audit logs, and account-deletion cascades don't
    /// silently stop at the first page.
    static func queryAllRecords(matching query: CKQuery) async throws -> [QueryMatchResult] {
        let firstPage = try await publicDB.records(matching: query)
        var allMatches = firstPage.matchResults
        var cursor = firstPage.queryCursor

        while let nextCursor = cursor {
            let page = try await publicDB.records(continuingMatchFrom: nextCursor)
            allMatches.append(contentsOf: page.matchResults)
            cursor = page.queryCursor
        }

        return allMatches
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
    /// record and returns the random record name. Caller mints
    /// `llamascookbook://share/<recordName>` from this.
    ///
    /// Encoding strategy (revised 2026-04-28 for upload speed):
    /// - `envelope` field: photo-less JSON envelope written to a temp
    ///   file (KB-scale; photo arrays preserve `id` / `order` /
    ///   `caption` but `image` is empty).
    /// - `photo0` … `photo<N-1>` fields: each photo's *raw* bytes
    ///   (typically JPEG, already storage-budget-sized) attached as
    ///   `CKAsset`. No base64 inflation, no JSON-encoding of binary.
    /// - Receiver walks `LCRecipeShareV1.injecting(photoBytes:)` to
    ///   re-base64 the asset bytes into the envelope before
    ///   materializing.
    ///
    /// On the wire this saves ~33% bandwidth (no base64 overhead) and
    /// massively reduces the JSON envelope size, which is the dominant
    /// CPU cost for photo-heavy recipes. Cap of `maxCloudPhotoCount`
    /// flat photos; anything beyond drops on the floor (rare in
    /// practice).
    ///
    /// Retries once on `serverRecordChanged` (record-name collision)
    /// with a fresh ID; beyond that, the rare collision becomes a
    /// thrown error and the caller falls back to the local URL form.
    /// Temp files (envelope + each photo) cleaned up via `defer`
    /// regardless of save outcome.
    static func uploadShare(
        _ envelope: LCRecipeShareV1,
        senderDisplayName: String?
    ) async throws -> String {
        // 1. Strip photo bytes from the envelope JSON so it stays a
        //    few KB; the bytes travel as separate CKAsset fields.
        let envelopeURL = try writeStrippedEnvelopeToTempFile(envelope, prefix: "share")

        // 2. Flatten photo bytes (recipe gallery first, then each
        //    step's photos in canonical order). The position in this
        //    list IS the suffix of the record's `photo<N>` field.
        let photoBytes = envelope.flattenedPhotoBytes()
        let attachedCount = min(photoBytes.count, maxCloudPhotoCount)

        // 3. Each photo's bytes get their own temp file (CKAsset
        //    requires a file URL). `nil` slots represent empty / decode-
        //    failed photos — we skip attaching those as assets so the
        //    record doesn't carry empty `photo<N>` fields.
        var photoURLs: [URL?] = []
        for i in 0..<attachedCount {
            let bytes = photoBytes[i]
            guard !bytes.isEmpty else {
                photoURLs.append(nil)
                continue
            }
            // HEIC → JPEG for the share-bound copy so non-Apple link
            // unfurlers (WhatsApp, Slack, Discord, Chrome) can render
            // the og:image preview. Local storage stays HEIC.
            let shareBytes = ImageProcessing.transcodeHEICToJPEGForSharing(bytes)
            let url = try writePhotoBytesToTempFile(shareBytes, prefix: "share", index: i)
            photoURLs.append(url)
        }

        // 4. Cleanup of all temp files happens regardless of save
        //    outcome (success path or any retry/throw above).
        defer {
            try? FileManager.default.removeItem(at: envelopeURL)
            for url in photoURLs.compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // 5. Two attempts — collision is vanishingly unlikely (~1e-6
        //    at 1k records) but cheap to retry once on a fresh ID.
        for attempt in 0..<2 {
            let recordName = generateRecordID()
            let recordID = CKRecord.ID(recordName: recordName)
            let record = CKRecord(recordType: recipeShareRecordType, recordID: recordID)
            record["envelope"] = CKAsset(fileURL: envelopeURL)
            for (i, urlOpt) in photoURLs.enumerated() {
                if let url = urlOpt {
                    record["photo\(i)"] = CKAsset(fileURL: url)
                }
            }
            // Cap the record-level display-name column the same way the
            // envelope's `sharedBy` is capped — kept in lockstep so a
            // sender can't smuggle a longer / spoof-y name in via the
            // sibling field.
            if let name = RecipeShare.cappedDisplayName(senderDisplayName) {
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
    /// envelope. Reads the photo-less envelope from the `envelope`
    /// CKAsset, then walks `photo0` … `photo<N-1>` in canonical order
    /// to re-inject photo bytes via
    /// `LCRecipeShareV1.injecting(photoBytes:)`. Throws
    /// `CloudKitServiceError.envelopeMissing` if the envelope asset
    /// is unreachable; rethrows underlying CKError otherwise (network
    /// failure, no-such-record, account unavailable). Caller maps
    /// these to user-facing messages.
    /// Per-photo CKAsset size cap. CloudKit doesn't refuse oversized
    /// uploads on the public DB, so a malicious sender could attach a
    /// huge photo asset and starve the receiver's memory. 10 MB is
    /// well above what `ImageProcessing.prepare` would emit for a
    /// gallery photo (~250 KB-2 MB target) and leaves headroom for
    /// HEIC originals.
    static let maxCloudPhotoBytes = 10_000_000

    /// Total receive-side cap for all photo CKAssets attached to one
    /// recipe record. This keeps base64 reinjection from multiplying
    /// a large public record into a much larger heap spike.
    static let maxCloudTotalPhotoBytes = 40_000_000

    static func fetchShare(recordName: String) async throws -> LCRecipeShareV1 {
        let recordID = CKRecord.ID(recordName: recordName)
        let record = try await publicDB.record(for: recordID)

        guard let asset = record["envelope"] as? CKAsset,
              let assetURL = asset.fileURL else {
            throw CloudKitServiceError.envelopeMissing
        }
        // Stat-check + size-cap before reading bytes. `decode(fileURL:)`
        // is the same guarded entry point the file / share-extension
        // ingest paths use; routing through it keeps the OOM-defense
        // and schema-version checks in one place.
        let strippedEnvelope = try RecipeShare.decode(fileURL: assetURL)

        // Walk the photo<N> asset fields in flat canonical order; the
        // injecting helper on LCRecipeShareV1 walks the same order to
        // re-base64 each into the matching SharePhoto.image field.
        // Stop at the envelope's actual photo count rather than
        // probing all maxCloudPhotoCount slots blindly.
        let totalPhotos = strippedEnvelope.recipe.photos.count + strippedEnvelope.recipe.steps.reduce(0) { $0 + $1.photos.count }
        let probeCount = min(totalPhotos, maxCloudPhotoCount)
        var photoBytes: [Data] = []
        photoBytes.reserveCapacity(probeCount)
        var totalPhotoBytes = 0
        for i in 0..<probeCount {
            guard let photoAsset = record["photo\(i)"] as? CKAsset,
                  let url = photoAsset.fileURL,
                  let bytes = readCappedAsset(at: url) else {
                // Empty Data() keeps the index sequence aligned with
                // the envelope's photo arrays — `injecting(photoBytes:)`
                // treats empty entries as "missing" and skips them
                // during materialize.
                photoBytes.append(Data())
                continue
            }
            guard totalPhotoBytes + bytes.count <= maxCloudTotalPhotoBytes else {
                photoBytes.append(Data())
                continue
            }
            totalPhotoBytes += bytes.count
            photoBytes.append(bytes)
        }
        return strippedEnvelope.injecting(photoBytes: photoBytes)
    }

    /// Reads a CKAsset file URL with the per-photo size cap enforced
    /// *before* loading bytes into memory. Returns nil for
    /// over-cap files (caller treats nil as "missing photo" and
    /// continues), and for any underlying read error (network blip
    /// during CKAsset materialization, asset not yet downloaded). The
    /// stat check uses `attributesOfItem` rather than reading the
    /// whole file and measuring, so a hostile 1 GB asset never hits
    /// the heap.
    /// Internal-not-private so other CloudKitService extensions
    /// (`CloudKitPublishedRecipe`) can reuse the same OOM-defense.
    static func readCappedAsset(at url: URL) -> Data? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        if let size = attrs[.size] as? Int, size > maxCloudPhotoBytes {
            return nil
        }
        return try? Data(contentsOf: url)
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
    /// names this device has uploaded. Used as the cascade source
    /// when the user hits Delete Account. Local to this install: a
    /// fresh reinstall has an empty outbox even if records still
    /// exist in CloudKit. The eventual TTL janitor (~14 days) covers
    /// records stranded that way.
    private static let outboxKey = "cloudShareOutbox.v1"

    /// Cascade for `UserAccount.deleteAccount()`. Drops every
    /// authored RecipeShare into `CloudPendingDeleteQueue` and drains
    /// it — same pattern the slice 2-6 cascades use. Records that
    /// delete successfully (or that CloudKit reports as already gone
    /// via `unknownItem`) drop out of the queue. Records that fail
    /// with any other error (network blip, account unavailable,
    /// throttling) stay queued; the launch-time drain in
    /// `RootView.task` picks them up. App Review's flaky-network
    /// test for Account Deletion needs this resiliency under
    /// Guideline 5.1.1(v).
    static func deleteAuthoredShares() async {
        let names = outboxRecordNames()
        if !names.isEmpty {
            CloudPendingDeleteQueue.enqueueMany(
                recordType: recipeShareRecordType,
                recordNames: names
            )
            clearOutbox()
        }
        await CloudPendingDeleteQueue.drain()
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

    /// Local JSON encoder for upload paths. Internal-not-private so
    /// other CloudKitService extensions (`CloudKitPublishedRecipe`)
    /// can reuse the same encoder configuration.
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Writes the photo-less form of `envelope` to a unique temp file
    /// and returns the URL. Both upload paths (file/link share via
    /// `uploadShare` and friend-cookbook mirror via
    /// `upsertPublishedRecipe`) use this — photos always travel as
    /// sibling `CKAsset` fields, never inside the envelope JSON, to
    /// avoid base64 inflation. `prefix` differentiates the temp file
    /// in the system tmpdir for diagnostics; e.g. `share` vs `publish`.
    /// Caller is responsible for `try? FileManager.default.removeItem`
    /// in a `defer` block — the helper does not own cleanup.
    static func writeStrippedEnvelopeToTempFile(
        _ envelope: LCRecipeShareV1,
        prefix: String
    ) throws -> URL {
        let strippedJSON = try makeEncoder().encode(envelope.withClearedPhotoBytes())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-envelope-\(UUID().uuidString).json")
        try strippedJSON.write(to: url, options: .atomic)
        return url
    }

    /// Writes raw photo bytes to a unique temp file and returns the
    /// URL — paired with `writeStrippedEnvelopeToTempFile`. `prefix`
    /// + `index` keep the resulting filename diagnostic-friendly
    /// (`share-photo3-<uuid>.bin`). Bytes are NOT transcoded here —
    /// callers that need HEIC→JPEG transcoding (the file/link share
    /// path, per the CLAUDE.md hard invariant) handle that before
    /// passing bytes in. Callers that enforce per-photo / total
    /// budget caps (the friend-cookbook mirror path) likewise gate
    /// before the call.
    static func writePhotoBytesToTempFile(
        _ bytes: Data,
        prefix: String,
        index: Int
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-photo\(index)-\(UUID().uuidString).bin")
        try bytes.write(to: url, options: .atomic)
        return url
    }
}

enum CloudKitServiceError: LocalizedError {
    case envelopeMissing
    case exhaustedRetries
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .envelopeMissing:
            return "This recipe share is missing data."
        case .exhaustedRetries:
            return "Couldn't generate a unique share ID. Try again."
        case .notAuthorized:
            return "You don't have permission to change that record."
        }
    }
}
