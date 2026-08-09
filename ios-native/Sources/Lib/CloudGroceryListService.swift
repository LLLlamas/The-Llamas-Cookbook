import Foundation
import CloudKit

/// Static metadata for one item on a shared grocery list — the part the
/// list *owner* authors (name, measure, aisle). Travels inside the record's
/// `itemsJSON` string as an ordered array; the array position IS the item's
/// slot index, which maps to the live `check<N>` / `note<N>` CloudKit
/// fields. The owner's local `GroceryItem.id` rides along so a future
/// owner-side edit can re-key cleanly, but the slot index is the
/// load-bearing identity for the live mutable state.
struct SharedGroceryItemMeta: Codable, Equatable {
    let id: String
    let name: String
    let quantity: String?
    let unit: String?
    let aisle: String?
}

/// One item resolved for display/sync: the owner-authored `meta` merged
/// with the live, anyone-can-touch state (`isChecked` from `check<index>`,
/// availability from `note<index>`). `index` is the slot in the share record.
struct SharedGroceryItemState: Identifiable {
    let index: Int
    let meta: SharedGroceryItemMeta
    let isChecked: Bool
    let outOfStock: Bool
    let substitution: String?

    var id: Int { index }
}

/// Full read-side snapshot of a `GroceryListShare` record — everything
/// `GroceryListStore` needs to build (owner side) or mirror (recipient
/// side) a live list.
struct GroceryShareSnapshot: Identifiable {
    let recordName: String
    let ownerID: String
    let ownerName: String
    let listName: String
    let recipientIDs: [String]
    let updatedAt: Date
    let items: [SharedGroceryItemState]

    var id: String { recordName }
}

/// Public-DB service for the app-to-app shared grocery list — the
/// "husband at the store with a live checklist" flow. One CloudKit
/// `GroceryListShare` record per shared list is the single source of
/// truth for the mutable state both sides race on (item check-offs,
/// out-of-stock notes); the owner authors the item set, anyone on the
/// list can flip a check.
///
/// **Why the public DB (not CKShare / private sharing).** The rest of
/// the app's social graph (friends, published recipes) already lives on
/// the public DB keyed by iCloud user record names, and a grocery list
/// is throwaway, low-sensitivity data. Reusing the public-DB +
/// `recipientIDs` membership pattern keeps one mental model and one
/// subscription pipeline instead of standing up the private-DB CKShare
/// participant machinery for a shopping list.
///
/// **Anti-clobber per-item fields.** Item check state lives in flat
/// `check0…check<maxSharedItems-1>` Int fields (0/1) and notes in
/// `note0…note<maxSharedItems-1>` String fields — the exact same
/// per-slot pattern `RecipeShare`/`PublishedRecipe` use for
/// `photo0…photo19`. Two shoppers toggling *different* items only ever
/// write different fields, so a fetch-modify-save touches just the one
/// slot it changed. Concurrent writes to the *same* slot are resolved
/// last-writer-wins with a bounded `serverRecordChanged` retry.
///
/// **CloudKit Console schema (one-time portal trip, same caveat as the
/// photo asset slots — auto-discovery won't infer the full `check`/`note`
/// field range without sample records carrying them):**
/// - `ownerID` — String, queryable
/// - `ownerName` — String
/// - `listName` — String
/// - `recipientIDs` — String List, queryable (membership query +
///   subscription predicate both use `recipientIDs CONTAINS me`)
/// - `itemsJSON` — String (the `[SharedGroceryItemMeta]` blob; a 40-item
///   list is a few KB, comfortably inside CloudKit's String field budget)
/// - `revisedByName` — String (display name of the last editor; powers
///   the recipient's visible push body)
/// - `updatedAt` — Date/Time, queryable + sortable
/// - `check0` … `check<maxSharedItems-1>` — Int64 (0/1)
/// - `note0` … `note<maxSharedItems-1>` — String, optional:
///   `"out"` for unavailable, `"sub:<text>"` for a chosen substitute
///
/// Alert schema:
/// - `GroceryListAlert` record type, creation-only, one row per `!` event
/// - `ownerID` — String, queryable
/// - `listRecordName`, `listName`, `itemName`, `shopperName` — String
/// - `createdAt` — Date/Time
enum CloudGroceryListService {
    static let recordType = "GroceryListShare"
    static let alertRecordType = "GroceryListAlert"

    /// Per-list item cap for the shared/live form. Lists longer than this
    /// still work locally; only the first `maxSharedItems` rows get the
    /// live `check<N>`/`note<N>` slots. Matches the Console field range
    /// (`check0…check39`). A real grocery run is well under 40 lines.
    static let maxSharedItems = 40

    private static var publicDB: CKDatabase { CloudKitService.publicDB }

    // MARK: - Encode helpers

