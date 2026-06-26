import XCTest
@testable import LlamasCookbookNative

final class GroceryKnowledgeTests: XCTestCase {

    // MARK: - Aisle classification

    func testAisleProduce() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Tomatoes"), "Produce")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "bell pepper"), "Produce")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Fresh garlic"), "Produce")
    }

    func testAisleSpecificityBeatsGeneric() {
        // Longer / more specific keywords win over generic look-alikes.
        XCTAssertEqual(GroceryKnowledge.aisle(for: "garlic powder"), "Spices")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "black pepper"), "Spices")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "ice cream"), "Frozen")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "peanut butter"), "Pantry & Dry Goods")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "sour cream"), "Dairy & Eggs")
    }

    func testAisleDairyMeatBakery() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Whole milk"), "Dairy & Eggs")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "2 eggs"), "Dairy & Eggs")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Chicken breast"), "Meat & Seafood")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Sourdough bread"), "Bakery")
    }

    func testAisleUnknownFallsBackToOther() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Mystery widget"), "Other")
        XCTAssertEqual(GroceryKnowledge.aisle(for: ""), "Other")
    }

    func testAisleResultsAreAlwaysCanonical() {
        for name in ["tomato", "garlic powder", "chicken", "milk", "frozen peas", "ketchup", "qwerty"] {
            XCTAssertTrue(GroceryAisle.ordered.contains(GroceryKnowledge.aisle(for: name)),
                          "\(name) classified to a non-canonical aisle")
        }
    }

    // MARK: - Substitutions

    func testSubstitutionsKnownIngredients() {
        XCTAssertFalse(GroceryKnowledge.substitutes(for: "buttermilk").isEmpty)
        XCTAssertFalse(GroceryKnowledge.substitutes(for: "baking powder").isEmpty)
        // Plurals / qualifiers still resolve via substring.
        XCTAssertFalse(GroceryKnowledge.substitutes(for: "white eggs").isEmpty)
    }

    func testSubstitutionsUnknownIsEmpty() {
        XCTAssertTrue(GroceryKnowledge.substitutes(for: "dragon fruit").isEmpty)
    }

    func testSubstitutionSpecificityButtermilkNotMilk() {
        // "buttermilk" must resolve to the buttermilk swaps, not the generic
        // "milk" ones (longest keyword first).
        let subs = GroceryKnowledge.substitutes(for: "buttermilk")
        XCTAssertTrue(subs.contains { $0.replacement.lowercased().contains("lemon juice or white vinegar") })
    }

    // MARK: - Heuristic triage

    func testHeuristicTriageAlignsIndices() {
        let names = ["Tomatoes", "Salt", "Chicken thighs"]
        let result = IngredientAssistant.heuristicTriage(names: names)
        XCTAssertEqual(result.aisleByIndex[0], "Produce")
        XCTAssertEqual(result.aisleByIndex[1], "Spices")
        XCTAssertEqual(result.aisleByIndex[2], "Meat & Seafood")
    }

    func testHeuristicTriageEmpty() {
        let result = IngredientAssistant.heuristicTriage(names: [])
        XCTAssertTrue(result.aisleByIndex.isEmpty)
    }
}
