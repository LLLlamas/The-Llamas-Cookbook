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
        for name in ["tomato", "garlic powder", "chicken", "milk", "frozen peas", "ketchup", "qwerty",
                     "tylenol", "shampoo", "trash bags", "diapers", "dog food"] {
            XCTAssertTrue(GroceryAisle.ordered.contains(GroceryKnowledge.aisle(for: name)),
                          "\(name) classified to a non-canonical aisle")
        }
    }

    // MARK: - Non-food domains (drugstore / household / etc.)

    func testAisleHealthAndPharmacy() {
        // Active ingredients + brand names both route to the pharmacy aisle.
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Tylenol"), "Health & Pharmacy")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "acetaminophen"), "Health & Pharmacy")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Advil"), "Health & Pharmacy")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "ibuprofen"), "Health & Pharmacy")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Benadryl"), "Health & Pharmacy")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Bonine"), "Health & Pharmacy")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Band-aids"), "Health & Pharmacy")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "vitamin D"), "Health & Pharmacy")
    }

    func testAislePersonalCare() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Shampoo"), "Personal Care")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Toothpaste"), "Personal Care")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Deodorant"), "Personal Care")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Cerave"), "Personal Care")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Cetaphil"), "Personal Care")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "razors"), "Personal Care")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Hair Product"), "Personal Care")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Travel Containers"), "Personal Care")
        // Bare "soap" is personal care…
        XCTAssertEqual(GroceryKnowledge.aisle(for: "bar soap"), "Personal Care")
    }

    func testAisleHousehold() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Paper towels"), "Household")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Trash bags"), "Household")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Laundry detergent"), "Household")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Tide"), "Household")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Clorox"), "Household")
        // …but "dish soap" is a household cleaner, not personal care
        // (longest-keyword-first must win here).
        XCTAssertEqual(GroceryKnowledge.aisle(for: "dish soap"), "Household")
    }

    func testAisleBaby() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Diapers"), "Baby")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Baby formula"), "Baby")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Baby wipes"), "Baby")
    }

    func testAislePet() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Dog food"), "Pet")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Cat litter"), "Pet")
    }

    func testHeuristicTriageRoutesNonFoodDomains() {
        let names = ["Tylenol", "Shampoo", "Paper towels", "Diapers", "Dog food"]
        let result = IngredientAssistant.heuristicTriage(names: names)
        XCTAssertEqual(result.aisleByIndex[0], "Health & Pharmacy")
        XCTAssertEqual(result.aisleByIndex[1], "Personal Care")
        XCTAssertEqual(result.aisleByIndex[2], "Household")
        XCTAssertEqual(result.aisleByIndex[3], "Baby")
        XCTAssertEqual(result.aisleByIndex[4], "Pet")
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