    private static func encodeItems(_ items: [SharedGroceryItemMeta]) -> String {
        guard let data = try? CloudKitService.makeEncoder().encode(items),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func decodeItems(_ json: String?) -> [SharedGroceryItemMeta] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SharedGroceryItemMeta].self, from: data)) ?? []
    }

    static func encodeAvailabilityNote(outOfStock: Bool, substitution: String?) -> String? {
        let trimmed = substitution?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return "sub:\(trimmed)"
        }
        return outOfStock ? "out" : nil
    }

    static func decodeAvailabilityNote(_ raw: String?) -> (outOfStock: Bool, substitution: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return (false, nil)
        }
        if raw == "out" { return (true, nil) }
        if raw.hasPrefix("sub:") {
            let value = String(raw.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? (false, nil) : (true, value)
        }
        // Back-compat for early app builds that wrote the raw substitute
        // string before the web/share format settled on the `sub:` prefix.
        return (true, raw)
    }

    // MARK: - Upsert (share / re-sync structure)

    /// Slots whose live check/note state must be reseeded from the owner's
    /// local values, because the slot's *occupant* changed — a different
    /// item moved into it (rows shifted after a delete), or the slot is new.
    ///
    /// Every other slot still holds the same item, so its live state on the
    /// server is newer than anything the owner has locally and must be left
    /// alone. Identity is the owner's stable `GroceryItem` id, so an in-place
    /// rename keeps the slot (and its check-off) rather than resetting it.
    static func slotsNeedingReseed(
        existing: [SharedGroceryItemMeta],
        incoming: [SharedGroceryItemMeta]
    ) -> Set<Int> {
        var slots: Set<Int> = []
        for i in 0..<min(incoming.count, maxSharedItems) {
            if i >= existing.count || existing[i].id != incoming[i].id {
                slots.insert(i)
            }
        }
        return slots
    }

    /// Create or overwrite the share record for a list. Called when the
    /// owner first shares, when they add/remove recipients, and when they
    /// edit the item set (add/remove rows) on an already-shared list.
    ///
    /// `checkedByIndex` / `noteByIndex` seed the live slots from the
    /// owner's current local state so a freshly-shared list lands on the
    /// recipient already reflecting whatever the owner had ticked.
    ///
    /// **A re-sync must not rewrite live state it didn't change.** The
    /// owner's structure pushes are debounced and their local copy of the
    /// check state lags the shopper's by a refresh interval, so blanket-
    /// writing every slot would un-check whatever the shopper ticked in that
    /// window. We therefore diff the server's `itemsJSON` against the
    /// incoming one and touch ONLY the slots whose occupant actually changed
    /// (`slotsNeedingReseed`); untouched slots keep the server's values. An
    /// owner adding a row at the end now writes exactly one new slot.
    ///
    /// A reseeded slot is written in full — including clearing a `note` the
    /// previous occupant left behind, so a new item never inherits a stale
    /// "couldn't find it".
    @discardableResult
    static func upsertShare(
        recordName: String,
        ownerID: String,
        ownerName: String,
        listName: String,
        recipientIDs: [String],
        items: [SharedGroceryItemMeta],
        checkedByIndex: [Int: Bool],
        noteByIndex: [Int: String],
        revisedByName: String
    ) async throws {
        let recordID = CKRecord.ID(recordName: recordName)
        let record: CKRecord
        do {
            record = try await publicDB.record(for: recordID)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }

        // Read the slot layout we're replacing BEFORE overwriting itemsJSON —
        // it's what tells us which slots changed hands. A brand-new record
        // decodes to `[]`, so every slot reseeds. (See `slotsNeedingReseed`.)
        let previousMetas = decodeItems(record["itemsJSON"] as? String)
        let reseed = slotsNeedingReseed(existing: previousMetas, incoming: items)

        record["ownerID"] = ownerID as NSString
        record["ownerName"] = ownerName as NSString
        record["listName"] = listName as NSString
        record["recipientIDs"] = recipientIDs.isEmpty ? nil : (recipientIDs as NSArray)
        record["itemsJSON"] = encodeItems(items) as NSString
        record["revisedByName"] = revisedByName as NSString
        record["updatedAt"] = Date() as NSDate

        let cap = min(items.count, maxSharedItems)
        for i in 0..<maxSharedItems {
            if i < cap {
                // Same item still in this slot → the server's live state is
                // authoritative (a shopper may have just ticked it). Leave the
                // fetched record's fields untouched.
                guard reseed.contains(i) else { continue }
                // New occupant → write the owner's state in full, clearing the
                // previous occupant's note rather than letting it carry over.
                record["check\(i)"] = ((checkedByIndex[i] ?? false) ? 1 : 0) as NSNumber
                if let note = noteByIndex[i], !note.isEmpty {
                    record["note\(i)"] = note as NSString
                } else {
                    record["note\(i)"] = nil
                }
            } else {
                // Slot no longer used (item removed) — clear stale state.
                record["check\(i)"] = nil
                record["note\(i)"] = nil
            }
        }

        _ = try await publicDB.save(record)
    }

    // MARK: - Live single-field updates (anti-clobber)

    /// Flip one item's in-cart check state. Fetch-modify-save touching
    /// only `check<index>` + the activity metadata, with a bounded retry
    /// on `serverRecordChanged` so two shoppers racing the same slot
    /// converge instead of throwing.
    static func setItemChecked(
        recordName: String,
        index: Int,
        checked: Bool,
        revisedByName: String
    ) async throws {
        guard index >= 0, index < maxSharedItems else { return }
        try await mutateSlot(recordName: recordName, revisedByName: revisedByName) { record in
            record["check\(index)"] = (checked ? 1 : 0) as NSNumber
        }
    }

    /// Set/clear one item's shopper availability note ("out" or "sub:…").
    static func setItemNote(
        recordName: String,
        index: Int,
        outOfStock: Bool,
        substitution: String?,
        revisedByName: String
    ) async throws {
        guard index >= 0, index < maxSharedItems else { return }
        let encoded = encodeAvailabilityNote(outOfStock: outOfStock, substitution: substitution)
        try await mutateSlot(recordName: recordName, revisedByName: revisedByName) { record in
            if let encoded {
                record["note\(index)"] = encoded as NSString
            } else {
                record["note\(index)"] = nil
            }
        }
    }

    /// Creation-only push trigger for a shopper's `!` action. The owner has
    /// a separate CKQuerySubscription on this record type so ordinary check
    /// updates stay silent, while out-of-stock events get an immediate alert.
    static func createOutOfStockAlert(
        ownerID: String,
        listRecordName: String,
        listName: String,
        itemName: String,
        shopperName: String
    ) async throws {
        let record = CKRecord(
            recordType: alertRecordType,
            recordID: CKRecord.ID(recordName: UUID().uuidString)
        )
        // The owner's push body interpolates shopperName/itemName/listName
        // (see GROCERY_OOS_ALERT_BODY) — keep every slot non-empty so a
        // blank display name can't render " couldn't find …".
        let shopper = shopperName.trimmingCharacters(in: .whitespacesAndNewlines)
        record["ownerID"] = ownerID as NSString
        record["listRecordName"] = listRecordName as NSString
        record["listName"] = listName as NSString
        record["itemName"] = itemName as NSString
        record["shopperName"] = (shopper.isEmpty ? "Your shopper" : shopper) as NSString
        record["createdAt"] = Date() as NSDate
        _ = try await publicDB.save(record)
    }

    /// Write one slot. `apply` mutates only the single field the caller
    /// cares about; we stamp the activity metadata so the push body /
    /// "last touched" reads stay honest.
    ///
    /// **Fast path — one round trip.** We build the record locally rather
    /// than fetching it, and let CloudKit merge just the keys we set
    /// (`savePolicy = .changedKeys`). The old fetch-modify-save spent a
    /// whole extra round trip re-reading a record we then ignored every
    /// field of, which put ~2× the network latency between a shopper's tap
    /// and the other phone learning about it. A blind patch is also *more*
    /// clobber-safe, not less: the payload physically cannot contain
    /// another shopper's slot, so there is nothing to race over and no
    /// `serverRecordChanged` to retry.
    ///
    /// The fetch-modify-save loop stays as a fallback for anything the
    /// blind write can't express (an environment that rejects `.changedKeys`
    /// on an unfetched record, say) — a check-off is not worth losing to an
    /// optimization, and the fallback is the exact code that shipped before.
    private static func mutateSlot(
        recordName: String,
        revisedByName: String,
        apply: @escaping (CKRecord) -> Void
    ) async throws {
        let recordID = CKRecord.ID(recordName: recordName)

        let patch = CKRecord(recordType: recordType, recordID: recordID)
        apply(patch)
        patch["revisedByName"] = revisedByName as NSString
        patch["updatedAt"] = Date() as NSDate
        do {
            try await saveMerging(patch)
            return
        } catch let ckError as CKError where ckError.code == .unknownItem {
            // The share is genuinely gone — surface it; the caller's
            // refresh path tears down the local mirror.
            throw ckError
        } catch {
            // Anything else: fall through to the conservative path.
        }

        var attempt = 0
        while true {
            do {
                let record = try await publicDB.record(for: recordID)
                apply(record)
                record["revisedByName"] = revisedByName as NSString
                record["updatedAt"] = Date() as NSDate
                _ = try await publicDB.save(record)
                return
            } catch let ckError as CKError where ckError.code == .serverRecordChanged && attempt < 3 {
                // Someone else wrote between our fetch and save — re-read
                // the latest and re-apply our one-field delta on top.
                attempt += 1
                continue
            }
        }
    }

    /// Save a locally-built partial record, merging only the keys it set
    /// into whatever the server already has.
    ///
    /// `CKDatabase.save(_:)` can't express this — it uses
    /// `.ifServerRecordUnchanged`, which needs a change tag we deliberately
    /// never fetched — so we drop to the operation API. `.userInitiated`
    /// matters as much as the saved round trip: a check-off is a direct
    /// response to a tap, and at the default QoS CloudKit is free to let it
    /// wait behind background traffic.
    private static func saveMerging(_ record: CKRecord) async throws {
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys
        operation.isAtomic = true
        operation.qualityOfService = .userInitiated
        operation.configuration.isLongLived = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            publicDB.add(operation)
        }
    }

    // MARK: - Fetch

    static func fetchSharesForRecipient(_ me: String) async throws -> [GroceryShareSnapshot] {
        let predicate = NSPredicate(format: "recipientIDs CONTAINS %@", me)
        return try await fetchSnapshots(predicate: predicate)
    }

    static func fetchSharesForOwner(_ me: String) async throws -> [GroceryShareSnapshot] {
        let predicate = NSPredicate(format: "ownerID == %@", me)
        return try await fetchSnapshots(predicate: predicate)
    }

    static func fetchShare(recordName: String) async throws -> GroceryShareSnapshot {
        let record = try await publicDB.record(for: CKRecord.ID(recordName: recordName))
        return snapshot(from: record)
    }

    private static func fetchSnapshots(predicate: NSPredicate) async throws -> [GroceryShareSnapshot] {
        let query = CKQuery(recordType: recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        let matchResults = try await CloudKitService.queryAllRecords(matching: query)
        var snapshots: [GroceryShareSnapshot] = []
        for (_, result) in matchResults {
            guard case .success(let record) = result else { continue }
            snapshots.append(snapshot(from: record))
        }
        return snapshots
    }

    private static func snapshot(from record: CKRecord) -> GroceryShareSnapshot {
        let metas = decodeItems(record["itemsJSON"] as? String)
        let cap = min(metas.count, maxSharedItems)
        var items: [SharedGroceryItemState] = []
        for i in 0..<cap {
            let checked = ((record["check\(i)"] as? Int) ?? 0) != 0
            let availability = decodeAvailabilityNote(record["note\(i)"] as? String)
            items.append(SharedGroceryItemState(
                index: i,
                meta: metas[i],
                isChecked: checked,
                outOfStock: availability.outOfStock,
                substitution: availability.substitution
            ))
        }
        return GroceryShareSnapshot(
            recordName: record.recordID.recordName,
            ownerID: (record["ownerID"] as? String) ?? "",
            ownerName: (record["ownerName"] as? String) ?? "",
            listName: (record["listName"] as? String) ?? "Grocery List",
            recipientIDs: (record["recipientIDs"] as? [String]) ?? [],
            updatedAt: (record["updatedAt"] as? Date) ?? .distantPast,
            items: items
        )
    }

    // MARK: - Delete / unshare

    /// Tear down one share record (owner unshares, or the local list is
    /// deleted). Idempotent — a missing record is treated as success.
    static func deleteShare(recordName: String) async throws {
        do {
            _ = try await publicDB.deleteRecord(withID: CKRecord.ID(recordName: recordName))
        } catch let ckError as CKError where ckError.code == .unknownItem {
            return
        }
    }

    /// Account-deletion cascade — every share and grocery alert this user
    /// owns. Routes through `CloudPendingDeleteQueue` for the same
    /// flaky-network resiliency the other social cascades have
    /// (Guideline 5.1.1(v)).
    static func deleteAllOwned(ownerID: String) async {
        let predicate = NSPredicate(format: "ownerID == %@", ownerID)
        var enqueued = false

        let shareQuery = CKQuery(recordType: recordType, predicate: predicate)
        if let matchResults = try? await CloudKitService.queryAllRecords(matching: shareQuery) {
            let names = matchResults.map { $0.0.recordName }
            CloudPendingDeleteQueue.enqueueMany(recordType: recordType, recordNames: names)
            enqueued = enqueued || !names.isEmpty
        }

        let alertQuery = CKQuery(recordType: alertRecordType, predicate: predicate)
        if let matchResults = try? await CloudKitService.queryAllRecords(matching: alertQuery) {
            let names = matchResults.map { $0.0.recordName }
            CloudPendingDeleteQueue.enqueueMany(recordType: alertRecordType, recordNames: names)
            enqueued = enqueued || !names.isEmpty
        }

        if enqueued {
            await CloudPendingDeleteQueue.drain()
        }
    }
}
