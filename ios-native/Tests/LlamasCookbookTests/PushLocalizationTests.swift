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

    // MARK: - "A friend shared a list with you"

    func testSharedListAlertBodyResolvesFromTheBundle() {
        let body = localized("GROCERY_SHARE_NEW_BODY")
        XCTAssertNotEqual(body, missing, "GROCERY_SHARE_NEW_BODY did not resolve")
        XCTAssertNotEqual(body, "GROCERY_SHARE_NEW_BODY")
    }

    /// Args are ["ownerName", "listName"] — two slots, in that order.
    func testSharedListAlertBodyHasBothPositionalSlots() {
        let body = localized("GROCERY_SHARE_NEW_BODY")
        XCTAssertTrue(body.contains("%1$@"), "Missing owner-name slot")
        XCTAssertTrue(body.contains("%2$@"), "Missing list-name slot")
        XCTAssertFalse(body.contains("%3$@"), "Only two args are supplied")
    }

    func testSharedListAlertBodyReadsAsTheIntendedSentence() {
        let body = localized("GROCERY_SHARE_NEW_BODY")
        let rendered = String(format: body, "Dad", "Weekend Shop")
        XCTAssertTrue(rendered.hasPrefix("Dad just shared a new grocery list with you!"), rendered)
        XCTAssertTrue(rendered.contains("Weekend Shop"), rendered)
        XCTAssertFalse(rendered.contains("%"), "Unsubstituted format specifier left in: \(rendered)")
    }

    /// The push's category and action identifiers are baked into saved
    /// CKSubscriptions AND matched in `AppDelegate.didReceive`. If the two
    /// sides drift, the banner still arrives but its buttons do nothing.
    func testNotificationCategoryAndActionIdentifiersAreStable() {
        XCTAssertEqual(CloudKitSubscriptions.groceryShareCategory, "GROCERY_SHARE_NEW")
        XCTAssertEqual(CloudKitSubscriptions.groceryViewListAction, "GROCERY_VIEW_LIST")
        XCTAssertEqual(CloudKitSubscriptions.groceryDismissAction, "GROCERY_DISMISS")
    }

    /// The creation half and the update half must be distinct subscriptions
    /// — CloudKit bakes the payload in at save time, so one subscription
    /// covering both can only ever carry one body.
    func testShareCreatedAndUpdateSubscriptionsAreDistinct() {
        let me = "_abc123"
        let created = CloudKitSubscriptions.groceryShareCreatedSubscriptionID(for: me)
        let updated = CloudKitSubscriptions.groceryRecipientSubscriptionID(for: me)
        XCTAssertNotEqual(created, updated)
        // Both must map to the .groceryList stream in dispatch, which keys
        // off these prefixes.
        XCTAssertTrue(created.hasPrefix("grocery-list-shared-"))
        XCTAssertTrue(updated.hasPrefix("grocery-list-events-"))
    }
}

/// The in-app banner's copy, which is assembled locally rather than by
/// CloudKit and so is worth pinning separately from the push table.
final class IncomingShareTests: XCTestCase {

    func testHeadlineNamesTheOwner() {
        let share = IncomingShare(recordName: "r1", listName: "Weekend Shop", ownerName: "Dad")
        XCTAssertEqual(share.headline, "Dad shared a grocery list with you")
    }

    /// A friend who never set a profile name would otherwise render a
    /// headline starting with a space — " shared a grocery list with you".
    func testHeadlineFallsBackWhenOwnerNameIsBlank() {
        for blank in ["", "   ", "\n"] {
            let share = IncomingShare(recordName: "r1", listName: "Shop", ownerName: blank)
            XCTAssertEqual(share.headline, "A friend shared a grocery list with you")
        }
    }

    /// Identity is the cloud record name so a second share replaces the
    /// first banner rather than stacking, and re-announcing the same list
    /// is a no-op for the `.id()`-keyed overlay.
    func testIdentityIsTheShareRecordName() {
        let share = IncomingShare(recordName: "rec-42", listName: "Shop", ownerName: "Dad")
        XCTAssertEqual(share.id, "rec-42")
    }
}
