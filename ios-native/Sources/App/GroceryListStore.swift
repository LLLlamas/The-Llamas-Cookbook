import Foundation
import SwiftData
import Observation
import CloudKit

/// Coordinator for the app-to-app shared grocery list — the live
/// "husband at the store" checklist. Owns three jobs:
///
///  1. **Mirror in** every list a friend shared *to* me as a local
///     `GroceryList(ownerIsMe: false)` so it shows up in the Lists tab,
///     reads offline (store Wi-Fi is flaky), and reuses
///     `GroceryListDetailView` unchanged.
///  2. **Sync down** live check/note changes onto BOTH my received
///     mirrors and my own shared lists, so a check-off on either side
///     lands on every participant.
///  3. **Push up** my local check-offs / notes / structure edits to the
///     `GroceryListShare` CloudKit record.
///
/// Reconciliation is keyed by `GroceryList.shareRecordName` (identical on
/// both sides — it's the cloud record name) and, within a list, by
/// `GroceryItem.shareIndex` (the slot mapping to `check<N>`/`note<N>`).
///
/// **Best-effort, like every other cloud path here.** Signed-out / iCloud-
/// unavailable / network-down all degrade to "the local list still works,
/// it just doesn't sync." A failed push leaves the local optimistic state
/// in place; the next `refresh()` reconciles against the server.
///
/// Lifecycle mirrors `FriendsStore`: one instance created in `RootView`,
/// injected via `.environment`, `configure`d with the `ModelContext` +
/// display name in `RootView.task`, and wired to pushes via
/// `observeRemotePushes()`.
@MainActor
@Observable
final class GroceryListStore {
    /// The local SwiftData context. Set once from `RootView.task`.
    @ObservationIgnored
    private var modelContext: ModelContext?

    /// The local user's display name, stamped onto every push as
    /// `revisedByName` so a recipient's banner can read "Sam checked off
    /// milk" (and the owner can see who's shopping). Refreshed by
    /// `RootView` whenever sign-in state changes.
    @ObservationIgnored
    var myDisplayName: String = ""

    /// True when a grocery-share push landed since the user last opened
    /// the Lists tab — drives the Lists tab badge dot. Cleared by
    /// `markSharedSeen()` when they look.
    private(set) var hasSharedUpdate = false

    /// Set when a list a friend shared shows up for the first time. Drives
    /// the in-app banner in `RootView`, which the user can dismiss or tap to
    /// open the list. Cleared by `clearIncomingShare()` once handled.
    private(set) var incomingShare: IncomingShare?

    /// False until the first successful recipient reconcile completes.
    ///
    /// Guards against announcing history: on a fresh install, a re-install,
    /// or a sign-in on a new device, the very first reconcile mirrors EVERY
    /// list already shared with this user. Those aren't news, and firing a
    /// banner per list would bury the user under toasts for lists they've
    /// been shopping for weeks. Only shares that appear *after* we know what
    /// the baseline looks like are genuinely new.
    @ObservationIgnored
    private var hasHydratedReceivedShares = false

    /// True while a `refresh()` is in flight (re-entrancy guard).
    @ObservationIgnored
    private var isRefreshing = false

    @ObservationIgnored
    private var remotePushObserver: NSObjectProtocol?

    /// True while a push-driven refresh + its quiet window are in flight
    /// (see `scheduleCoalescedRefresh`).
    @ObservationIgnored
    private var pushRefreshInFlight = false

    /// Set when a push lands during the quiet window, so one trailing
    /// refresh catches whatever the leading one missed.
    @ObservationIgnored
    private var pushArrivedDuringWindow = false

    /// Per-list pending structure uploads (see `syncStructureDebounced`).
    @ObservationIgnored
    private var pendingStructureSyncs: [UUID: Task<Void, Never>] = [:]

    func configure(modelContext: ModelContext, myDisplayName: String) {
        self.modelContext = modelContext
        self.myDisplayName = myDisplayName
    }

    // MARK: - Refresh

