import XCTest
import SwiftData
@testable import LlamasCookbook

/// Locks the `GroceryList` shopping-progress predicates that the Lists row
/// summary, the Lists tab badge, and the "all set" done indicator all read
/// as their single source of truth. The JS mirror is covered by
/// `cloudflare-pages/test/grocery.test.js`; this is the Swift side.
@MainActor
final class GroceryListTests: XCTestCase {

    // No ModelContainer here: the host app already builds the full-schema
    // container at launch, and SwiftData traps on a second container over
    // the same @Model classes in-process. These predicates are pure
    // computed properties, so un-inserted instances suffice.
    private func add(
        to list: GroceryList,
        _ name: String,
        checked: Bool,
        order: Int
    ) {
        list.items.append(GroceryItem(name: name, isChecked: checked, order: order))
    }

    func testEmptyListIsNeitherAllSetNorOpen() {
        let list = GroceryList(name: "Empty")
        XCTAssertEqual(list.toBuyCount, 0)
        XCTAssertFalse(list.isAllSet, "An empty list must NOT read as all set")
        XCTAssertFalse(list.isOpen)
    }

    func testListWithItemsToBuyIsOpen() {
        let list = GroceryList(name: "Shop")
        add(to: list, "milk", checked: false, order: 0) // to buy
        add(to: list, "eggs", checked: true, order: 1)  // in cart
        add(to: list, "salt", checked: false, order: 2) // to buy
        XCTAssertEqual(list.toBuyCount, 2, "Only unchecked items count")
        XCTAssertFalse(list.isAllSet)
        XCTAssertTrue(list.isOpen)
    }

    func testFullyShoppedListIsAllSet() {
        let list = GroceryList(name: "Done")
        add(to: list, "milk", checked: true, order: 0)
        add(to: list, "salt", checked: true, order: 1)
        XCTAssertEqual(list.toBuyCount, 0)
        XCTAssertTrue(list.isAllSet)
        XCTAssertFalse(list.isOpen)
    }

    func testSharedAvailabilityNoteEncoding() {
        XCTAssertNil(CloudGroceryListService.encodeAvailabilityNote(
            outOfStock: false,
            substitution: nil
        ))
        XCTAssertEqual(CloudGroceryListService.encodeAvailabilityNote(
            outOfStock: true,
            substitution: nil
        ), "out")
        XCTAssertEqual(CloudGroceryListService.encodeAvailabilityNote(
            outOfStock: true,
            substitution: "  almond milk  "
        ), "sub:almond milk")

        let out = CloudGroceryListService.decodeAvailabilityNote("out")
        XCTAssertTrue(out.outOfStock)
        XCTAssertNil(out.substitution)

        let swap = CloudGroceryListService.decodeAvailabilityNote("sub:margarine")
        XCTAssertTrue(swap.outOfStock)
        XCTAssertEqual(swap.substitution, "margarine")

        let legacy = CloudGroceryListService.decodeAvailabilityNote("brown eggs")
        XCTAssertTrue(legacy.outOfStock)
        XCTAssertEqual(legacy.substitution, "brown eggs")
    }
}
