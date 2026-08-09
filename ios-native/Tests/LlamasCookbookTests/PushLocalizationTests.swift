import XCTest
@testable import LlamasCookbook

/// Locks the push-notification string table into the app bundle.
///
/// CloudKit's grocery "!" alert ships an `alertLocalizationKey` +
/// `alertLocalizationArgs` payload (see
/// `CloudKitSubscriptions.registerGrocerySubscriptions`). iOS resolves that
/// key against the app's own `Localizable.strings` **on the receiving
/// device** — and there is no fallback text: an unresolvable loc-key renders
/// as the raw key, so the owner's banner reads
/// "GROCERY_OOS_ALERT_BODY" instead of "Sam couldn't find …".
///
/// That's what shipped until 2026-08-08: `Localizable.strings` was bundled
/// at the app root instead of inside `en.lproj`, so it was present in the
/// bundle but invisible to string lookup — a state no build warning flags
/// and no UI reveals (SwiftUI `Text("literal")` falls back to the literal,
/// so ordinary strings look fine either way).
///
/// These assertions run against `Bundle.main`, which under the test host IS
/// the app bundle, so they fail if the `.lproj` structure regresses.
final class PushLocalizationTests: XCTestCase {

    /// Sentinel used to distinguish "key resolved" from "key missing" —
    /// `localizedString(forKey:value:table:)` echoes the key back when
    /// `value` is nil or empty, which is indistinguishable from a real hit.
    private let missing = "__MISSING__"

    private func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: missing, table: nil)
    }

    func testOutOfStockAlertBodyResolvesFromTheBundle() {
        let body = localized("GROCERY_OOS_ALERT_BODY")
        XCTAssertNotEqual(
            body, missing,
            "GROCERY_OOS_ALERT_BODY did not resolve. Localizable.strings is "
            + "probably outside en.lproj again — check `Resources/Localizations` "
            + "in project.yml and verify with: find LlamasCookbook.app -name '*.lproj'"
        )
        XCTAssertNotEqual(
            body, "GROCERY_OOS_ALERT_BODY",
            "Lookup echoed the key back — the string table isn't in the bundle"
        )
    }

    /// The three `%n$@` slots are positional and load-bearing: CloudKit
    /// substitutes `alertLocalizationArgs` — ["shopperName", "itemName",
    /// "listName"] — in that exact order. Dropping or reordering a slot
    /// silently mangles every out-of-stock banner.
    func testOutOfStockAlertBodyHasAllThreePositionalSlots() {
        let body = localized("GROCERY_OOS_ALERT_BODY")
        for slot in ["%1$@", "%2$@", "%3$@"] {
            XCTAssertTrue(
                body.contains(slot),
                "Missing \(slot) in GROCERY_OOS_ALERT_BODY — the args are "
                + "positional (shopperName, itemName, listName)"
            )
        }
    }

    /// Renders the template the way iOS will, as a readable guard against
    /// someone "simplifying" the positional specifiers into bare %@.
    func testOutOfStockAlertBodyFormatsIntoASentence() {
        let body = localized("GROCERY_OOS_ALERT_BODY")
        let rendered = String(format: body, "Sam", "oat milk", "Weekend Shop")
        XCTAssertTrue(rendered.contains("Sam"))
        XCTAssertTrue(rendered.contains("oat milk"))
        XCTAssertTrue(rendered.contains("Weekend Shop"))
        XCTAssertFalse(rendered.contains("%"), "Unsubstituted format specifier left in: \(rendered)")
    }
}
