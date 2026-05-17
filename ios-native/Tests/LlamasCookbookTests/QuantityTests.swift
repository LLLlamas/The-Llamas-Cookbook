import XCTest
@testable import LlamasCookbookNative

final class QuantityTests: XCTestCase {

    // MARK: - Quantity.parse

    func testParseNilReturnsNil() {
        XCTAssertNil(Quantity.parse(nil))
    }

    func testParseEmptyReturnsNil() {
        XCTAssertNil(Quantity.parse(""))
    }

    func testParseWhitespaceReturnsNil() {
        XCTAssertNil(Quantity.parse("   "))
    }

    func testParseFreeformReturnsNil() {
        XCTAssertNil(Quantity.parse("a pinch"))
    }

    func testParseWholeInteger() {
        XCTAssertEqual(Quantity.parse("3"), 3.0)
    }

    func testParseSimpleFraction() {
        XCTAssertEqual(Quantity.parse("1/4"), 0.25, accuracy: 1e-9)
    }

    func testParseMixedNumberSpaceFormat() {
        XCTAssertEqual(Quantity.parse("3 1/4"), 3.25, accuracy: 1e-9)
    }

    func testParseMixedNumberAmpersandFormat() {
        XCTAssertEqual(Quantity.parse("3 & 1/4"), 3.25, accuracy: 1e-9)
    }

    func testParseDecimal() {
        XCTAssertEqual(Quantity.parse("0.5"), 0.5, accuracy: 1e-9)
    }

    // MARK: - Quantity.format

    func testFormatZeroReturnsZero() {
        XCTAssertEqual(Quantity.format(0), "0")
    }

    func testFormatQuarter() {
        XCTAssertEqual(Quantity.format(0.25), "1/4")
    }

    func testFormatHalf() {
        XCTAssertEqual(Quantity.format(0.5), "1/2")
    }

    func testFormatMixedNumber() {
        XCTAssertEqual(Quantity.format(1.25), "1 & 1/4")
    }

    func testFormatWholeNumber() {
        XCTAssertEqual(Quantity.format(3.0), "3")
    }

    // MARK: - Quantity.scale

    func testScaleNilReturnsNil() {
        XCTAssertNil(Quantity.scale(nil, by: 2))
    }

    func testScaleEmptyReturnsEmpty() {
        XCTAssertEqual(Quantity.scale("", by: 2), "")
    }

    func testScaleFactorOne() {
        XCTAssertEqual(Quantity.scale("3", by: 1), "3")
    }

    func testScaleDoubles() {
        XCTAssertEqual(Quantity.scale("1/4", by: 2), "1/2")
    }

    func testScaleFreeformPassthrough() {
        // "a pinch" can't be parsed — return unchanged
        XCTAssertEqual(Quantity.scale("a pinch", by: 2), "a pinch")
    }

    // MARK: - Quantity.displayFormat

    func testDisplayFormatNormalizesMixedNumber() {
        XCTAssertEqual(Quantity.displayFormat("3 1/4"), "3 & 1/4")
    }

    func testDisplayFormatAlreadyNormalizedPassthrough() {
        XCTAssertEqual(Quantity.displayFormat("3 & 1/4"), "3 & 1/4")
    }

    func testDisplayFormatLoneWholePassthrough() {
        XCTAssertEqual(Quantity.displayFormat("2"), "2")
    }

    func testDisplayFormatLoneFractionPassthrough() {
        XCTAssertEqual(Quantity.displayFormat("1/2"), "1/2")
    }

    func testDisplayFormatNilReturnsEmpty() {
        XCTAssertEqual(Quantity.displayFormat(nil), "")
    }

    // MARK: - Quantity.combine

    func testCombineBothParts() {
        XCTAssertEqual(Quantity.combine(whole: "3", frac: "1/4"), "3 & 1/4")
    }

    func testCombineWholeOnly() {
        XCTAssertEqual(Quantity.combine(whole: "2", frac: nil), "2")
    }

    func testCombineFracOnly() {
        XCTAssertEqual(Quantity.combine(whole: nil, frac: "1/2"), "1/2")
    }

    func testCombineNeitherReturnsEmpty() {
        XCTAssertEqual(Quantity.combine(whole: nil, frac: nil), "")
    }

    // MARK: - ClockFormat.mmss

    func testClockFormatZero() {
        XCTAssertEqual(ClockFormat.mmss(0), "0:00")
    }

    func testClockFormatSevenSeconds() {
        XCTAssertEqual(ClockFormat.mmss(7), "0:07")
    }

    func testClockFormatNinetySeconds() {
        XCTAssertEqual(ClockFormat.mmss(90), "1:30")
    }

    func testClockFormatLargeValue() {
        XCTAssertEqual(ClockFormat.mmss(754), "12:34")
    }

    func testClockFormatNegativeClampedToZero() {
        XCTAssertEqual(ClockFormat.mmss(-5), "0:00")
    }

    // MARK: - StringCase.cookbookTitle

    func testCookbookTitleNilFallback() {
        XCTAssertEqual(StringCase.cookbookTitle(displayName: nil), "Llamas Cookbook")
    }

    func testCookbookTitleEmptyFallback() {
        XCTAssertEqual(StringCase.cookbookTitle(displayName: "  "), "Llamas Cookbook")
    }

    func testCookbookTitleCookFallback() {
        XCTAssertEqual(StringCase.cookbookTitle(displayName: "Cook"), "Llamas Cookbook")
    }

    func testCookbookTitlePossessive() {
        XCTAssertEqual(StringCase.cookbookTitle(displayName: "Lorenzo"), "Lorenzo's Cookbook")
    }

    func testCookbookTitleSibilantDropsS() {
        XCTAssertEqual(StringCase.cookbookTitle(displayName: "Sas"), "Sas' Cookbook")
    }

    // MARK: - StringCase.friendsTitle

    func testFriendsTitleNilFallback() {
        XCTAssertEqual(StringCase.friendsTitle(displayName: nil), "Llamas Friends")
    }

    func testFriendsTitlePossessive() {
        XCTAssertEqual(StringCase.friendsTitle(displayName: "Alex"), "Alex's Friends")
    }

    // MARK: - StringCase.titleCase

    func testTitleCaseSimple() {
        XCTAssertEqual(StringCase.titleCase("banana bread"), "Banana Bread")
    }

    func testTitleCaseHyphenated() {
        XCTAssertEqual(StringCase.titleCase("gluten-free pasta"), "Gluten-Free Pasta")
    }

    func testTitleCaseApostropheNotSplitBoundary() {
        XCTAssertEqual(StringCase.titleCase("grandma's recipe"), "Grandma's Recipe")
    }

    func testTitleCasePreservesAcronym() {
        XCTAssertEqual(StringCase.titleCase("BBQ chicken"), "BBQ Chicken")
    }
}
