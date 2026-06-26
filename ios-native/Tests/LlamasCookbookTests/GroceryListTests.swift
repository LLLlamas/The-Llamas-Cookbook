import XCTest
import SwiftData
@testable import LlamasCookbookNative

/// Locks the `GroceryList` shopping-progress predicates that the Lists row
/// summary, the Lists tab badge, and the "all set" done indicator all read
/// as their single source of truth. The JS mirror is covered by
/// `cloudflare-pages/test/grocery.test.js`; this is the Swift side.
@MainActor
final class GroceryListTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: GroceryList.self, GroceryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return container.mainContext
    }

    private func add(
        _ ctx: ModelContext,
        to list: GroceryList,
        _ name: String,
        needed: Bool,
        checked: Bool,
        order: Int
    ) {
        let item = GroceryItem(name: name, needed: needed, isChecked: checked, order: order)
        ctx.insert(item)
        item.list = list
    }

    func testEmptyListIsNeitherAllSetNorOpen() throws {
        let ctx = try makeContext()
        let list = GroceryList(name: "Empty")
        ctx.insert(list)
        XCTAssertEqual(list.toBuyCount, 0)
        XCTAssertFalse(list.isAllSet, "An empty list must NOT read as all set")
        XCTAssertFalse(list.isOpen)
    }

    func testListWithItemsToBuyIsOpen() throws {
        let ctx = try makeContext()
        let list = GroceryList(name: "Shop")
        ctx.insert(list)
        add(ctx, to: list, "milk", needed: true, checked: false, order: 0)  // to buy
        add(ctx, to: list, "eggs", needed: true, checked: true, order: 1)   // in cart
        add(ctx, to: list, "salt", needed: false, checked: false, order: 2) // have
        XCTAssertEqual(list.toBuyCount, 1, "Only the unchecked, needed item counts")
        XCTAssertFalse(list.isAllSet)
        XCTAssertTrue(list.isOpen)
    }

    func testFullyShoppedListIsAllSet() throws {
        let ctx = try makeContext()
        let list = GroceryList(name: "Done")
        ctx.insert(list)
        add(ctx, to: list, "milk", needed: true, checked: true, order: 0)
        add(ctx, to: list, "salt", needed: false, checked: false, order: 1)
        XCTAssertEqual(list.toBuyCount, 0)
        XCTAssertTrue(list.isAllSet)
        XCTAssertFalse(list.isOpen)
    }
}