    /// Pull every share I'm a recipient of + every share I own, then
    /// reconcile both into local SwiftData. Best-effort; silently no-ops
    /// when iCloud isn't bound.
    func refresh() async {
        guard !isRefreshing, let context = modelContext else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let me = UserProfileMirror.cachedRecordID() else {
            // Signed out — drop any received mirrors so a previous user's
            // shared lists don't linger. Own lists are untouched.
            dropAllReceivedMirrors(in: context)
            return
        }

        // Both reconciles are DESTRUCTIVE when handed an empty set:
        // `reconcileReceived` deletes every mirror whose record isn't present,
        // and `reconcileOwned` strips the local sharing pointer off every owned
        // list whose record isn't present. So a THROWN fetch (network blip /
        // CKError / throttle) must never be flattened to `[]` — that reads as
        // "everything got unshared" and wipes local state the cloud record
        // still backs (and the owned side doesn't self-heal). Only reconcile
        // the side whose fetch actually succeeded; the other keeps its
        // last-known state and re-syncs on the next good refresh.
        if let received = try? await CloudGroceryListService.fetchSharesForRecipient(me) {
            reconcileReceived(received, in: context)
        }
        if let owned = try? await CloudGroceryListService.fetchSharesForOwner(me) {
            reconcileOwned(owned, in: context)
        }
    }

    /// The shared list a detail view is currently sitting on, if any.
    ///
    /// Set implicitly by `refreshSharedList` — the detail view already calls
    /// that on appear and on every poll, so the store learns what's on screen
    /// without the view having to tell it. Read by `scheduleCoalescedRefresh`
    /// to update the visible list FIRST when a push lands (one record fetch)
    /// instead of making the shopper wait on the two-query full reconcile.
    @ObservationIgnored
    private weak var activeSharedList: GroceryList?

    /// Pull just the cloud record backing the currently-open detail view.
    /// Used by `GroceryListDetailView` for push-driven refreshes and a
    /// lightweight active-screen polling fallback, so shoppers do not have
    /// to pop back to Lists before they see what someone else bought.
    func refreshSharedList(_ list: GroceryList) async {
        activeSharedList = list
        guard let context = modelContext,
              let recordName = list.shareRecordName else { return }
        do {
            let snapshot = try await CloudGroceryListService.fetchShare(recordName: recordName)
            if list.ownerIsMe {
                list.ownerID = snapshot.ownerID
                list.sharedRecipientIDs = snapshot.recipientIDs
                _ = applyLiveState(snapshot.items, to: list)
                list.updatedAt = snapshot.updatedAt
            } else {
                list.name = snapshot.listName
                list.ownerName = snapshot.ownerName.isEmpty ? nil : snapshot.ownerName
                list.ownerID = snapshot.ownerID
                list.shareRecordName = snapshot.recordName
                applyItems(snapshot.items, to: list, in: context, ownerAuthoritative: true)
                list.updatedAt = snapshot.updatedAt
            }
        } catch let ckError as CKError where ckError.code == .unknownItem {
            if list.ownerIsMe {
                clearSharingMetadata(on: list)
                list.touch()
            } else {
                context.delete(list)
            }
        } catch {
            // Best-effort; the active-screen polling loop / next push retries.
        }
    }

    // MARK: - Reconcile (recipient mirrors)

    private func reconcileReceived(_ snapshots: [GroceryShareSnapshot], in context: ModelContext) {
        let lists = allLists(in: context)
        let liveRecordNames = Set(snapshots.map(\.recordName))

        // Index existing received mirrors by their cloud record name.
        var mirrorByRecord: [String: GroceryList] = [:]
        for list in lists where !list.ownerIsMe {
            guard let rn = list.shareRecordName else {
                // A non-owned list with no record name is an orphan — drop it.
                context.delete(list)
                continue
            }
            if liveRecordNames.contains(rn) {
                mirrorByRecord[rn] = list
            } else {
                // The share vanished (owner unshared / removed me).
                context.delete(list)
            }
        }

        for snapshot in snapshots {
            let list: GroceryList
            if let existing = mirrorByRecord[snapshot.recordName] {
                list = existing
            } else {
                list = GroceryList(
                    name: snapshot.listName,
                    ownerIsMe: false,
                    shareRecordName: snapshot.recordName
                )
                context.insert(list)
                // A share we've never seen before. Announce it — but only
                // once we've established a baseline, so a fresh install
                // doesn't toast every list the user already had.
                if hasHydratedReceivedShares {
                    incomingShare = IncomingShare(
                        recordName: snapshot.recordName,
                        listName: snapshot.listName,
                        ownerName: snapshot.ownerName
                    )
                }
            }
            list.name = snapshot.listName
            list.ownerName = snapshot.ownerName.isEmpty ? nil : snapshot.ownerName
            list.ownerID = snapshot.ownerID
            list.shareRecordName = snapshot.recordName
            applyItems(snapshot.items, to: list, in: context, ownerAuthoritative: true)
            list.updatedAt = snapshot.updatedAt
        }

        hasHydratedReceivedShares = true
    }

