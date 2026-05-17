import XCTest
@testable import LlamasCookbookNative

final class SourdoughCalculatorTests: XCTestCase {

    // MARK: - table structure

    func testTableHasTenRows() {
        let rows = SourdoughCalculator.table(forTotal: 100)
        XCTAssertEqual(rows.count, 10)
    }

    func testTableRatiosAscending() {
        let rows = SourdoughCalculator.table(forTotal: 100)
        let ratios = rows.map(\.ratio)
        XCTAssertEqual(ratios, Array(1...10))
    }

    func testTableRowRatioMatchesIndex() {
        let rows = SourdoughCalculator.table(forTotal: 200)
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(row.ratio, i + 1)
        }
    }

    // MARK: - Math verification

    func testRatio1MathFor100g() {
        // 1:1:1 → denom = 3; starter = 100/3 ≈ 33.3, water = flour = 100/3 ≈ 33.3
        let row = SourdoughCalculator.row(forTotal: 100, ratio: 1)
        XCTAssertEqual(row.starter + row.water + row.flour, 100, accuracy: 1e-9)
    }

    func testRatio5MathFor300g() {
        // 1:5:5 → denom = 11
        let row = SourdoughCalculator.row(forTotal: 300, ratio: 5)
        XCTAssertEqual(row.starter + row.water + row.flour, 300, accuracy: 1e-9)
    }

    func testWaterEqualsFlour() {
        for ratio in 1...10 {
            let row = SourdoughCalculator.row(forTotal: 250, ratio: ratio)
            XCTAssertEqual(row.water, row.flour, accuracy: 1e-9, "ratio \(ratio)")
        }
    }

    func testSumEqualsTotalForAllRatios() {
        let total = 150.0
        for ratio in 1...10 {
            let row = SourdoughCalculator.row(forTotal: total, ratio: ratio)
            XCTAssertEqual(row.starter + row.water + row.flour, total, accuracy: 1e-9, "ratio \(ratio)")
        }
    }

    // MARK: - gramsValue

    func testGramsValueUnder100OneDecimal() {
        XCTAssertEqual(SourdoughCalculator.gramsValue(33.333), "33.3")
    }

    func testGramsValueExactlyDropsDecimal() {
        XCTAssertEqual(SourdoughCalculator.gramsValue(20.0), "20")
    }

    func testGramsValueAt100RoundsToInt() {
        XCTAssertEqual(SourdoughCalculator.gramsValue(100.0), "100")
    }

    func testGramsValueOver100NoDecimal() {
        XCTAssertEqual(SourdoughCalculator.gramsValue(133.7), "134")
    }

    // MARK: - formatGrams

    func testFormatGramsAppendsSuffix() {
        XCTAssertEqual(SourdoughCalculator.formatGrams(20.0), "20 g")
    }

    func testFormatGramsLargeValue() {
        XCTAssertEqual(SourdoughCalculator.formatGrams(150.0), "150 g")
    }

    // MARK: - Row helpers

    func testLabelFormat() {
        let row = SourdoughCalculator.row(forTotal: 100, ratio: 3)
        XCTAssertEqual(row.label, "1:3:3")
    }

    func testCompactTimeRangeStripsHours() {
        let row = SourdoughCalculator.row(forTotal: 100, ratio: 1)
        XCTAssertTrue(row.compactTimeRange.contains("h"), "Expected 'h' in '\(row.compactTimeRange)'")
        XCTAssertFalse(row.compactTimeRange.contains("hours"), "Did not expect 'hours' in '\(row.compactTimeRange)'")
    }

    func testTimeRangeIsNonEmptyForAllRatios() {
        for ratio in 1...10 {
            let row = SourdoughCalculator.row(forTotal: 100, ratio: ratio)
            XCTAssertFalse(row.timeRange.isEmpty, "ratio \(ratio) has empty timeRange")
        }
    }
}
