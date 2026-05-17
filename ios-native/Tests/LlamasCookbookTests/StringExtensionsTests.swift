import XCTest
@testable import LlamasCookbookNative

final class StringExtensionsTests: XCTestCase {

    // MARK: - Optional<String>.trimmedIfNonEmpty

    func testNilReturnsNil() {
        let s: String? = nil
        XCTAssertNil(s.trimmedIfNonEmpty)
    }

    func testWhitespaceOnlyReturnsNil() {
        let s: String? = "   "
        XCTAssertNil(s.trimmedIfNonEmpty)
    }

    func testNewlineOnlyReturnsNil() {
        let s: String? = "\n\t\n"
        XCTAssertNil(s.trimmedIfNonEmpty)
    }

    func testTrimsLeadingAndTrailingWhitespace() {
        let s: String? = "  hello  "
        XCTAssertEqual(s.trimmedIfNonEmpty, "hello")
    }

    func testPreservesInternalWhitespace() {
        let s: String? = "  hello world  "
        XCTAssertEqual(s.trimmedIfNonEmpty, "hello world")
    }

    func testAlreadyTrimmedReturnsSameValue() {
        let s: String? = "banana bread"
        XCTAssertEqual(s.trimmedIfNonEmpty, "banana bread")
    }

    func testSingleCharacterReturnsItself() {
        let s: String? = "x"
        XCTAssertEqual(s.trimmedIfNonEmpty, "x")
    }
}
