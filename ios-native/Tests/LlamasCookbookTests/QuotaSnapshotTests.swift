import XCTest
@testable import LlamasCookbookNative

final class QuotaSnapshotTests: XCTestCase {

    // Helper — build a snapshot without touching the network.
    private func snapshot(
        plan: String,
        limit: Int = 5,
        used: Int,
        remaining: Int,
        resetAt: Date = Date(timeIntervalSince1970: 1_748_736_000) // 2025-06-01 UTC
    ) -> QuotaSnapshot {
        QuotaSnapshot(plan: plan, limit: limit, used: used, remaining: remaining, resetAt: resetAt)
    }

    // MARK: - isPro

    func testFreePlanIsNotPro() {
        XCTAssertFalse(snapshot(plan: "free", used: 0, remaining: 5).isPro)
    }

    func testProPlanIsPro() {
        XCTAssertTrue(snapshot(plan: "pro", limit: 30, used: 0, remaining: 30).isPro)
    }

    // MARK: - isMonthlyExhausted

    func testExhaustedWhenRemainingIsZero() {
        XCTAssertTrue(snapshot(plan: "free", used: 5, remaining: 0).isMonthlyExhausted)
    }

    func testNotExhaustedWhenRemainingIsPositive() {
        XCTAssertFalse(snapshot(plan: "free", used: 2, remaining: 3).isMonthlyExhausted)
    }

    func testExhaustedWhenRemainingIsNegative() {
        // Shouldn't occur in practice but guard against server inconsistency.
        XCTAssertTrue(snapshot(plan: "free", used: 6, remaining: -1).isMonthlyExhausted)
    }

    // MARK: - resetDateFormatted

    func testResetDateFormattedIsNonEmpty() {
        let s = snapshot(plan: "free", used: 0, remaining: 5)
        XCTAssertFalse(s.resetDateFormatted.isEmpty)
    }

    func testResetDateFormattedContainsDayNumber() {
        // Jun 1 → "Jun 1"
        let june1 = Date(timeIntervalSince1970: 1_748_736_000)
        let s = snapshot(plan: "free", used: 0, remaining: 5, resetAt: june1)
        XCTAssertTrue(s.resetDateFormatted.contains("1"), "Expected day '1' in '\(s.resetDateFormatted)'")
    }

    func testResetDateFormattedChangesWithMonth() {
        let june1 = Date(timeIntervalSince1970: 1_748_736_000)   // Jun 1 2025
        let july1 = Date(timeIntervalSince1970: 1_751_328_000)   // Jul 1 2025
        let sJune = snapshot(plan: "free", used: 0, remaining: 5, resetAt: june1)
        let sJuly = snapshot(plan: "free", used: 0, remaining: 5, resetAt: july1)
        XCTAssertNotEqual(sJune.resetDateFormatted, sJuly.resetDateFormatted)
    }
}
