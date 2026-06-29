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
        // Longer / more specific keywords (and the specific-band author order)
        // win over generic look-alikes.
        XCTAssertEqual(GroceryKnowledge.aisle(for: "garlic powder"), "Spices")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "black pepper"), "Spices")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "ice cream"), "Frozen")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "sour cream"), "Dairy & Eggs")
        // "baby corn" (International) beats "corn" (Produce) by length.
        XCTAssertEqual(GroceryKnowledge.aisle(for: "baby corn"), "International")
        // "corn starch" (Baking) beats "corn" (Produce).
        XCTAssertEqual(GroceryKnowledge.aisle(for: "corn starch"), "Baking")
        // "baking soda" (Baking) beats "soda" (Beverages).
        XCTAssertEqual(GroceryKnowledge.aisle(for: "baking soda"), "Baking")
        // "rice vinegar" (International) beats bare "rice" (Pasta, Rice & Grains).
        XCTAssertEqual(GroceryKnowledge.aisle(for: "rice vinegar"), "International")
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
                     "tylenol", "shampoo", "trash bags", "diapers", "dog food",
                     "spaghetti", "canned beans", "flour", "tortilla chips", "soy sauce",
                     "sliced turkey", "oatmeal", "coconut milk"] {
            XCTAssertTrue(GroceryAisle.ordered.contains(GroceryKnowledge.aisle(for: name)),
                          "\(name) classified to a non-canonical aisle")
        }
    }

    // MARK: - New center-store departments

    func testAisleBreakfastAndCereal() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "Cereal"), "Breakfast & Cereal")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "oatmeal"), "Breakfast & Cereal")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "granola"), "Breakfast & Cereal")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "pancake mix"), "Breakfast & Cereal")
        // Maple syrup is shelved near pancake mix, not in Condiments.
        XCTAssertEqual(GroceryKnowledge.aisle(for: "maple syrup"), "Breakfast & Cereal")
    }

    func testAisleCannedAndJarred() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "canned beans"), "Canned & Jarred")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "black beans"), "Canned & Jarred")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "tomato paste"), "Canned & Jarred")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "chicken broth"), "Canned & Jarred")
        // Plain canned tomato sauce → Canned & Jarred…
        XCTAssertEqual(GroceryKnowledge.aisle(for: "tomato sauce"), "Canned & Jarred")
    }

    func testAisleCondimentsAndSauces() {
        // …but seasoned pasta sauce / marinara → Condiments & Sauces.
        XCTAssertEqual(GroceryKnowledge.aisle(for: "pasta sauce"), "Condiments & Sauces")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "marinara"), "Condiments & Sauces")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "ketchup"), "Condiments & Sauces")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "mustard"), "Condiments & Sauces")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "peanut butter"), "Condiments & Sauces")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "honey"), "Condiments & Sauces")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "soy sauce"), "Condiments & Sauces")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "sriracha"), "Condiments & Sauces")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "crouton"), "Condiments & Sauces")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "croutons"), "Condiments & Sauces")
        // Grape jelly: explicit multi-word beats the equal-length "grape" → Produce.
        XCTAssertEqual(GroceryKnowledge.aisle(for: "grape jelly"), "Condiments & Sauces")
    }

    func testAislePastaRiceAndGrains() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "pasta"), "Pasta, Rice & Grains")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "spaghetti"), "Pasta, Rice & Grains")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "rice"), "Pasta, Rice & Grains")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "quinoa"), "Pasta, Rice & Grains")
    }

    func testAisleBaking() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "flour"), "Baking")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "chocolate chips"), "Baking")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "vanilla extract"), "Baking")
        // Bare baking nuts/raisins route to Baking (predominant recipe use).
        XCTAssertEqual(GroceryKnowledge.aisle(for: "almonds"), "Baking")
        // Canned evaporated/condensed milk are Baking, not Dairy.
        XCTAssertEqual(GroceryKnowledge.aisle(for: "evaporated milk"), "Baking")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "condensed milk"), "Baking")
    }

    func testAisleSnacks() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "chips"), "Snacks")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "tortilla chips"), "Snacks")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "graham crackers"), "Snacks")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "trail mix"), "Snacks")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "mixed nuts"), "Snacks")
    }

    func testAisleInternational() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "coconut milk"), "International")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "ghee"), "International")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "sushi rice"), "International")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "curry paste"), "International")
    }

    func testAisleSpecialtyDietDepth() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "gluten free bread"), "Bakery")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "gluten free pasta"), "Pasta, Rice & Grains")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "vegan cheese"), "Dairy & Eggs")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "plant based chicken nuggets"), "Frozen")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "beyond meat"), "Meat & Seafood")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "seitan"), "Dairy & Eggs")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "nutritional yeast"), "Baking")
    }

    func testAisleInternationalDepth() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "lee kum kee oyster sauce"), "International")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "chinkiang vinegar"), "International")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "tahini"), "International")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "harissa"), "International")
    }

    func testAisleHealthSupplementDepth() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "extra strength tylenol"), "Health & Pharmacy")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "electrolyte powder"), "Health & Pharmacy")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "hydrocortisone cream"), "Health & Pharmacy")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "coq10"), "Health & Pharmacy")
    }

    func testAisleBabyPetDepth() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "stage 1 formula"), "Baby")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "baby food pouch"), "Baby")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "size 3 diapers"), "Baby")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "dog dental chews"), "Pet")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "reptile food"), "Pet")
    }

    func testAisleDeli() {
        XCTAssertEqual(GroceryKnowledge.aisle(for: "sliced turkey"), "Deli")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "hummus"), "Deli")
    }

    func testAisleTofuIsDairy() {
        // Tofu's canonical refrigerated home is Dairy & Eggs.
        XCTAssertEqual(GroceryKnowledge.aisle(for: "tofu"), "Dairy & Eggs")
    }

    func testAislePantryRemainsForGenericShelfStaple() {
        // Plain olive oil stays the backward-compat Pantry catch-all.
        XCTAssertEqual(GroceryKnowledge.aisle(for: "olive oil"), "Pantry & Dry Goods")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "breadcrumbs"), "Pantry & Dry Goods")
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
        XCTAssertEqual(GroceryKnowledge.aisle(for: "vitamin D"), "Health & Pharmacy")
        // First-aid: use the space form, not the hyphenated brand spelling
        // (the tokenizer splits "band-aid" → "band" + "aid").
        XCTAssertEqual(GroceryKnowledge.aisle(for: "band aid"), "Health & Pharmacy")
        XCTAssertEqual(GroceryKnowledge.aisle(for: "bandage"), "Health & Pharmacy")
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
        // Bare "soap" (as a bar) is personal care…
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

    // MARK: - Taxonomy shape

    func testAisleTaxonomyHasFullStoreWalk() {
        // The approved 22-department store-walk, Produce first → Other last.
        XCTAssertEqual(GroceryAisle.ordered.count, 22)
        XCTAssertEqual(GroceryAisle.ordered.first, "Produce")
        XCTAssertEqual(GroceryAisle.ordered.last, "Other")
        for aisle in ["Deli", "Breakfast & Cereal", "Canned & Jarred", "Condiments & Sauces",
                      "Pasta, Rice & Grains", "Baking", "Snacks", "International",
                      "Pantry & Dry Goods"] {
            XCTAssertTrue(GroceryAisle.ordered.contains(aisle), "missing \(aisle)")
        }
    }

    func testAisleKeywordTableIsCanonicalAndUnique() {
        var seen = Set<String>()
        for entry in GroceryKnowledge.aisleKeywords {
            XCTAssertTrue(GroceryAisle.ordered.contains(entry.value), "\(entry.keyword) uses non-canonical aisle \(entry.value)")
            XCTAssertTrue(seen.insert(entry.keyword).inserted, "duplicate aisle keyword \(entry.keyword)")
        }
    }
}
