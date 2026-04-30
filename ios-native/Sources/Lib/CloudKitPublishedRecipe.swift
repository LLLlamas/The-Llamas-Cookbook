import Foundation
import CloudKit

/// Lightweight summary of a `PublishedRecipe` record — enough to
/// render `FriendLibraryView`'s recipe-card list without downloading
/// the full envelope or photo CKAssets. Slice 4 consumes these to
/// build the friend's read-only library; slice 5 follows up with
/// `fetchPublishedRecipe(recordName:)` once the user taps into a
/// card.
struct PublishedRecipeSummary: Identifiable, Hashable {
    /// CloudKit recordName (== `localRecipeID.uuidString`). Stable
    /// across re-publishes; used to fetch the full envelope on tap.
    let recordName: String
    let ownerID: String
    let localRecipeID: UUID
    let recipeTitle: String
    let updatedAt: Date

    var id: String { recordName }
}

/// Full read-side payload for a single `PublishedRecipe` record —
/// the rendered envelope plus the chain-attribution metadata that
/// `RecipeShare.materializeFromPublished` needs to stamp the
/// receiver's local Recipe with the correct `originalCreator*` /
/// `originalRecipeID` values.
///
/// **Why not just the envelope.** `LCRecipeShareV1.share.sharedBy`
/// carries the chain-root display *name*, but the receiver also
/// needs the chain-root *user record name* (so a future "open the
/// original creator's cookbook" tap, or the slice 6 import-counter
/// query, has a stable identifier to pivot on). That's stored as a
/// CKRecord field beside the envelope asset, not inside the
/// envelope JSON, so we surface both together.
struct PublishedRecipeDetail {
    let envelope: LCRecipeShareV1
    /// userRecordName of the chain-root creator. Nil for recipes
    /// the publisher authored themselves (no chain).
    let originalCreatorID: String?
    /// Chain-root recipe id (the very first `Recipe.id` in the
    /// import graph). Nil for own-authored recipes.
    let originalRecipeID: String?
}

extension CloudKitService {
    // MARK: - PublishedRecipe

    /// CloudKit record type for the friend-visible library mirror.
    /// Field schema (deployed Dev → Prod ahead of TestFlight, with
    /// the manual-photo-asset-field caveat from CLAUDE.md — auto-
    /// discovery doesn't catch the `photo0`–`photo19` Asset slots
    /// without sample records carrying them):
    ///
    /// - `ownerID` — String, queryable. The publisher's iCloud
    ///   user record name; friends fetch by `ownerID == friend`.
    /// - `localRecipeID` — String. The publisher's local
    ///   `Recipe.id.uuidString`. Carried for completeness; the
    ///   recordName itself is set to the same value so upsert can
    ///   fetch by recordName without a query round-trip.
    /// - `envelope` — Asset. JSON envelope, `LCRecipeShareV1` shape
    ///   with photo bytes stripped (those travel as separate
    ///   CKAssets — same convention as `RecipeShare`).
    /// - `recipeTitle` — String, sortable. Denormalized so
    ///   `FriendLibraryView` can render the card list without
    ///   downloading every envelope.
    /// - `updatedAt` — Date/Time, queryable + sortable.
    /// - `originalCreatorID` — String, optional, queryable. Slice 5
    ///   chain attribution. Nil for everyone's own original recipes.
    /// - `originalRecipeID` — String, optional. Slice 5 chain root.
    /// - `photo0` … `photo<maxCloudPhotoCount-1>` — Asset, optional.
    ///
    /// Record name strategy: `recipe.id.uuidString` (the local
    /// `Recipe.id` UUID). Universally unique by definition, so two
    /// publishers can never collide on the same recordName even on
    /// public DB. Lets us upsert by recordName fetch without first
    /// querying by `ownerID + localRecipeID`.
    static let publishedRecipeRecordType = "PublishedRecipe"

    // MARK: Upsert

