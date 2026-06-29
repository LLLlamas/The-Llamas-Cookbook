import Foundation

/// Researched grocery-domain reference data — aisle classification and
/// ingredient substitutions — held the same way `Conversions.swift` holds
/// the kitchen-equivalents tables. It serves two jobs: it *is* the heuristic
/// the on-device triage falls back to when Apple Intelligence is
/// unavailable, and it *grounds* the FoundationModels prompts (the aisle
/// vocabulary + example swaps keep the model's output consistent and
/// on-domain).
///
/// Sources: USU & University of Illinois Extension substitution guides and
/// King Arthur Baking (substitutions); standard US supermarket department
/// layouts (aisle taxonomy). Matching is word-aware: multi-word keywords match as a
/// substring, single-word keywords match a whole word token, and the lists
/// are tried longest-keyword-first so "garlic powder" beats "garlic" and
/// "ice cream" beats "cream".
enum GroceryKnowledge {

    // MARK: - Matching primitives

    /// Word tokens of `name`, each augmented with a naive singular form so
    /// plural ingredient names still match singular keywords ("tomatoes" →
    /// "tomato", "eggs" → "egg", "berries" → "berry"). Multi-word keywords
    /// match via substring (below), which already tolerates plurals.
    private static func tokens(of name: String) -> Set<String> {
        var set = Set<String>()
        for token in name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
            set.insert(token)
            if token.hasSuffix("ies"), token.count > 3 {
                set.insert(String(token.dropLast(3)) + "y")
            } else if token.hasSuffix("es"), token.count > 2 {
                set.insert(String(token.dropLast(2)))
            }
            if token.hasSuffix("s"), token.count > 1 {
                set.insert(String(token.dropLast(1)))
            }
        }
        return set
    }

    private static func matches(normalized: String, tokens: Set<String>, keyword: String) -> Bool {
        keyword.contains(" ") ? normalized.contains(keyword) : tokens.contains(keyword)
    }

    /// First value whose keyword matches `name`, trying longest keywords
    /// first so specific phrases win over generic words.
    private static func firstMatch<V>(_ name: String, in table: [(keyword: String, value: V)]) -> V? {
        let normalized = name.lowercased()
        let toks = tokens(of: name)
        for entry in table where matches(normalized: normalized, tokens: toks, keyword: entry.keyword) {
            return entry.value
        }
        return nil
    }

    // MARK: - Aisle classification

    /// Ingredient keyword → grocery aisle. Authored specific-first; also
    /// sorted longest-first at use so "garlic powder" (Spices) beats
    /// "garlic" (Produce). Aisles match `GroceryAisle.ordered`.
    static let aisleKeywords: [(keyword: String, value: String)] = sortedLongestFirst([
        // Spices & seasonings (placed first so they win over produce/dairy
        // look-alikes like "garlic", "black pepper", "ground ginger").
        ("salt", "Spices"), ("black pepper", "Spices"), ("peppercorn", "Spices"),
        ("garlic powder", "Spices"), ("onion powder", "Spices"), ("paprika", "Spices"),
        ("cumin", "Spices"), ("chili powder", "Spices"), ("cinnamon", "Spices"),
        ("oregano", "Spices"), ("thyme", "Spices"), ("rosemary", "Spices"),
        ("bay leaf", "Spices"), ("nutmeg", "Spices"), ("cayenne", "Spices"),
        ("turmeric", "Spices"), ("curry powder", "Spices"), ("ground ginger", "Spices"),
        ("italian seasoning", "Spices"), ("red pepper flakes", "Spices"),
        ("vanilla extract", "Spices"), ("seasoning", "Spices"), ("spice", "Spices"),

        // Produce
        ("lettuce", "Produce"), ("romaine", "Produce"), ("spinach", "Produce"),
        ("kale", "Produce"), ("arugula", "Produce"), ("cabbage", "Produce"),
        ("tomato", "Produce"), ("onion", "Produce"), ("green onion", "Produce"),
        ("scallion", "Produce"), ("shallot", "Produce"), ("garlic", "Produce"),
        ("potato", "Produce"), ("sweet potato", "Produce"), ("carrot", "Produce"),
        ("celery", "Produce"), ("cucumber", "Produce"), ("bell pepper", "Produce"),
        ("jalapeno", "Produce"), ("pepper", "Produce"), ("mushroom", "Produce"),
        ("broccoli", "Produce"), ("cauliflower", "Produce"), ("zucchini", "Produce"),
        ("squash", "Produce"), ("eggplant", "Produce"), ("green beans", "Produce"),
        ("avocado", "Produce"), ("apple", "Produce"), ("banana", "Produce"),
        ("orange", "Produce"), ("lemon", "Produce"), ("lime", "Produce"),
        ("strawberry", "Produce"), ("blueberry", "Produce"), ("raspberry", "Produce"),
        ("grape", "Produce"), ("melon", "Produce"), ("pineapple", "Produce"),
        ("mango", "Produce"), ("peach", "Produce"), ("pear", "Produce"),
        ("cilantro", "Produce"), ("parsley", "Produce"), ("mint", "Produce"),
        ("basil", "Produce"), ("ginger", "Produce"), ("herbs", "Produce"),

        // Meat & Seafood
        ("ground beef", "Meat & Seafood"), ("beef", "Meat & Seafood"),
        ("steak", "Meat & Seafood"), ("chicken", "Meat & Seafood"),
        ("pork", "Meat & Seafood"), ("bacon", "Meat & Seafood"),
        ("sausage", "Meat & Seafood"), ("ham", "Meat & Seafood"),
        ("turkey", "Meat & Seafood"), ("lamb", "Meat & Seafood"),
        ("salmon", "Meat & Seafood"), ("tuna", "Meat & Seafood"),
        ("shrimp", "Meat & Seafood"), ("crab", "Meat & Seafood"),
        ("cod", "Meat & Seafood"), ("tilapia", "Meat & Seafood"),
        ("fish", "Meat & Seafood"), ("seafood", "Meat & Seafood"),

        // Dairy & Eggs
        ("milk", "Dairy & Eggs"), ("egg", "Dairy & Eggs"),
        ("butter", "Dairy & Eggs"), ("cheese", "Dairy & Eggs"),
        ("cheddar", "Dairy & Eggs"), ("mozzarella", "Dairy & Eggs"),
        ("parmesan", "Dairy & Eggs"), ("heavy cream", "Dairy & Eggs"),
        ("sour cream", "Dairy & Eggs"), ("cream cheese", "Dairy & Eggs"),
        ("cream", "Dairy & Eggs"), ("yogurt", "Dairy & Eggs"),
        ("buttermilk", "Dairy & Eggs"), ("half and half", "Dairy & Eggs"),
        ("margarine", "Dairy & Eggs"),

        // Bakery
        ("bread", "Bakery"), ("baguette", "Bakery"), ("bun", "Bakery"),
        ("roll", "Bakery"), ("bagel", "Bakery"), ("tortilla", "Bakery"),
        ("pita", "Bakery"), ("croissant", "Bakery"), ("naan", "Bakery"),
        ("pie crust", "Bakery"),

        // Frozen
        ("frozen", "Frozen"), ("ice cream", "Frozen"), ("popsicle", "Frozen"),
        ("ice", "Frozen"),

        // Beverages
        ("juice", "Beverages"), ("soda", "Beverages"), ("cola", "Beverages"),
        ("coffee", "Beverages"), ("tea", "Beverages"), ("wine", "Beverages"),
        ("beer", "Beverages"), ("sparkling water", "Beverages"),
        ("lemonade", "Beverages"), ("seltzer", "Beverages"),

        // Baby (placed before the personal-care/health bands so specific
        // baby items win over generic "soap"/"lotion"/"wipes").
        ("diaper", "Baby"), ("pull-ups", "Baby"), ("pull ups", "Baby"),
        ("baby wipes", "Baby"), ("baby formula", "Baby"), ("formula", "Baby"),
        ("baby food", "Baby"), ("pacifier", "Baby"), ("baby lotion", "Baby"),
        ("baby shampoo", "Baby"), ("baby wash", "Baby"), ("diaper rash cream", "Baby"),
        ("desitin", "Baby"), ("pampers", "Baby"), ("huggies", "Baby"),
        ("baby bottle", "Baby"), ("teething", "Baby"),

        // Health & Pharmacy — OTC meds, first aid, vitamins, supplements.
        // Brand names placed alongside generics; longest-first matching keeps
        // "advil" / "tylenol" specific. (Active-ingredient + brand both
        // listed so users get the right aisle either way.)
        ("acetaminophen", "Health & Pharmacy"), ("tylenol", "Health & Pharmacy"),
        ("ibuprofen", "Health & Pharmacy"), ("advil", "Health & Pharmacy"),
        ("motrin", "Health & Pharmacy"), ("aspirin", "Health & Pharmacy"),
        ("aleve", "Health & Pharmacy"), ("naproxen", "Health & Pharmacy"),
        ("excedrin", "Health & Pharmacy"), ("pain reliever", "Health & Pharmacy"),
        ("benadryl", "Health & Pharmacy"), ("diphenhydramine", "Health & Pharmacy"),
        ("claritin", "Health & Pharmacy"), ("zyrtec", "Health & Pharmacy"),
        ("allegra", "Health & Pharmacy"), ("allergy", "Health & Pharmacy"),
        ("antihistamine", "Health & Pharmacy"), ("sudafed", "Health & Pharmacy"),
        ("mucinex", "Health & Pharmacy"), ("dayquil", "Health & Pharmacy"),
        ("nyquil", "Health & Pharmacy"), ("robitussin", "Health & Pharmacy"),
        ("cough syrup", "Health & Pharmacy"), ("cough drop", "Health & Pharmacy"),
        ("halls", "Health & Pharmacy"), ("ricola", "Health & Pharmacy"),
        ("bonine", "Health & Pharmacy"), ("dramamine", "Health & Pharmacy"),
        ("meclizine", "Health & Pharmacy"), ("motion sickness", "Health & Pharmacy"),
        ("pepto", "Health & Pharmacy"), ("tums", "Health & Pharmacy"),
        ("antacid", "Health & Pharmacy"), ("imodium", "Health & Pharmacy"),
        ("prilosec", "Health & Pharmacy"), ("omeprazole", "Health & Pharmacy"),
        ("pepcid", "Health & Pharmacy"), ("laxative", "Health & Pharmacy"),
        ("melatonin", "Health & Pharmacy"),
        ("band-aid", "Health & Pharmacy"), ("band aid", "Health & Pharmacy"),
        ("bandage", "Health & Pharmacy"), ("gauze", "Health & Pharmacy"),
        ("neosporin", "Health & Pharmacy"), ("hydrogen peroxide", "Health & Pharmacy"),
        ("rubbing alcohol", "Health & Pharmacy"), ("cotton ball", "Health & Pharmacy"),
        ("cotton swab", "Health & Pharmacy"), ("q-tip", "Health & Pharmacy"),
        ("q tip", "Health & Pharmacy"), ("thermometer", "Health & Pharmacy"),
        ("first aid", "Health & Pharmacy"), ("epsom salt", "Health & Pharmacy"),
        ("icy hot", "Health & Pharmacy"), ("cough", "Health & Pharmacy"),
        ("vitamin", "Health & Pharmacy"), ("multivitamin", "Health & Pharmacy"),
        ("supplement", "Health & Pharmacy"), ("probiotic", "Health & Pharmacy"),
        ("fish oil", "Health & Pharmacy"), ("omega-3", "Health & Pharmacy"),
        ("biotin", "Health & Pharmacy"), ("collagen", "Health & Pharmacy"),
        ("magnesium", "Health & Pharmacy"), ("zinc", "Health & Pharmacy"),
        ("medicine", "Health & Pharmacy"), ("ointment", "Health & Pharmacy"),

        // Personal Care — bath, hair, skin, oral, shave, hygiene. Brand
        // names (Cerave, Cetaphil, Dove…) listed so a bare brand routes
        // correctly. "Hair product" / "travel containers" appear on real
        // lists and are caught here.
        ("shampoo", "Personal Care"), ("conditioner", "Personal Care"),
        ("hair product", "Personal Care"), ("hair gel", "Personal Care"),
        ("hairspray", "Personal Care"), ("hair spray", "Personal Care"),
        ("dry shampoo", "Personal Care"), ("hair", "Personal Care"),
        ("body wash", "Personal Care"), ("bar soap", "Personal Care"),
        ("hand soap", "Personal Care"), ("soap", "Personal Care"),
        ("lotion", "Personal Care"), ("moisturizer", "Personal Care"),
        ("cerave", "Personal Care"), ("cetaphil", "Personal Care"),
        ("aveeno", "Personal Care"), ("dove", "Personal Care"),
        ("nivea", "Personal Care"), ("eucerin", "Personal Care"),
        ("vaseline", "Personal Care"), ("sunscreen", "Personal Care"),
        ("spf", "Personal Care"), ("face wash", "Personal Care"),
        ("toothpaste", "Personal Care"), ("toothbrush", "Personal Care"),
        ("mouthwash", "Personal Care"), ("listerine", "Personal Care"),
        ("dental floss", "Personal Care"), ("floss", "Personal Care"),
        ("crest", "Personal Care"), ("colgate", "Personal Care"),
        ("deodorant", "Personal Care"), ("antiperspirant", "Personal Care"),
        ("razor", "Personal Care"), ("shaving cream", "Personal Care"),
        ("shave gel", "Personal Care"), ("gillette", "Personal Care"),
        ("aftershave", "Personal Care"), ("chapstick", "Personal Care"),
        ("lip balm", "Personal Care"), ("cosmetics", "Personal Care"),
        ("makeup", "Personal Care"), ("mascara", "Personal Care"),
        ("foundation", "Personal Care"), ("nail polish", "Personal Care"),
        ("perfume", "Personal Care"), ("cologne", "Personal Care"),
        ("feminine", "Personal Care"), ("tampon", "Personal Care"),
        // Multi-word so bare "pad" can't false-positive "pad thai";
        // "feminine"/"tampon"/"panty liner" already cover the aisle.
        ("maxi pad", "Personal Care"), ("menstrual pad", "Personal Care"),
        ("panty liner", "Personal Care"), ("contact solution", "Personal Care"),
        ("travel container", "Personal Care"), ("travel size", "Personal Care"),
        ("face mask", "Personal Care"), ("hand sanitizer", "Personal Care"),
        ("hand cream", "Personal Care"),

        // Household
        ("paper towel", "Household"), ("toilet paper", "Household"),
        ("napkin", "Household"), ("foil", "Household"), ("plastic wrap", "Household"),
        ("parchment", "Household"), ("trash bag", "Household"), ("garbage bag", "Household"),
        ("dish soap", "Household"), ("dishwasher", "Household"), ("dish detergent", "Household"),
        ("laundry detergent", "Household"), ("detergent", "Household"),
        ("fabric softener", "Household"), ("dryer sheet", "Household"),
        ("bleach", "Household"), ("clorox", "Household"), ("tide", "Household"),
        ("lysol", "Household"), ("windex", "Household"), ("febreze", "Household"),
        ("swiffer", "Household"), ("all-purpose cleaner", "Household"),
        ("disinfectant", "Household"), ("cleaner", "Household"),
        ("dish sponge", "Household"), ("sponge", "Household"), ("scrubber", "Household"),
        ("air freshener", "Household"), ("light bulb", "Household"),
        ("lightbulb", "Household"), ("ziploc", "Household"), ("storage bag", "Household"),
        ("sandwich bag", "Household"), ("paper plate", "Household"),
        ("paper cup", "Household"), ("plastic cutlery", "Household"),
        ("candle", "Household"), ("matches", "Household"), ("lighter", "Household"),
        ("battery", "Household"), ("tissue", "Household"), ("kleenex", "Household"),
        ("wipes", "Household"),

        // Pet
        ("dog food", "Pet"), ("cat food", "Pet"), ("cat litter", "Pet"),
        ("litter", "Pet"), ("pet food", "Pet"), ("dog treat", "Pet"),
        ("cat treat", "Pet"), ("pet treat", "Pet"), ("dog", "Pet"),
        ("cat", "Pet"), ("kibble", "Pet"), ("puppy", "Pet"),
        ("kitten", "Pet"), ("pet", "Pet"),

        // Pantry & Dry Goods (generic catch-alls last within the priority
        // band so specific items above win)
        ("flour", "Pantry & Dry Goods"), ("sugar", "Pantry & Dry Goods"),
        ("rice", "Pantry & Dry Goods"), ("pasta", "Pantry & Dry Goods"),
        ("spaghetti", "Pantry & Dry Goods"), ("noodle", "Pantry & Dry Goods"),
        ("oats", "Pantry & Dry Goods"), ("cereal", "Pantry & Dry Goods"),
        ("beans", "Pantry & Dry Goods"), ("lentil", "Pantry & Dry Goods"),
        ("chickpea", "Pantry & Dry Goods"), ("canned", "Pantry & Dry Goods"),
        ("tomato sauce", "Pantry & Dry Goods"), ("tomato paste", "Pantry & Dry Goods"),
        ("broth", "Pantry & Dry Goods"), ("stock", "Pantry & Dry Goods"),
        ("olive oil", "Pantry & Dry Goods"), ("oil", "Pantry & Dry Goods"),
        ("vinegar", "Pantry & Dry Goods"), ("soy sauce", "Pantry & Dry Goods"),
        ("honey", "Pantry & Dry Goods"), ("syrup", "Pantry & Dry Goods"),
        ("peanut butter", "Pantry & Dry Goods"), ("jam", "Pantry & Dry Goods"),
        ("jelly", "Pantry & Dry Goods"), ("ketchup", "Pantry & Dry Goods"),
        ("mustard", "Pantry & Dry Goods"), ("mayo", "Pantry & Dry Goods"),
        ("salsa", "Pantry & Dry Goods"), ("sauce", "Pantry & Dry Goods"),
        ("cornstarch", "Pantry & Dry Goods"), ("baking soda", "Pantry & Dry Goods"),
        ("baking powder", "Pantry & Dry Goods"), ("yeast", "Pantry & Dry Goods"),
        ("breadcrumbs", "Pantry & Dry Goods"), ("cracker", "Pantry & Dry Goods"),
        ("chips", "Pantry & Dry Goods"), ("cookie", "Pantry & Dry Goods"),
        ("almond", "Pantry & Dry Goods"), ("walnut", "Pantry & Dry Goods"),
        ("raisin", "Pantry & Dry Goods"), ("coconut milk", "Pantry & Dry Goods"),
        ("cocoa", "Pantry & Dry Goods"), ("chocolate chips", "Pantry & Dry Goods"),
    ])

    /// Classify an ingredient name into a `GroceryAisle`; falls back to
    /// "Other" when nothing matches.
    static func aisle(for name: String) -> String {
        firstMatch(name, in: aisleKeywords) ?? GroceryAisle.fallback
    }

    // MARK: - Substitutions

    struct Substitution: Equatable {
        let replacement: String
        let note: String?
        init(_ replacement: String, _ note: String? = nil) {
            self.replacement = replacement
            self.note = note
        }
    }

    /// Researched 1:1(-ish) swaps keyed by canonical ingredient. Used by the
    /// "they don't have this" flow's heuristic fallback and to ground the AI
    /// substitution prompt. Quantities are written for the common recipe
    /// amount (usually 1 cup / 1 tsp / 1 large) and noted where the swap
    /// changes the result.
    static let substitutions: [(keyword: String, value: [Substitution])] = sortedLongestFirst([
        ("buttermilk", [
            Substitution("1 cup milk + 1 tbsp lemon juice or white vinegar", "Stir, rest 5 min until curdled"),
            Substitution("1 cup plain yogurt", "Thin with a splash of milk if needed"),
            Substitution("1 cup milk + 1¾ tsp cream of tartar", nil),
        ]),
        ("baking powder", [
            Substitution("¼ tsp baking soda + ½ tsp cream of tartar", "Per 1 tsp baking powder; mix fresh"),
        ]),
        ("baking soda", [
            Substitution("3 tsp baking powder", "Per 1 tsp soda; reduce other acids in the recipe"),
        ]),
        ("self-rising flour", [
            Substitution("1 cup all-purpose flour + 1½ tsp baking powder + ¼ tsp salt", nil),
        ]),
        ("self rising flour", [
            Substitution("1 cup all-purpose flour + 1½ tsp baking powder + ¼ tsp salt", nil),
        ]),
        ("cornstarch", [
            Substitution("2 tbsp all-purpose flour", "Per 1 tbsp cornstarch, for thickening"),
            Substitution("1 tbsp arrowroot powder", nil),
        ]),
        ("cream of tartar", [
            Substitution("Equal lemon juice or white vinegar", "When used to stabilize/acidify"),
        ]),
        ("brown sugar", [
            Substitution("1 cup white sugar + 1 tbsp molasses", "Use 2 tbsp molasses for dark brown"),
            Substitution("1 cup white sugar", "Loses a little moisture + caramel note"),
        ]),
        ("powdered sugar", [
            Substitution("1 cup white sugar blended with 1 tbsp cornstarch", "Blend until fine"),
        ]),
        ("heavy cream", [
            Substitution("¾ cup milk + ⅓ cup melted butter", "For cooking/baking, not whipping"),
            Substitution("1 cup evaporated milk", "For richness, won't whip"),
        ]),
        ("sour cream", [
            Substitution("1 cup plain Greek yogurt", "Closest swap, 1:1"),
            Substitution("1 cup crème fraîche", nil),
        ]),
        ("whole milk", [
            Substitution("½ cup evaporated milk + ½ cup water", nil),
            Substitution("1 cup any plain plant milk", "Oat/soy are closest in baking"),
        ]),
        ("milk", [
            Substitution("1 cup water + 1 tbsp melted butter", "For baking"),
            Substitution("1 cup any plain plant milk", nil),
        ]),
        ("butter", [
            Substitution("1 cup margarine", "1:1"),
            Substitution("¾ cup oil", "For some baked goods; not for creaming"),
        ]),
        ("egg", [
            Substitution("¼ cup unsweetened applesauce", "Per egg, for moist baked goods"),
            Substitution("1 mashed ripe banana", "Adds banana flavor"),
            Substitution("1 tbsp ground flaxseed + 3 tbsp water", "Rest 5 min to gel"),
            Substitution("3 tbsp aquafaba (chickpea liquid)", "Good for binding/whipping"),
        ]),
        ("honey", [
            Substitution("1¼ cup sugar + ¼ cup water", "Per 1 cup honey"),
            Substitution("1 cup maple syrup", nil),
        ]),
        ("maple syrup", [
            Substitution("1 cup honey", nil),
            Substitution("1 cup sugar + ¼ cup water", nil),
        ]),
        ("lemon juice", [
            Substitution("Equal lime juice", nil),
            Substitution("½ as much white vinegar", "For acidity, not flavor"),
        ]),
        ("garlic", [
            Substitution("⅛ tsp garlic powder per clove", nil),
        ]),
        ("fresh herbs", [
            Substitution("⅓ as much dried herb", "1 tbsp fresh ≈ 1 tsp dried"),
        ]),
        ("breadcrumbs", [
            Substitution("Crushed crackers or cornflakes", nil),
            Substitution("Rolled oats (pulsed)", nil),
            Substitution("Panko", nil),
        ]),
        ("white wine", [
            Substitution("Equal chicken/vegetable broth + 1 tsp vinegar", nil),
            Substitution("White grape juice + 1 tsp vinegar", nil),
        ]),
        ("red wine", [
            Substitution("Equal beef broth + 1 tsp vinegar", nil),
            Substitution("Cranberry or grape juice + 1 tsp vinegar", nil),
        ]),
        ("mayonnaise", [
            Substitution("Plain Greek yogurt", "Tangier, lighter"),
        ]),
        ("yogurt", [
            Substitution("Sour cream", "1:1"),
            Substitution("Buttermilk", "Thinner; reduce other liquid"),
        ]),
        ("vegetable oil", [
            Substitution("Equal melted butter or other neutral oil", nil),
            Substitution("Unsweetened applesauce", "Replace up to half, for baking"),
        ]),
    ])

    /// Substitutes for an ingredient name (longest canonical key first).
    /// Returns [] when we have no researched swap — the AI handles the
    /// long tail, and the UI falls back to "search the web".
    static func substitutes(for name: String) -> [Substitution] {
        let hit = firstMatch(name, in: substitutions) ?? []
        return hit
    }

    // MARK: - AI grounding

    /// Compact aisle vocabulary handed to the FoundationModels triage prompt
    /// so the model labels items with our exact aisle names.
    static let aisleVocabulary = GroceryAisle.ordered.joined(separator: ", ")

    // MARK: - Helpers

    /// Stable longest-keyword-first ordering so specific phrases win.
    private static func sortedLongestFirst<V>(_ table: [(keyword: String, value: V)]) -> [(keyword: String, value: V)] {
        table.sorted { $0.keyword.count > $1.keyword.count }
    }
}
