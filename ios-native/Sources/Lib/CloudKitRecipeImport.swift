import Foundation
import CloudKit
import os

/// Subsystem-scoped logger so audit-write failures surface in
/// Console.app / `log stream` during dev without leaking to the
/// release default subsystem. Mirrors the eventual home in
/// `CloudKitSubscriptions` once that file grows its own logger.
private let recipeImportLogger = Logger(
    subsystem: "com.llamascookbook.app",
    category: "CloudKitSubscriptions"
)

/// One row in the import audit log — corresponds to a single
/// `RecipeImport` CK record. Returned by
/// `CloudKitService.fetchRecipeImports(forOriginalRecipeID:)`;
/// consumed by `ImportersListSheet` to render the "who imported
/// my recipe" list, and by `RecipeDetailView`'s import-counter
/// chip refresh path.
///
/// **Design.** Frozen-in-time snapshot — call sites refresh by
/// re-fetching, not by holding a reference. `id` is the CK
/// recordName so SwiftUI lists can diff cleanly across re-fetches
/// (a previously-seen import keeps the same id even after a
/// refresh).
struct RecipeImportRecord: Identifiable, Hashable {
    /// CloudKit recordName for this audit row. Used as the stable
    /// SwiftUI list id; targeted deletions (account-deletion
    /// cascade) reuse it.
    let recordName: String
    /// Chain-root creator's userRecordName. The query field —
    /// every row matching `originalRecipeID == X` answers "how
    /// many times has this recipe been imported."
    let originalCreatorID: String
    /// Chain-root recipe id (the very first `Recipe.id` in the
    /// import graph). String, not UUID, because the chain root
    /// could have been authored on a future schema where ids
    /// aren't UUIDs.
    let originalRecipeID: String
    /// userRecordName of the user who imported the recipe.
    let importerID: String
    /// Denormalized importer display name — surfaced in the
    /// `ImportersListSheet` row alongside the import date so the
    /// list reads without a per-row UserProfile fetch.
    let importerDisplayName: String
    /// Immediate-parent userRecordName — who the importer
    /// imported FROM. Equals `originalCreatorID` for direct
    /// imports; differs when the chain has intermediate hops.
    let sourceUserID: String
    /// When the import happened. Sort key for the importers
    /// list (newest first).
    let importedAt: Date

    var id: String { recordName }
}

extension CloudKitService {
    // MARK: - RecipeImport

    /// CloudKit record type for the import audit log. Field
    /// schema (deployed Dev → Prod ahead of TestFlight, per
    /// the "Schema deployment ritual" in implement-social.md):
    ///
    /// - `originalCreatorID` — String, queryable. The chain
    ///   root creator's userRecordName. Powers the
    ///   account-deletion cascade query for "every import
    ///   audit involving me as creator."
    /// - `originalRecipeID` — String, queryable. The chain
    ///   root recipe id. Powers the counter query
    ///   (`count(* where originalRecipeID == X)`).
    /// - `importerID` — String, queryable. The importer's
    ///   userRecordName. Powers the cascade query for
    ///   "every import audit involving me as importer."
    /// - `importerDisplayName` — String. Denormalized so the
    ///   importers-list sheet renders without a per-row
    ///   UserProfile fetch.
    /// - `sourceUserID` — String. Immediate parent — who the
    ///   importer imported FROM. May equal `originalCreatorID`.
    /// - `importedAt` — Date/Time, queryable + sortable.
    ///
    /// Record name strategy: random token from `[A-Z2-9]` minus
    /// `I/O/0/1` (same alphabet as `RecipeShare`), so two
    /// audit rows can never collide on the same recordName.
    /// Idempotent re-import detection isn't a goal — a user
    /// importing the same recipe twice from the same friend
    /// produces two audit rows by design (the chip's
    /// "imported by N" counts events, not unique people).
    static let recipeImportRecordType = "RecipeImport"

    // MARK: Write

    /// Fire-and-forget audit write at import time. Called from
    /// `FriendRecipeDetailView.performImport` after the local
    /// SwiftData save succeeds, so a SwiftData failure doesn't
    /// leave a phantom audit row pointing at a recipe that
    /// never landed locally.
    ///
    /// **Best-effort semantics.** A network blip during the
    /// audit write means the counter under-reports by one
    /// import event for this recipe. Acceptable — the chip is
    /// a delight surface, not a billing receipt. The local
    /// `originalCreator*` / `originalSharer*` attribution
    /// still works without the audit row (it's denormalized
    /// into the importer's local Recipe).
    ///
    /// Two-attempt retry on collision matches `uploadShare`'s
    /// pattern — at the (vanishingly small) chance of a
    /// record-name clash, retry once with a fresh ID before
    /// giving up.
    static func writeRecipeImport(
        originalCreatorID: String,
        originalRecipeID: String,
        importerID: String,
        importerDisplayName: String,
        sourceUserID: String
    ) async throws {
        for attempt in 0..<2 {
            let recordName = generateRecipeImportRecordID()
            let recordID = CKRecord.ID(recordName: recordName)
            let record = CKRecord(recordType: recipeImportRecordType, recordID: recordID)
            record["originalCreatorID"] = originalCreatorID as NSString
            record["originalRecipeID"] = originalRecipeID as NSString
            record["importerID"] = importerID as NSString
            record["importerDisplayName"] = importerDisplayName as NSString
            record["sourceUserID"] = sourceUserID as NSString
            record["importedAt"] = Date() as NSDate

            do {
                _ = try await publicDB.save(record)
                return
            } catch let ckError as CKError where ckError.code == .serverRecordChanged && attempt == 0 {
                continue
            }
        }
        // Surface exhaustion to device logs — the calling site uses
        // `try?` so without this the failure is invisible in dev.
        recipeImportLogger.error(
            "writeRecipeImport exhausted retries for original=\(originalRecipeID, privacy: .public) importer=\(importerID, privacy: .public)"
        )
        throw CloudKitServiceError.exhaustedRetries
    }

