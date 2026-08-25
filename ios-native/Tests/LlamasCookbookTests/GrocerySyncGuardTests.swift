import XCTest
@testable import LlamasCookbook

/// Locks the two rules that decide whether a shared grocery list looks
/// "live" to the person watching it.
///
/// Both were written in response to the 2026-08 two-device run, where the
/// `!` marker only surfaced after backing out of the list and re-entering:
///
///  - `visiblePollInterval` — the old loop dropped to a 30 s heartbeat after
///    20 polls and never reset while the view stayed pushed, so re-entry
///    (which restarts the task) was genuinely the fastest way to see a change.
///  - `shouldApply` — the inbound merge had no ordering rule, so the
///    eventually-consistent `CKQuery` in `refresh()` could overwrite the
///    strongly-consistent `record(for:)` read that had just landed.
///
/// No `ModelContainer` here: the host app builds the full-schema container at
/// launch and SwiftData traps on a second one in-process. Nothing under test
/// touches a `ModelContext`.
@MainActor
final class GrocerySyncGuardTests: XCTestCase {

    // MARK: - Poll cadence

    func testVisiblePollStartsAtThreeSeconds() {
        XCTAssertEqual(GroceryListDetailView.visiblePollInterval(afterPolls: 0), 3)
        XCTAssertEqual(GroceryListDetailView.visiblePollInterval(afterPolls: 19), 3)
    }

    func testVisiblePollEasesButNeverExceedsTheCeiling() {
        XCTAssertEqual(GroceryListDetailView.visiblePollInterval(afterPolls: 20), 10)
        // The regression guard: a list left open for hours must not drift
        // back toward the old 30 s heartbeat.
        for polls in stride(from: 0, through: 5_000, by: 137) {
            XCTAssertLessThanOrEqual(
                GroceryListDetailView.visiblePollInterval(afterPolls: polls),
                GroceryListDetailView.maxVisiblePollInterval
            )
        }
    }

    func testFailureBackoffGrowsAndCaps() {
        XCTAssertEqual(GroceryListDetailView.failureBackoff(afterFailures: 0), 5)
        XCTAssertEqual(GroceryListDetailView.failureBackoff(afterFailures: 1), 10)
        XCTAssertEqual(GroceryListDetailView.failureBackoff(afterFailures: 4), 60)
        XCTAssertEqual(GroceryListDetailView.failureBackoff(afterFailures: 99), 60)
    }

    func testFailureBackoffIsAlwaysSlowerThanTheHealthyPoll() {
        // A rate-limited container must never be polled at the on-screen
        // cadence, or the backoff is decorative. The first retry is allowed
        // to be brisk (a blip should recover fast), but it must still be
        // slower than the fastest healthy poll, and it must overtake the
        // healthy ceiling quickly once failures persist.
        XCTAssertGreaterThan(
            GroceryListDetailView.failureBackoff(afterFailures: 0),
            GroceryListDetailView.visiblePollInterval(afterPolls: 0)
        )
        XCTAssertGreaterThanOrEqual(
            GroceryListDetailView.failureBackoff(afterFailures: 1),
            GroceryListDetailView.maxVisiblePollInterval
        )
    }

    // MARK: - Inbound snapshot ordering

    private func snapshot(_ recordName: String, updatedAt: Date) -> GroceryShareSnapshot {
        GroceryShareSnapshot(
            recordName: recordName,
            ownerID: "_owner",
            ownerName: "Owner",
            listName: "Weekend Shop",
            recipientIDs: ["_shopper"],
            updatedAt: updatedAt,
            items: []
        )
    }

    func testFirstSnapshotForARecordIsAlwaysApplied() {
        let store = GroceryListStore()
        XCTAssertTrue(store.shouldApply(snapshot("A", updatedAt: Date(timeIntervalSince1970: 100))))
    }

    func testNewerSnapshotIsApplied() {
        let store = GroceryListStore()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(store.shouldApply(snapshot("A", updatedAt: Date(timeIntervalSince1970: 100)), now: now))
        XCTAssertTrue(store.shouldApply(snapshot("A", updatedAt: Date(timeIntervalSince1970: 200)), now: now))
    }

    func testEqualSnapshotIsApplied() {
        // Application is idempotent and the per-field writes are
        // inequality-guarded, so equal timestamps must not be dropped —
        // `mutateSlot` can land two writes inside the same instant.
        let store = GroceryListStore()
        let now = Date(timeIntervalSince1970: 1_000)
        let stamp = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(store.shouldApply(snapshot("A", updatedAt: stamp), now: now))
        XCTAssertTrue(store.shouldApply(snapshot("A", updatedAt: stamp), now: now))
    }

    func testStaleSnapshotIsDroppedInsideTheGuardWindow() {
        // The actual bug: a fresh read lands, then the eventually-consistent
        // query returns an older one and reverts it on screen.
        let store = GroceryListStore()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(store.shouldApply(snapshot("A", updatedAt: Date(timeIntervalSince1970: 200)), now: now))
        XCTAssertFalse(store.shouldApply(snapshot("A", updatedAt: Date(timeIntervalSince1970: 100)), now: now))
    }

    func testStaleSnapshotIsAcceptedOnceTheGuardWindowExpires() {
        // `updatedAt` is stamped by the writing CLIENT, so skewed clocks can
        // emit timestamps that go backwards. The guard must expire, or the
        // slower phone's writes would be dropped permanently.
        let store = GroceryListStore()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(store.shouldApply(snapshot("A", updatedAt: Date(timeIntervalSince1970: 200)), now: now))
        let afterWindow = now.addingTimeInterval(GroceryListStore.staleSnapshotGuardWindow + 1)
        XCTAssertTrue(
            store.shouldApply(snapshot("A", updatedAt: Date(timeIntervalSince1970: 100)), now: afterWindow)
        )
    }

    func testGuardIsPerRecordNotGlobal() {
        // Two lists sync independently; a fresh snapshot for one must never
        // be blocked by a newer snapshot for the other.
        let store = GroceryListStore()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(store.shouldApply(snapshot("A", updatedAt: Date(timeIntervalSince1970: 500)), now: now))
        XCTAssertTrue(store.shouldApply(snapshot("B", updatedAt: Date(timeIntervalSince1970: 100)), now: now))
    }
}