    /// Upsert a PublishedRecipe record from a live SwiftData
    /// `Recipe`. Builds the envelope on the caller's actor (must be
    /// MainActor since SwiftData @Model access is bound there),
    /// strips photo bytes into separate CKAssets, then writes
    /// off-main inside the async CK call.
    ///
    /// On failure the temp files are cleaned up and the throw
    /// propagates — caller (`LibraryMirrorService`) swallows so
    /// publishing is best-effort.
    @MainActor
    static func upsertPublishedRecipe(
        ownerID: String,
        sharedBy: String?,
        appVersion: String,
        recipe: Recipe,
        originalCreatorID: String?,
        originalRecipeID: String?
    ) async throws {
        let envelope = RecipeShare.envelope(
            for: recipe,
            sharedBy: sharedBy,
            appVersion: appVersion
        )

        // Strip photo bytes so the envelope JSON stays a few KB —
        // photos travel as sibling CKAssets (no base64 inflation).
        let strippedJSON = try makeEncoder().encode(envelope.withClearedPhotoBytes())
        let envelopeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-envelope-\(UUID().uuidString).json")
        try strippedJSON.write(to: envelopeURL, options: .atomic)

        let photoBytes = envelope.flattenedPhotoBytes()
        let attachedCount = min(photoBytes.count, maxCloudPhotoCount)

        var photoURLs: [URL?] = []
        for i in 0..<attachedCount {
            let bytes = photoBytes[i]
            guard !bytes.isEmpty else {
                photoURLs.append(nil)
                continue
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("publish-photo\(i)-\(UUID().uuidString).bin")
            try bytes.write(to: url, options: .atomic)
            photoURLs.append(url)
        }

        defer {
            try? FileManager.default.removeItem(at: envelopeURL)
            for url in photoURLs.compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // Capture for the async call — Recipe is @Model, not Sendable,
        // so we extract the bits we need into Sendable locals before
        // crossing the suspend boundary.
        let recordName = recipe.id.uuidString
        let recipeTitle = recipe.title

        let recordID = CKRecord.ID(recordName: recordName)
        let record: CKRecord
        do {
            record = try await publicDB.record(for: recordID)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            record = CKRecord(recordType: publishedRecipeRecordType, recordID: recordID)
        }

        record["ownerID"] = ownerID as NSString
        record["localRecipeID"] = recordName as NSString
        record["envelope"] = CKAsset(fileURL: envelopeURL)
        record["recipeTitle"] = recipeTitle as NSString
        record["updatedAt"] = Date() as NSDate

        // Slice 5 chain attribution: when the publisher imported
        // this recipe from someone else, carry the chain-root
        // identifiers forward so a downstream importer can preserve
        // the chain. nil for own-authored recipes; CKRecord with a
        // nil value explicitly removes the field, which is the
        // shape we want for the upsert path (recipe was previously
        // imported, then locally re-authored, → field should clear).
        record["originalCreatorID"] = originalCreatorID as NSString?
        record["originalRecipeID"] = originalRecipeID as NSString?

        // Clear stale photo slots first — a recipe that lost a photo
        // since last publish would otherwise have the old asset
        // dangling at the same index. CKRecord setting nil on a key
        // explicitly removes the field.
        for i in 0..<maxCloudPhotoCount {
            record["photo\(i)"] = nil
        }
        for (i, urlOpt) in photoURLs.enumerated() {
            if let url = urlOpt {
                record["photo\(i)"] = CKAsset(fileURL: url)
            }
        }

        _ = try await publicDB.save(record)
    }

    // MARK: Delete

    /// Delete a single PublishedRecipe by its local recipe id.
    /// Idempotent — `unknownItem` is treated as success.
    static func deletePublishedRecipe(localRecipeID: UUID) async throws {
        let recordID = CKRecord.ID(recordName: localRecipeID.uuidString)
        do {
            _ = try await publicDB.deleteRecord(withID: recordID)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            return
        }
    }

    /// Cascade — delete every PublishedRecipe owned by `ownerID`.
    /// Called from `UserAccount.deleteAccount`. Best-effort:
    /// individual delete failures are swallowed; reviewers testing
    /// account deletion should still see records gone within one
    /// retry of the cascade. (If failures pile up, mirror this
    /// pattern after `cloudShareOutbox` and add a pending-delete
    /// queue.)
    static func deleteAllPublishedRecipes(ownerID: String) async {
        let predicate = NSPredicate(format: "ownerID == %@", ownerID)
        let query = CKQuery(recordType: publishedRecipeRecordType, predicate: predicate)
        guard let matchResults = try? await queryAllRecords(matching: query) else {
            return
        }
        for (id, _) in matchResults {
            _ = try? await publicDB.deleteRecord(withID: id)
        }
    }

    // MARK: Fetch

    /// Fetch the per-recipe summaries for a friend's library —
    /// enough to render the card list without downloading photos.
    /// Sorted by `recipeTitle` ascending (matches the local
    /// LibraryView's A–Z default).
    static func fetchPublishedRecipeSummaries(ownerID: String) async throws -> [PublishedRecipeSummary] {
        let predicate = NSPredicate(format: "ownerID == %@", ownerID)
        let query = CKQuery(recordType: publishedRecipeRecordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "recipeTitle", ascending: true)]
        let matchResults = try await queryAllRecords(matching: query)
        var results: [PublishedRecipeSummary] = []
        for (id, result) in matchResults {
            guard case .success(let record) = result else { continue }
            guard let recipeTitle = record["recipeTitle"] as? String,
                  let localRecipeIDStr = record["localRecipeID"] as? String,
                  let localRecipeID = UUID(uuidString: localRecipeIDStr),
                  let updatedAt = record["updatedAt"] as? Date else {
                continue
            }
            results.append(PublishedRecipeSummary(
                recordName: id.recordName,
                ownerID: ownerID,
                localRecipeID: localRecipeID,
                recipeTitle: recipeTitle,
                updatedAt: updatedAt
            ))
        }
        return results
    }

    /// Fetch the full envelope + chain-attribution metadata for a
    /// single PublishedRecipe. Mirrors `fetchShare` — pulls the
    /// stripped envelope from the Asset, then walks the `photo<N>`
    /// siblings to re-inject bytes. The `originalCreatorID` /
    /// `originalRecipeID` fields piggyback on the same fetch so
    /// `FriendRecipeDetailView` and `materializeFromPublished` get
    /// the chain root in one round-trip.
    static func fetchPublishedRecipe(recordName: String) async throws -> PublishedRecipeDetail {
        let recordID = CKRecord.ID(recordName: recordName)
        let record = try await publicDB.record(for: recordID)
        guard let asset = record["envelope"] as? CKAsset,
              let assetURL = asset.fileURL else {
            throw CloudKitServiceError.envelopeMissing
        }
        let strippedEnvelope = try RecipeShare.decode(fileURL: assetURL)

        let totalPhotos = strippedEnvelope.recipe.photos.count
            + strippedEnvelope.recipe.steps.reduce(0) { $0 + $1.photos.count }
        let probeCount = min(totalPhotos, maxCloudPhotoCount)
        var photoBytes: [Data] = []
        photoBytes.reserveCapacity(probeCount)
        var totalPhotoBytes = 0
        for i in 0..<probeCount {
            guard let photoAsset = record["photo\(i)"] as? CKAsset,
                  let url = photoAsset.fileURL,
                  let bytes = readCappedAsset(at: url) else {
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
        let envelope = strippedEnvelope.injecting(photoBytes: photoBytes)

        return PublishedRecipeDetail(
            envelope: envelope,
            originalCreatorID: record["originalCreatorID"] as? String,
            originalRecipeID: record["originalRecipeID"] as? String
        )
    }

}
