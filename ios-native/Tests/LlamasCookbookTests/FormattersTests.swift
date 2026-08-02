import XCTest
@testable import LlamasCookbook

final class FormattersTests: XCTestCase {

    // MARK: - shortMonthDay

    func testShortMonthDayIsNonEmpty() {
        let result = Formatters.shortMonthDay.string(from: Date())
        XCTAssertFalse(result.isEmpty)
    }

    func testShortMonthDayForJune1() {
        // Noon local time so the calendar day is June 1 in every timezone
        // (midnight UTC renders as May 31 west of Greenwich).
        let date = Calendar.current.date(
            from: DateComponents(year: 2026, month: 6, day: 1, hour: 12)
        )!
        let result = Formatters.shortMonthDay.string(from: date)
        XCTAssertTrue(result.contains("1"), "Expected '1' in '\(result)'")
        XCTAssertTrue(result.contains("Jun") || result.contains("June"),
                      "Expected month abbreviation in '\(result)'")
    }

    func testShortMonthDayDiffersBetweenMonths() {
        let june1 = Date(timeIntervalSince1970: 1_748_736_000)  // 2025-06-01
        let july1 = Date(timeIntervalSince1970: 1_751_328_000)  // 2025-07-01
        let junStr  = Formatters.shortMonthDay.string(from: june1)
        let julStr  = Formatters.shortMonthDay.string(from: july1)
        XCTAssertNotEqual(junStr, julStr)
    }

    // MARK: - date (medium style)

    func testDateFormatterIsNonEmpty() {
        let result = Formatters.date.string(from: Date())
        XCTAssertFalse(result.isEmpty)
    }

    func testDateFormatterContainsYear() {
        // Use a well-known reference date so the year is predictable.
        let date = Date(timeIntervalSince1970: 1_748_736_000)  // 2025-06-01
        let result = Formatters.date.string(from: date)
        XCTAssertTrue(result.contains("2025"), "Expected '2025' in '\(result)'")
    }

    func testDateFormatterDiffersBetweenDates() {
        let d1 = Date(timeIntervalSince1970: 1_748_736_000)  // 2025-06-01
        let d2 = Date(timeIntervalSince1970: 1_751_328_000)  // 2025-07-01
        XCTAssertNotEqual(Formatters.date.string(from: d1), Formatters.date.string(from: d2))
    }
}
