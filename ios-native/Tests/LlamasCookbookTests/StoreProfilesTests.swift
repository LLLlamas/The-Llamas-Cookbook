import XCTest
@testable import LlamasCookbookNative

final class StoreProfilesTests: XCTestCase {

    /// Fresh, isolated UserDefaults per test so persisted profiles never
    /// leak between cases (or into the real app domain on a dev device).
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "StoreProfilesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - GroceryAisle.resolvedOrder

    func testResolvedOrderKeepsFullPermutation() {
        let reversed = Array(GroceryAisle.ordered.reversed())
        XCTAssertEqual(GroceryAisle.resolvedOrder(reversed), reversed)
    }

    func testResolvedOrderDropsUnknownsAndDuplicates() {
        let stored = ["Produce", "Discontinued Aisle", "produce", "Frozen"]
        let resolved = GroceryAisle.resolvedOrder(stored)
        XCTAssertEqual(Array(resolved.prefix(2)), ["Produce", "Frozen"])
        XCTAssertEqual(resolved.count, GroceryAisle.ordered.count)
        XCTAssertEqual(Set(resolved), Set(GroceryAisle.ordered))
    }

    func testResolvedOrderAppendsMissingAislesCanonically() {
        let partial = ["Frozen", "Produce"]
        let resolved = GroceryAisle.resolvedOrder(partial)
        XCTAssertEqual(Array(resolved.prefix(2)), ["Frozen", "Produce"])
        let appended = Array(resolved.dropFirst(2))
        let expected = GroceryAisle.ordered.filter { $0 != "Frozen" && $0 != "Produce" }
        XCTAssertEqual(appended, expected)
    }

    // MARK: - GroceryAisle.group(order:)

    func testGroupNilOrderMatchesCanonical() {
        let items = ["milk": "Dairy & Eggs", "apple": "Produce", "chips": "Snacks"]
            .map { (name: $0.key, aisle: $0.value) }
        let canonical = GroceryAisle.group(items) { $0.aisle }
        let explicit = GroceryAisle.group(items, order: nil) { $0.aisle }
        XCTAssertEqual(canonical.map(\.aisle), explicit.map(\.aisle))
    }

    func testGroupRespectsCustomOrder() {
        let items = [
            (name: "milk", aisle: "Dairy & Eggs"),
            (name: "apple", aisle: "Produce"),
            (name: "chips", aisle: "Snacks"),
        ]
        let custom = ["Snacks", "Dairy & Eggs", "Produce"]
        let sections = GroceryAisle.group(items, order: custom) { $0.aisle }
        XCTAssertEqual(sections.map(\.aisle), ["Snacks", "Dairy & Eggs", "Produce"])
    }

    func testGroupCustomOrderStillBucketsAislesMissingFromIt() {
        // An old profile that predates an aisle still shows items from it —
        // healed to the end rather than silently dropped.
        let items = [
            (name: "shampoo", aisle: "Personal Care"),
            (name: "apple", aisle: "Produce"),
        ]
        let sections = GroceryAisle.group(items, order: ["Produce"]) { $0.aisle }
        XCTAssertEqual(sections.map(\.aisle), ["Produce", "Personal Care"])
    }

    // MARK: - Store templates

    func testTemplatesAreCompletePermutations() {
        for template in StoreTemplate.all {
            XCTAssertEqual(
                template.order.count, GroceryAisle.ordered.count,
                "\(template.name) must list every aisle exactly once"
            )
            XCTAssertEqual(
                Set(template.order), Set(GroceryAisle.ordered),
                "\(template.name) must be a permutation of GroceryAisle.ordered"
            )
        }
    }

    // MARK: - StoreProfileStore

    func testAddPersistsAndRoundTrips() {
        let store = StoreProfileStore(defaults: defaults)
        let added = store.add(named: "Kroger", aisleOrder: StoreTemplate.all[0].order)
        XCTAssertEqual(store.profiles.count, 1)

        let reloaded = StoreProfileStore(defaults: defaults)
        XCTAssertEqual(reloaded.profiles, [added])
    }

    func testAssignmentRoundTripsAndClears() {
        let store = StoreProfileStore(defaults: defaults)
        let kroger = store.add(named: "Kroger")
        let listID = UUID()

        store.assign(kroger.id, toList: listID)
        XCTAssertEqual(store.profile(forList: listID)?.id, kroger.id)
        XCTAssertEqual(
            StoreProfileStore(defaults: defaults).assignedStoreID(forList: listID),
            kroger.id
        )

        store.assign(nil, toList: listID)
        XCTAssertNil(store.profile(forList: listID))
        XCTAssertNil(store.aisleOrder(forList: listID))
    }

    func testDeleteScrubsAssignments() {
        let store = StoreProfileStore(defaults: defaults)
        let kroger = store.add(named: "Kroger")
        let listID = UUID()
        store.assign(kroger.id, toList: listID)

        store.delete(kroger.id)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.profile(forList: listID))
        // And the scrub persisted — a fresh load doesn't resurrect it.
        XCTAssertNil(StoreProfileStore(defaults: defaults).assignedStoreID(forList: listID))
    }

    func testAisleOrderForListHealsStaleProfile() {
        let store = StoreProfileStore(defaults: defaults)
        let profile = store.add(named: "Corner shop", aisleOrder: ["Frozen", "Produce"])
        let listID = UUID()
        store.assign(profile.id, toList: listID)

        let order = store.aisleOrder(forList: listID)
        XCTAssertEqual(order?.count, GroceryAisle.ordered.count)
        XCTAssertEqual(order.map { Array($0.prefix(2)) }, ["Frozen", "Produce"])
    }
}
