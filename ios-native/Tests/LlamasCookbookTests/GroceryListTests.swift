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

    // MARK: - Share-slot reseed diff

    // `upsertShare` rewrites only the slots these identify. Everything else
    // keeps the server's live check/note state, so an owner's debounced
    // structure push can't un-check what a shopper just ticked.

    private func meta(_ id: String, _ name: String) -> SharedGroceryItemMeta {
        SharedGroceryItemMeta(id: id, name: name, quantity: nil, unit: nil, aisle: nil)
    }

    func testFirstShareReseedsEverySlot() {
        let incoming = [meta("a", "milk"), meta("b", "eggs")]
        XCTAssertEqual(
            CloudGroceryListService.slotsNeedingReseed(existing: [], incoming: incoming),
            [0, 1],
            "A brand-new record has no live state to preserve"
        )
    }

    func testUnchangedStructureReseedsNothing() {
        let items = [meta("a", "milk"), meta("b", "eggs")]
        XCTAssertTrue(
            CloudGroceryListService.slotsNeedingReseed(existing: items, incoming: items).isEmpty,
            "Re-sharing an unchanged list must not touch a single live slot"
        )
    }

    func testAppendingAnItemReseedsOnlyTheNewSlot() {
        let existing = [meta("a", "milk"), meta("b", "eggs")]
        let incoming = existing + [meta("c", "bread")]
        XCTAssertEqual(
            CloudGroceryListService.slotsNeedingReseed(existing: existing, incoming: incoming),
            [2],
            "Adding a row must leave the shopper's existing check-offs alone"
        )
    }

    func testDeletingAMiddleItemReseedsTheShiftedSlots() {
        let existing = [meta("a", "milk"), meta("b", "eggs"), meta("c", "bread")]
        let incoming = [meta("a", "milk"), meta("c", "bread")]
        XCTAssertEqual(
            CloudGroceryListService.slotsNeedingReseed(existing: existing, incoming: incoming),
            [1],
            "Only slots that changed occupant reseed; slot 0 still holds milk"
        )
    }

    func testRenamingInPlaceKeepsTheSlot() {
        let existing = [meta("a", "milk")]
        let incoming = [meta("a", "whole milk")]
        XCTAssertTrue(
            CloudGroceryListService.slotsNeedingReseed(existing: existing, incoming: incoming).isEmpty,
            "Identity is the item id, so a rename must not reset its check state"
        )
    }

    func testReseedNeverExceedsTheSlotRange() {
        let many = (0..<60).map { meta("id-\($0)", "item \($0)") }
        let slots = CloudGroceryListService.slotsNeedingReseed(existing: [], incoming: many)
        XCTAssertEqual(slots.count, CloudGroceryListService.maxSharedItems)
        XCTAssertNil(
            slots.first { $0 >= CloudGroceryListService.maxSharedItems },
            "Rows past the cap have no check<N>/note<N> field to write"
        )
    }
}
