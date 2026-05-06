import Foundation
import CloudKit

/// Persistent retry queue for CloudKit record deletions across the
/// account-deletion cascade. Exists because Apple App Review tests
/// Delete Account under flaky-network conditions, and a single-shot
/// best-effort `try? await deleteRecord(withID:)` strands records in
/// CloudKit when the network blips mid-cascade — the user pressed
/// Delete Account, the local state was wiped, but the cloud record
/// is still there. App Review reviewers can spot the orphan via
/// CloudKit Console, and Guideline 5.1.1(v) compliance fails.
///
/// **Architecture.** This is a simple persistent queue of `(recordType,
/// recordName)` pairs in UserDefaults. The cascade methods that need
/// retry semantics (`deleteAllFriendships`, `deleteAllPublishedRecipes`,
/// `deleteAllRecipeImports`, `UserProfileMirror.deleteOnAccountDeletion`)
/// query the public DB for matching record IDs, enqueue every result,
/// then call `drain()`. Drain attempts each delete; success or
/// `unknownItem` drops the entry; any other error keeps it queued.
/// On the next launch (or the next cascade invocation) drain runs
/// again to clear survivors.
///
/// **Why not generalize the existing `cloudShareOutbox` /
/// `cloudSharePendingDelete` pair on `CloudKitService`.** Those track a
/// flat list of record names tied to one record type (`RecipeShare`).
/// They predated the social slices and stayed scoped to that path so
/// the cascade refactor wouldn't have to touch them. This queue runs
/// alongside, handling the four record types added by slices 2-6.
/// The existing share outbox keeps its dedicated pair for now;
/// migrating it is a future cleanup.
///
/// **Why a single global queue instead of per-cascade queues.** The
/// drain logic is identical for every record type — call
/// `publicDB.deleteRecord(withID:)`, treat `unknownItem` as success,
/// re-queue any other error. One queue means one drain to wire into
/// the launch hook. The `(recordType, recordName)` shape lets us
/// reconstruct the right `CKRecord.ID` regardless of which cascade
/// originally enqueued the entry.
///
/// **Concurrency.** All methods are static and operate on
/// UserDefaults, which is process-thread-safe. Drain is async and can
/// run from any actor; per-record deletes serialize internally.
enum CloudPendingDeleteQueue {
    /// UserDefaults key. The `.v1` suffix lets a future schema change
    /// (e.g. carrying a retry count alongside each entry) bump to
    /// `.v2` without colliding with existing on-device state.
    private static let queueKey = "cloudPendingDeleteQueue.v1"

    /// Legacy `cloudSharePendingDelete` UserDefaults key — predates
    /// this generic queue. Entries here are absorbed on first drain
    /// after upgrade so users with an in-flight delete from an older
    /// build don't lose the retry. Once absorbed the key is removed.
    private static let legacyShareDeleteKey = "cloudSharePendingDelete.v1"

    /// One queued delete request. `recordType` lets the drain pick
    /// the right CKRecord.ID; in practice `record(for: recordID)` and
    /// `deleteRecord(withID:)` are recordType-agnostic on the public
    /// DB, but storing the type makes diagnostics readable and lets
    /// us add per-type filtering later (e.g. if a future slice wants
    /// to drain only Friendship deletes).
    struct Entry: Codable, Equatable, Hashable {
        let recordType: String
        let recordName: String
    }

    // MARK: - Public API

    /// Add a single entry. Idempotent — duplicate enqueues collapse
    /// (Set semantics) since a successful delete already drops the
    /// entry, so multiple enqueues of the same record name just mean
    /// one drain attempt.
    static func enqueue(recordType: String, recordName: String) {
        enqueueMany(recordType: recordType, recordNames: [recordName])
    }

    /// Add multiple entries for the same record type. The cascade
    /// methods call this with the result of `queryAllRecords`.
    static func enqueueMany(recordType: String, recordNames: [String]) {
        guard !recordNames.isEmpty else { return }
        var current = pendingEntries()
        let existing = Set(current)
        for name in recordNames {
            let entry = Entry(recordType: recordType, recordName: name)
            if !existing.contains(entry) {
                current.append(entry)
            }
        }
        write(current)
    }

    /// Snapshot of currently-queued entries — exposed for diagnostics
    /// and tests; cascade callers don't need it (they enqueue + drain
    /// directly).
    static func pendingEntries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: queueKey) else {
            return []
        }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// Walk the queue, attempt to delete each record, drop entries
    /// that succeed or that the server reports as already gone.
    /// Re-queue everything else for the next call.
    ///
    /// **Idempotent.** Safe to invoke on every launch even when the
    /// queue is empty — the early return short-circuits before any
    /// CloudKit calls.
    static func drain() async {
        absorbLegacyShareDeletes()
        let queue = pendingEntries()
        guard !queue.isEmpty else { return }
        var remaining: [Entry] = []
        for entry in queue {
            let recordID = CKRecord.ID(recordName: entry.recordName)
            do {
                _ = try await CloudKitService.publicDB.deleteRecord(withID: recordID)
                // Success — drop entry by NOT appending to remaining.
            } catch let ckError as CKError where ckError.code == .unknownItem {
                // Already gone — server confirms the record doesn't
                // exist. Drop entry; nothing to retry.
            } catch {
                // Network blip, throttling, account unavailable, etc.
                // Keep queued for the next launch / next cascade.
                remaining.append(entry)
            }
        }
        write(remaining)
    }

    // MARK: - Internal helpers

    private static func write(_ entries: [Entry]) {
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: queueKey)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: queueKey)
    }

    /// One-time migration. The pre-2026-05 build kept a flat
    /// `[String]` of pending RecipeShare delete record names under
    /// `cloudSharePendingDelete.v1`. We absorb any leftover entries
    /// into this queue (with `recordType = "RecipeShare"`) and clear
    /// the legacy key so this is a no-op on every subsequent drain.
    /// Users mid-cascade during the upgrade keep their retry queue
    /// intact.
    private static func absorbLegacyShareDeletes() {
        guard let names = UserDefaults.standard.stringArray(forKey: legacyShareDeleteKey),
              !names.isEmpty else {
            // Make sure a stale empty entry is also cleaned up.
            UserDefaults.standard.removeObject(forKey: legacyShareDeleteKey)
            return
        }
        enqueueMany(
            recordType: CloudKitService.recipeShareRecordType,
            recordNames: names
        )
        UserDefaults.standard.removeObject(forKey: legacyShareDeleteKey)
    }
}