    // MARK: Fetch

    /// Fetch every `RecipeImport` row for a given original recipe.
    /// Sorted newest-first so the `ImportersListSheet` can render
    /// directly without re-sorting. Empty result for a recipe
    /// nobody has imported yet — the call site checks `count`
    /// and renders the chip's "0" / hides the chip accordingly.
    ///
    /// Follows CloudKit cursors so large import counts do not
    /// silently stop at the first query page.
    static func fetchRecipeImports(forOriginalRecipeID originalRecipeID: String) async throws -> [RecipeImportRecord] {
        let predicate = NSPredicate(format: "originalRecipeID == %@", originalRecipeID)
        let query = CKQuery(recordType: recipeImportRecordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "importedAt", ascending: false)]
        let matchResults = try await queryAllRecords(matching: query)
        var results: [RecipeImportRecord] = []
        results.reserveCapacity(matchResults.count)
        for (id, result) in matchResults {
            guard case .success(let record) = result else { continue }
            guard let originalCreatorID = record["originalCreatorID"] as? String,
                  let originalRecipeID = record["originalRecipeID"] as? String,
                  let importerID = record["importerID"] as? String,
                  let importerDisplayName = record["importerDisplayName"] as? String,
                  let sourceUserID = record["sourceUserID"] as? String,
                  let importedAt = record["importedAt"] as? Date
            else { continue }
            results.append(RecipeImportRecord(
                recordName: id.recordName,
                originalCreatorID: originalCreatorID,
                originalRecipeID: originalRecipeID,
                importerID: importerID,
                importerDisplayName: importerDisplayName,
                sourceUserID: sourceUserID,
                importedAt: importedAt
            ))
        }
        return results
    }

    /// Convenience wrapper that returns just the count — used by
    /// `RecipeDetailView` to refresh `ImportCountCache` without
    /// paying the cost of decoding every audit row when
    /// the chip only needs the integer. Same query under the hood;
    /// CK doesn't expose a server-side `count(*)` so we still
    /// page through results, but the lighter decode keeps the
    /// stale-while-revalidate refresh snappy.
    static func countRecipeImports(forOriginalRecipeID originalRecipeID: String) async throws -> Int {
        try await fetchRecipeImports(forOriginalRecipeID: originalRecipeID).count
    }

    // MARK: Cascade

    /// Cascade — delete every `RecipeImport` row this user
    /// appears on, either as the importer or as the chain-root
    /// creator. Called from `UserAccount.deleteAccount` so a
    /// reviewer-tested account-deletion run leaves no trace of
    /// the user's social activity in the cloud.
    ///
    /// **Hard-delete vs anonymize.** The spec recommended
    /// anonymizing the importer name to preserve counter
    /// integrity. We hard-delete for simplicity — the counter
    /// is a delight surface, not a correctness invariant, and
    /// the App-Store-Review "delete every cloud trace"
    /// expectation reads more cleanly with hard-delete.
    /// Implications:
    /// - Deleter was the importer of N recipes → those N
    ///   audit rows go away. The original creators' chips drop
    ///   by 1 each.
    /// - Deleter was the chain root → every downstream import
    ///   audit row goes away. The deleter's own chip is moot
    ///   (their account is gone), but downstream importers'
    ///   local "Originally shared by [Deleter]" line still
    ///   renders (denormalized in SwiftData).
    ///
    /// Best-effort — silent on iCloud unavailability and
    /// individual delete failures, matching the
    /// `deleteAllFriendships` / `deleteAllPublishedRecipes`
    /// cascade pattern.
    static func deleteAllRecipeImports(for userRecordName: String) async {
        // Two single-field queries instead of an OR compound predicate:
        // CloudKit's public-DB OR requires every field carry a queryable
        // index, and a missing index would throw `invalidArguments` and
        // skip the entire cascade. Splitting also makes each leg fail
        // independently — a transient failure on one query no longer
        // strands rows that the other would have caught.
        let importerQuery = CKQuery(
            recordType: recipeImportRecordType,
            predicate: NSPredicate(format: "importerID == %@", userRecordName)
        )
        if let matchResults = try? await queryAllRecords(matching: importerQuery) {
            for (id, _) in matchResults {
                _ = try? await publicDB.deleteRecord(withID: id)
            }
        }
        let creatorQuery = CKQuery(
            recordType: recipeImportRecordType,
            predicate: NSPredicate(format: "originalCreatorID == %@", userRecordName)
        )
        if let matchResults = try? await queryAllRecords(matching: creatorQuery) {
            for (id, _) in matchResults {
                _ = try? await publicDB.deleteRecord(withID: id)
            }
        }
    }

    // MARK: - Helpers

    /// Random alphanumeric record name from the same
    /// `[A-Z2-9]` minus `I/O/0/1` alphabet `RecipeShare` uses.
    /// Internal-not-private so future cascades (slice 7+ if
    /// any) can mint matching IDs without redefining the
    /// alphabet.
    private static func generateRecipeImportRecordID() -> String {
        String((0..<recordIDLength).map { _ in
            recordIDAlphabet.randomElement()!
        })
    }
}