    // MARK: - Reconcile (my own shared lists)

    private func reconcileOwned(_ snapshots: [GroceryShareSnapshot], in context: ModelContext) {
        let byRecord = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.recordName, $0) })
        for list in allLists(in: context) where list.ownerIsMe {
            guard let rn = list.shareRecordName else { continue }
            guard let snapshot = byRecord[rn] else {
                // Record gone server-side — fall back to a plain local list.
                clearSharingMetadata(on: list)
                continue
            }
            // The owner owns the item *structure*; only the live
            // check/note state flows back down onto existing rows.
            list.ownerID = snapshot.ownerID
            list.sharedRecipientIDs = snapshot.recipientIDs
            _ = applyLiveState(snapshot.items, to: list)
            list.updatedAt = snapshot.updatedAt
        }
    }

    // MARK: - Item application

    /// Recipient path: the owner is authoritative for the whole item set,
    /// so we add/update/remove local rows to match the snapshot exactly,
    /// keyed by `shareIndex`.
    private func applyItems(
        _ states: [SharedGroceryItemState],
        to list: GroceryList,
        in context: ModelContext,
        ownerAuthoritative: Bool
    ) {
        // Snapshot the relationship before mutating it (deleting members of
        // a live SwiftData relationship mid-iteration is unsafe).
        let existingItems = Array(list.items)
        var byIndex: [Int: GroceryItem] = [:]
        for item in existingItems {
            if let idx = item.shareIndex { byIndex[idx] = item }
        }
        let liveIndices = Set(states.map(\.index))

        for state in states {
            let item: GroceryItem
            if let existing = byIndex[state.index] {
                item = existing
            } else {
                item = GroceryItem(name: state.meta.name, shareIndex: state.index, order: state.index)
                context.insert(item)
                item.list = list
            }
            // Guard every write behind an inequality check (mirrors
            // applyLiveState) so an unchanged snapshot doesn't dirty
            // SwiftData and re-fire every @Query on each refresh.
            if item.name != state.meta.name { item.name = state.meta.name }
            if item.quantity != state.meta.quantity { item.quantity = state.meta.quantity }
            if item.unit != state.meta.unit { item.unit = state.meta.unit }
            if item.aisle != state.meta.aisle { item.aisle = state.meta.aisle }
            if item.isChecked != state.isChecked { item.isChecked = state.isChecked }
            if item.outOfStock != state.outOfStock { item.outOfStock = state.outOfStock }
            if item.substitution != state.substitution { item.substitution = state.substitution }
            if item.order != state.index { item.order = state.index }
            if item.shareIndex != state.index { item.shareIndex = state.index }
        }

        if ownerAuthoritative {
            // Remove rows the owner dropped (slot no longer present) and any
            // stray unindexed rows on a mirror.
            for item in existingItems where (item.shareIndex.map { !liveIndices.contains($0) } ?? true) {
                context.delete(item)
            }
        }
    }

    /// Owner path: keep my local structure, only sync the live mutable
    /// fields (check + note) down onto rows I already have.
    @discardableResult
    private func applyLiveState(_ states: [SharedGroceryItemState], to list: GroceryList) -> Bool {
        var byIndex: [Int: GroceryItem] = [:]
        for item in list.items {
            if let idx = item.shareIndex { byIndex[idx] = item }
        }
        var changed = false
        for state in states {
            guard let item = byIndex[state.index] else { continue }
            if item.isChecked != state.isChecked {
                item.isChecked = state.isChecked
                changed = true
            }
            if item.outOfStock != state.outOfStock {
                item.outOfStock = state.outOfStock
                changed = true
            }
            if item.substitution != state.substitution {
                item.substitution = state.substitution
                changed = true
            }
        }
        return changed
    }

    // MARK: - Share / unshare (owner)

    /// Share a local list with one or more friends. Stamps the list's
    /// sharing metadata, assigns each item a stable `shareIndex`, and
    /// uploads the `GroceryListShare` record seeded with the current
    /// check/note state. Returns true on a successful upload.
    @discardableResult
    func shareList(
        _ list: GroceryList,
        withRecipientIDs recipientIDs: [String],
        recipientLabel: String,
        ownerName: String
    ) async -> Bool {
        guard let ownerID = UserProfileMirror.cachedRecordID() else { return false }
        let recordName = list.shareRecordName ?? list.id.uuidString

        // Assign slot indices in current display order, capped.
        let ordered = Array(list.sortedItems.prefix(CloudGroceryListService.maxSharedItems))
        var metas: [SharedGroceryItemMeta] = []
        var checkedByIndex: [Int: Bool] = [:]
        var noteByIndex: [Int: String] = [:]
        for (i, item) in ordered.enumerated() {
            item.shareIndex = i
            metas.append(SharedGroceryItemMeta(
                id: item.id.uuidString,
                name: item.name,
                quantity: item.quantity,
                unit: item.unit,
                aisle: item.aisle
            ))
            checkedByIndex[i] = item.isChecked
            if let note = CloudGroceryListService.encodeAvailabilityNote(
                outOfStock: item.outOfStock,
                substitution: item.substitution
            ) {
                noteByIndex[i] = note
            }
        }
        // Rows past the cap can't sync live — clear any stale index.
        for item in list.sortedItems.dropFirst(CloudGroceryListService.maxSharedItems) {
            item.shareIndex = nil
        }

        do {
            try await CloudGroceryListService.upsertShare(
                recordName: recordName,
                ownerID: ownerID,
                ownerName: ownerName,
                listName: list.name,
                recipientIDs: recipientIDs,
                items: metas,
                checkedByIndex: checkedByIndex,
                noteByIndex: noteByIndex,
                revisedByName: ownerName
            )
        } catch {
            return false
        }

        list.shareRecordName = recordName
        list.ownerID = ownerID
        list.sharedRecipientIDs = recipientIDs
        list.sharedWithName = recipientLabel
        list.touch()
        return true
    }

    /// Stop sharing a list I own — delete the cloud record and strip the
    /// local sharing metadata. The recipients' mirrors fall away on their
    /// next refresh.
    func unshare(_ list: GroceryList) async {
        guard list.ownerIsMe, let recordName = list.shareRecordName else { return }
        try? await CloudGroceryListService.deleteShare(recordName: recordName)
        clearSharingMetadata(on: list)
        list.touch()
    }

    // MARK: - Live push (either side)

    /// Push a single item's check state after the user toggled it locally.
    /// No-op for non-shared lists / unindexed items.
    func pushCheck(_ item: GroceryItem) async {
        guard let list = item.list, list.isShared,
              let recordName = list.shareRecordName,
              let index = item.shareIndex else { return }
        try? await CloudGroceryListService.setItemChecked(
            recordName: recordName,
            index: index,
            checked: item.isChecked,
            revisedByName: myDisplayName
        )
    }

    /// Push a single item's shopper availability note / substitution.
    /// `notifyOwner` creates a separate one-shot alert record after the note
    /// save succeeds, so the owner gets a visible push for the shopper's `!`
    /// without turning every check-off into a banner.
    func pushNote(_ item: GroceryItem, notifyOwner: Bool = false) async {
        guard let list = item.list, list.isShared,
              let recordName = list.shareRecordName,
              let index = item.shareIndex else { return }
        let outOfStock = item.outOfStock
        let substitution = item.substitution
        let shouldNotifyOwner = notifyOwner && outOfStock && !list.ownerIsMe
        let ownerID = list.ownerID
        let listName = list.name
        let itemName = item.name
        do {
            try await CloudGroceryListService.setItemNote(
                recordName: recordName,
                index: index,
                outOfStock: outOfStock,
                substitution: substitution,
                revisedByName: myDisplayName
            )
            if shouldNotifyOwner, let ownerID, !ownerID.isEmpty {
                try? await CloudGroceryListService.createOutOfStockAlert(
                    ownerID: ownerID,
                    listRecordName: recordName,
                    listName: listName,
                    itemName: itemName,
                    shopperName: myDisplayName
                )
            }
        } catch {
            // Best-effort; local optimistic state remains and the next refresh
            // reconciles against CloudKit.
        }
    }

    /// Re-upload the full item set after the owner adds/removes rows on an
    /// already-shared list. Reassigns `shareIndex` and rewrites the record.
    func syncStructure(_ list: GroceryList, ownerName: String) async {
        guard list.ownerIsMe, list.isShared else { return }
        _ = await shareList(
            list,
            withRecipientIDs: list.sharedRecipientIDs,
            recipientLabel: list.sharedWithName ?? "",
            ownerName: ownerName
        )
    }

    /// Debounced `syncStructure` for rapid-fire structural edits (typing
    /// five items into the add bar = one full-record upload, not five).
    /// Same trailing-timer shape as `LibraryMirrorService.enqueueUpsert`.
    /// Check-offs and notes are NOT routed here — `pushCheck`/`pushNote`
    /// stay immediate.
    func syncStructureDebounced(_ list: GroceryList, ownerName: String) {
        guard list.ownerIsMe, list.isShared else { return }
        let id = list.id
        pendingStructureSyncs[id]?.cancel()
        pendingStructureSyncs[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if Task.isCancelled { return }
            await self?.syncStructure(list, ownerName: ownerName)
            self?.pendingStructureSyncs.removeValue(forKey: id)
        }
    }

    // MARK: - Badge

    func markSharedSeen() { hasSharedUpdate = false }

    /// Dismiss the in-app "a friend shared a list" banner — whether the user
    /// tapped the X or tapped through to the list.
    func clearIncomingShare() { incomingShare = nil }

    /// Look up a mirrored list by its cloud record name. Used to resolve a
    /// banner tap / push tap into the actual `GroceryList` to navigate to.
    func list(withShareRecordName recordName: String) -> GroceryList? {
        guard let context = modelContext else { return nil }
        return allLists(in: context).first { $0.shareRecordName == recordName }
    }

    // MARK: - Helpers

    private func allLists(in context: ModelContext) -> [GroceryList] {
        (try? context.fetch(FetchDescriptor<GroceryList>())) ?? []
    }

    private func dropAllReceivedMirrors(in context: ModelContext) {
        for list in allLists(in: context) where !list.ownerIsMe {
            context.delete(list)
        }
    }

    private func clearSharingMetadata(on list: GroceryList) {
        list.shareRecordName = nil
        list.ownerID = nil
        list.sharedRecipientIDs = []
        list.sharedWithName = nil
        for item in list.items { item.shareIndex = nil }
    }

    // MARK: - Push observation

    /// Subscribe to grocery-share pushes. Idempotent. On each one, flag
    /// the tab badge and refresh so both received mirrors and owned lists
    /// re-sync live.
    func observeRemotePushes() {
        guard remotePushObserver == nil else { return }
        remotePushObserver = NotificationCenter.default.addObserver(
            forName: CloudKitSubscriptions.didFireNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            guard let kindRaw = note.userInfo?["kind"] as? String,
                  CloudKitSubscriptions.FiredKind(rawValue: kindRaw) == .groceryList
            else { return }
            Task { @MainActor in
                self.hasSharedUpdate = true
                self.scheduleCoalescedRefresh()
            }
        }
    }

    /// One edit can fan out as several pushes (owner subscription + per-
    /// recipient), and our own writes push back to us — so refresh on the
    /// leading edge, then hold a quiet window. Pushes landing inside the
    /// window collapse into a single trailing refresh instead of each
    /// paying the full two-query + reconcile cost.
    ///
    /// The list the user is actually looking at is refreshed FIRST, on its
    /// own, before the full reconcile runs. That's a single `record(for:)`
    /// against a known record name versus two `CKQuery`s over every share
    /// the user participates in plus a full SwiftData diff — so the row
    /// under their eyes ticks over in roughly the time of one round trip,
    /// and the housekeeping catches up behind it. Without this, a check-off
    /// on the other phone visibly lagged the push that announced it.
    private func scheduleCoalescedRefresh() {
        if pushRefreshInFlight {
            pushArrivedDuringWindow = true
            return
        }
        pushRefreshInFlight = true
        Task { @MainActor in
            repeat {
                pushArrivedDuringWindow = false
                if let visible = activeSharedList, visible.isShared {
                    await refreshSharedList(visible)
                }
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            } while pushArrivedDuringWindow
            pushRefreshInFlight = false
        }
    }

    deinit {
        if let remotePushObserver {
            NotificationCenter.default.removeObserver(remotePushObserver)
        }
    }
}

/// A grocery list a friend just shared, surfaced once for the in-app banner.
///
/// Carries the display strings rather than the `GroceryList` itself so the
/// banner is a plain value: the SwiftData object may be re-fetched, and the
/// record name is the stable handle for resolving it at tap time.
struct IncomingShare: Equatable, Identifiable {
    let recordName: String
    let listName: String
    let ownerName: String

    var id: String { recordName }

    /// "Dad shared a grocery list with you" — falls back to a friend-less
    /// phrasing when the owner's display name is blank, which happens if
    /// they never set a profile name.
    var headline: String {
        let who = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return who.isEmpty
            ? "A friend shared a grocery list with you"
            : "\(who) shared a grocery list with you"
    }
}
