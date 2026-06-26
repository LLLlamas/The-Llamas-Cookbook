import Foundation

/// Curated common-substitution suggestions for grocery items — the
/// "research" behind the shopper's "?" helper. Entirely offline and
/// hand-verified (no network, no quota, no AI guesswork), so a suggestion
/// is only ever shown when we're confident it's a real, sensible swap.
/// Unknown items return no suggestion and the UI invites a free-text note
/// instead — we never fabricate a swap.
///
/// Keys live in SINGULAR base form and are matched via `GroceryKeyword`
/// (tolerant of plurals + surrounding quantity/qualifier words), so
/// "2 cups buttermilk" and "Buttermilk" both resolve to the same entry.
enum GrocerySwaps {
    struct Suggestion: Identifiable, Hashable {
        let id = UUID()
        /// The swap itself — concise, ready to read at the shelf.
        let swap: String
        /// Optional ratio/context note ("per cup", "in baking").
        let note: String?

        init(_ swap: String, _ note: String? = nil) {
            self.swap = swap
            self.note = note
        }
    }

    /// Curated table. Each ingredient maps to one or more swaps, best first.
    /// Add entries freely — keep keys singular and lowercase.
    static let table: [String: [Suggestion]] = [
        // Dairy & eggs
        "buttermilk": [Suggestion("1 cup milk + 1 tbsp lemon juice or vinegar", "let it sit 5 min")],
        "butter": [Suggestion("equal amount margarine"), Suggestion("¾ the amount in neutral oil", "for baking")],
        "egg": [Suggestion("¼ cup unsweetened applesauce", "per egg, in baking"), Suggestion("1 tbsp ground flax + 3 tbsp water", "per egg")],
        "milk": [Suggestion("equal oat, soy, or almond milk"), Suggestion("½ cup evaporated milk + ½ cup water")],
        "heavy cream": [Suggestion("¾ cup milk + ⅓ cup melted butter", "per cup")],
        "half and half": [Suggestion("⅞ cup milk + 1 tbsp melted butter", "per cup")],
        "sour cream": [Suggestion("plain Greek yogurt, 1:1")],
        "yogurt": [Suggestion("sour cream, 1:1")],
        "cream cheese": [Suggestion("equal mascarpone, or thick Greek yogurt")],
        "mascarpone": [Suggestion("8 oz cream cheese + ¼ cup cream + 2 tbsp butter")],
        "ricotta": [Suggestion("blended cottage cheese, 1:1")],
        "parmesan": [Suggestion("equal Grana Padano or Pecorino Romano")],
        "feta": [Suggestion("equal crumbled goat cheese")],

        // Bakery & pantry
        "all purpose flour": [Suggestion("equal bread flour"), Suggestion("1 cup minus 2 tbsp + 2 tbsp cornstarch", "for cake flour")],
        "self rising flour": [Suggestion("1 cup AP flour + 1½ tsp baking powder + ¼ tsp salt")],
        "bread crumbs": [Suggestion("equal panko, crushed crackers, or rolled oats")],
        "panko": [Suggestion("equal regular bread crumbs")],
        "baking powder": [Suggestion("¼ tsp baking soda + ½ tsp cream of tartar", "per 1 tsp")],
        "baking soda": [Suggestion("3× the amount in baking powder")],
        "cornstarch": [Suggestion("2 tbsp flour", "per 1 tbsp cornstarch")],
        "brown sugar": [Suggestion("1 cup white sugar + 1 tbsp molasses")],
        "sugar": [Suggestion("equal packed brown sugar"), Suggestion("¾ cup honey", "per cup; reduce liquid")],
        "powdered sugar": [Suggestion("1 cup sugar blended with 1 tbsp cornstarch")],
        "honey": [Suggestion("1¼ cup sugar + ¼ cup liquid", "per cup"), Suggestion("equal maple syrup or agave")],
        "maple syrup": [Suggestion("equal honey or agave")],
        "molasses": [Suggestion("¾ cup brown sugar", "per cup"), Suggestion("equal dark corn syrup")],
        "vanilla extract": [Suggestion("equal vanilla bean paste"), Suggestion("equal maple syrup", "in a pinch")],
        "cocoa powder": [Suggestion("3 tbsp cocoa + 1 tbsp butter", "= 1 oz unsweetened chocolate")],
        "yeast": [Suggestion("equal weight in active dry vs. instant", "adjust rise time")],

        // Oils, acids, condiments
        "vegetable oil": [Suggestion("equal canola, light olive, or melted butter")],
        "olive oil": [Suggestion("equal avocado or canola oil")],
        "lemon juice": [Suggestion("equal lime juice"), Suggestion("½ the amount white vinegar", "in a pinch")],
        "lime juice": [Suggestion("equal lemon juice")],
        "white vinegar": [Suggestion("equal lemon juice or apple cider vinegar")],
        "soy sauce": [Suggestion("equal tamari or coconut aminos")],
        "worcestershire": [Suggestion("equal soy sauce + a pinch of sugar")],
        "dijon mustard": [Suggestion("equal yellow mustard + a pinch of horseradish")],
        "mayonnaise": [Suggestion("plain Greek yogurt, 1:1")],
        "ketchup": [Suggestion("½ cup tomato sauce + 2 tbsp sugar + 1 tbsp vinegar")],

        // Produce & aromatics
        "garlic": [Suggestion("⅛ tsp garlic powder", "per clove")],
        "garlic powder": [Suggestion("1 fresh clove", "per ⅛ tsp")],
        "onion": [Suggestion("1 tbsp onion powder", "per medium onion"), Suggestion("equal shallot or leek")],
        "shallot": [Suggestion("equal onion + a pinch of garlic")],
        "ginger": [Suggestion("¼ tsp ground ginger", "per 1 tbsp fresh")],
        "cilantro": [Suggestion("equal flat-leaf parsley", "milder flavor")],
        "fresh herbs": [Suggestion("⅓ the amount dried")],
        "tomato sauce": [Suggestion("⅜ cup tomato paste + ½ cup water", "per cup")],
        "tomato paste": [Suggestion("equal reduced tomato sauce")],

        // Proteins & staples
        "ground beef": [Suggestion("equal ground turkey, chicken, or plant crumbles")],
        "chicken broth": [Suggestion("equal vegetable broth, or water + 1 bouillon cube per cup")],
        "beef broth": [Suggestion("equal vegetable broth, or water + 1 bouillon cube per cup")],
        "white wine": [Suggestion("equal chicken or vegetable broth + 1 tsp vinegar")],
        "red wine": [Suggestion("equal beef broth + 1 tsp vinegar")],
        "rice": [Suggestion("equal quinoa, couscous, or orzo")],
        "pasta": [Suggestion("equal amount of any shape you have")],
        "peanut butter": [Suggestion("equal almond or sunflower-seed butter")],
        "chocolate chips": [Suggestion("chopped chocolate bar, equal weight")],
    ]

    /// Pre-sorted keys (cached) so `GroceryKeyword.bestKey` doesn't re-sort
    /// per lookup.
    private static let keys = Array(table.keys)

    /// Curated swaps for an item name, best first. Empty when we have no
    /// confident suggestion — callers should then invite a free-text note
    /// rather than show a guess.
    static func suggestions(for itemName: String) -> [Suggestion] {
        guard let key = GroceryKeyword.bestKey(in: itemName, keys: keys) else { return [] }
        return table[key] ?? []
    }
}
