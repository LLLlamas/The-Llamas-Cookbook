import XCTest
@testable import LlamasCookbookNative

/// Mirrors `cloudflare-pages/test/moderation.test.js` — the Swift and JS
/// screens must agree, so the two suites cover the same cases.
final class ContentModerationTests: XCTestCase {

    // MARK: - Clean names pass (incl. Scunthorpe / culinary allowlist)

    func testCleanNamesPass() {
        let clean = [
            "Weekend Shop",
            "Taco Night",
            "Grandma's Sunday Sauce",
            // Culinary / place false positives that must NOT trip:
            "Shiitake Mushroom Soup",
            "Sea Bass Ceviche",
            "Cumin Lamb Stew",
            "Scunthorpe Pork Pie",
            "Sussex Pond Pudding",
            "Coq au Vin",
            "Cock-a-leekie Soup",
            "Hummus & Pita",
            "Mussels Mariniere",
            // Mild words we deliberately don't block:
            "Hell's Kitchen Chili",
            "What the Cluck Wings",
            "Mac n Cheese",
        ]
        for name in clean {
            XCTAssertTrue(ContentModeration.isClean(name), "Expected CLEAN: \(name)")
        }
    }

    // MARK: - Bad names blocked (incl. evasions)

    func testBadNamesBlocked() {
        let blocked = [
            "fuck",
            "My Bitch List",
            "this is bullshit",
            "asshole special",
            "F.U.C.K.",      // separator squashing
            "sh1t list",     // leetspeak 1 -> i
            "a$$hole",       // leetspeak $ -> s
            "fuuuuck off",   // repeated-char padding
            "F U C K",       // spaced letters
            "you retard",
            "faggot",
        ]
        for name in blocked {
            XCTAssertFalse(ContentModeration.isClean(name), "Expected BLOCKED: \(name)")
        }
    }

    // MARK: - check() detail + empty input

    func testCheckReportsMatchedTerm() {
        guard case let .blocked(matched) = ContentModeration.check("what the fuck") else {
            return XCTFail("Expected .blocked")
        }
        XCTAssertEqual(matched, "fuck")
    }

    func testEmptyInputIsClean() {
        XCTAssertTrue(ContentModeration.isClean(""))
        XCTAssertTrue(ContentModeration.isClean("   "))
        XCTAssertEqual(ContentModeration.check(""), .clean)
    }
}
