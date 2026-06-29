import Foundation
import FoundationModels

/// On-device grocery intelligence: triages a list into store-walk aisles,
/// explains an unfamiliar item ("what is this?"), and suggests substitutes
/// for an out-of-stock one. Mirrors `RecipeAIParser`'s availability gating
/// and error-swallowing — every path degrades to `GroceryKnowledge`'s
/// researched reference data when Apple Intelligence is unavailable, so the
/// feature works on every device. The model, when present, is *grounded* by
/// the same reference data (aisle vocabulary) so its output stays
/// consistent with the heuristic.
enum IngredientAssistant {

    /// True when the on-device language model is ready (iOS 26+, Apple
    /// Intelligence enabled + downloaded). Every "no" bows to the heuristic.
    static var isAvailable: Bool {
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        return false
    }

    // MARK: - Triage

    struct TriageResult: Equatable {
        /// input index → aisle name (one of `GroceryAisle.ordered`)
        var aisleByIndex: [Int: String]
    }

    /// Classify each name into a store-walk aisle. Uses the on-device model
    /// when available, else the researched heuristic. Pure in/out (no
    /// SwiftData) so the caller applies the result on the main actor.
    static func triage(names: [String]) async -> TriageResult {
        guard !names.isEmpty else { return TriageResult(aisleByIndex: [:]) }
        if #available(iOS 26.0, *), isAvailable {
            if let modelResult = await triageWithModel(names) {
                return modelResult
            }
        }
        return heuristicTriage(names: names)
    }

    /// Pure researched-reference triage — also the AI fallback + backfill.
    /// Deterministic and unit-tested.
    static func heuristicTriage(names: [String]) -> TriageResult {
        var aisle: [Int: String] = [:]
        for (i, name) in names.enumerated() {
            aisle[i] = GroceryKnowledge.aisle(for: name)
        }
        return TriageResult(aisleByIndex: aisle)
    }

    @available(iOS 26.0, *)
    private static func triageWithModel(_ names: [String]) async -> TriageResult? {
        let session = LanguageModelSession(instructions: triageInstructions)
        let numbered = names.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        do {
            let response = try await session.respond(
                to: "Classify these grocery items:\n\(numbered)",
                generating: Triage.self
            )
            var aisle: [Int: String] = [:]
            for item in response.content.items where item.index >= 0 && item.index < names.count {
                aisle[item.index] = GroceryAisle.normalize(item.aisle)
            }
            // Backfill anything the model skipped with the heuristic so no
            // row is ever left unclassified.
            let fallback = heuristicTriage(names: names)
            for i in names.indices {
                if aisle[i] == nil { aisle[i] = fallback.aisleByIndex[i] }
            }
            return TriageResult(aisleByIndex: aisle)
        } catch {
            return nil
        }
    }

    // MARK: - What is this?

    /// A short, friendly explanation of an unfamiliar item + where to find
    /// it. Returns nil when the model is unavailable — the caller then offers
    /// only the "see photos on the web" affordance.
    static func describe(_ name: String) async -> String? {
        guard #available(iOS 26.0, *), isAvailable else { return nil }
        let session = LanguageModelSession(instructions: describeInstructions)
        do {
            let response = try await session.respond(to: "What is \"\(name)\" and where is it in a grocery store?")
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    // MARK: - Substitutes

    /// Suggested swaps for an out-of-stock item. Leads with the researched
    /// reference (instant, offline, trustworthy); only asks the model for
    /// the long tail it doesn't cover.
    static func suggestSubstitutes(for name: String, inRecipe recipeTitle: String? = nil) async -> [String] {
        let known = GroceryKnowledge.substitutes(for: name).map { sub in
            sub.note.map { "\(sub.replacement) — \($0)" } ?? sub.replacement
        }
        if !known.isEmpty { return known }

        guard #available(iOS 26.0, *), isAvailable else { return [] }
        let session = LanguageModelSession(instructions: substituteInstructions)
        let context = recipeTitle.map { " for \($0)" } ?? ""
        do {
            let response = try await session.respond(
                to: "Suggest substitutes for \"\(name)\"\(context).",
                generating: SubstituteSuggestions.self
            )
            return response.content.substitutes
        } catch {
            return []
        }
    }

    // MARK: - Generable schemas

    @Generable
    struct Triage {
        @Guide(description: "One entry per input item, using the item's number as index.")
        let items: [TriagedItem]
    }

    @Generable
    struct TriagedItem {
        @Guide(description: "The item's number from the input list.")
        let index: Int
        @Guide(description: "Grocery aisle. Choose exactly one of: Produce, Deli, Bakery, Meat & Seafood, Dairy & Eggs, Frozen, Breakfast & Cereal, Canned & Jarred, Condiments & Sauces, Pasta, Rice & Grains, Baking, Spices, Snacks, International, Beverages, Pantry & Dry Goods, Baby, Health & Pharmacy, Personal Care, Household, Pet, Other.")
        let aisle: String
    }

    @Generable
    struct SubstituteSuggestions {
        @Guide(description: "1 to 3 common substitutes, each a short grocery item name with amounts if relevant.")
        let substitutes: [String]
    }

    // MARK: - Instructions (grounded by GroceryKnowledge)

    private static let triageInstructions = """
    You sort items on a grocery / drugstore shopping list into store departments. For each numbered item, pick the single best aisle from EXACTLY this list: \(GroceryKnowledge.aisleVocabulary). Use each item's own number as its index. Never invent items and never change their names.

    What each department holds:
    \(triageHints)

    Tie-breakers: a more specific form wins over the generic one — dried/ground "garlic powder" is Spices not Produce; a canned/jarred form is Canned & Jarred not the fresh aisle; "baby <item>" is Baby; an OTC medicine with a brand name is Health & Pharmacy. Use Pantry & Dry Goods only when no more specific center aisle fits, and Other only when nothing matches.
    """

    /// Compact per-department guidance handed to the triage prompt so the
    /// model knows what each of the new center/non-food aisles holds.
    /// Sourced from the researched grocery taxonomy.
    private static let triageHints = """
    - Produce: Fresh whole fruit, vegetables, fresh-cut herbs, fresh garlic/ginger, refrigerated tofu/guacamole at the produce edge. NOT dried, canned, frozen, or jarred versions.
    - Deli: Refrigerated sliced cold cuts, cured meats, deli-counter cheese, rotisserie chicken, and refrigerated dips/spreads (hummus, tzatziki) + prepared salads.
    - Bakery: Fresh bread, rolls, buns, bagels, tortillas, pita/naan, and sweet bakery (croissants, muffins, cake). NOT crackers/cookies (Snacks) or mixes (Baking).
    - Meat & Seafood: Raw/fresh meat, poultry, pork, bacon, fresh sausage, and fresh/raw fish & shellfish. NOT canned, frozen-breaded, deli-sliced, or jerky.
    - Dairy & Eggs: Refrigerated milk & plant-milk cartons, butter, eggs, yogurt, packaged cheese, sour cream, refrigerated tofu/dough. NOT canned/condensed/evaporated milk (Baking).
    - Frozen: Anything sold frozen: vegetables, fruit, meals, pizza, ice cream, frozen breakfast, frozen seafood, ice. The word 'frozen' is decisive.
    - Breakfast & Cereal: Boxed cereal, oatmeal/oats, hot cereal, granola, toaster pastries, pancake/waffle mix, breakfast syrups. NOT frozen waffles/pancakes (Frozen).
    - Canned & Jarred: Shelf-stable cans/jars: tomatoes, canned beans, canned veg/fruit, canned fish, broth/stock, soup. Plain canned 'tomato sauce' lives here, seasoned pasta sauce does not.
    - Condiments & Sauces: Bottled/jarred table condiments, dressings, hot sauce, jarred pasta sauce & salsa, pickles & olives, nut-butter spreads, jams/jelly, table vinegars, honey.
    - Pasta, Rice & Grains: Dry pasta & noodles, rice, quinoa and other grains, and DRIED beans/lentils. Canned beans go to Canned & Jarred; flours go to Baking.
    - Baking: Flour, sugar, leaveners, extracts, baking chocolate/chips & cocoa, baking mixes, cooking oils, canned condensed/evaporated milk, baking nuts & raisins.
    - Spices: Dried/ground spices & herbs, salt & pepper, seasoning blends and rubs. Dried forms win over the fresh produce equivalent.
    - Snacks: Chips, crackers, cookies, pretzels, popcorn, candy/chocolate bars, snack/granola bars, jerky, trail mix & snacking nuts, fruit snacks, shelf-stable snack cups.
    - International: Ethnic-aisle staples: Asian sauces/noodles, curry pastes, canned coconut milk, Hispanic masa/chiles/sauces, Indian dals/masalas, Mediterranean & Kosher specialties.
    - Beverages: Coffee, tea, soda, sparkling & bottled water, shelf-stable juice, sports/energy drinks, drink mixes, and all alcohol.
    - Pantry & Dry Goods: Catch-all for shelf-stable items that don't fit a more specific center aisle (e.g. plain olive oil, breadcrumbs); also the backward-compat bucket for already-stored values.
    - Baby: Diapers, wipes, formula, baby food, and baby-care toiletries. 'Baby <item>' always wins over the generic toiletry.
    - Health & Pharmacy: OTC medicine (brand + active ingredient), first aid, vitamins & supplements, eye/family-planning care.
    - Personal Care: Hair, skin, oral, shave, deodorant, cosmetics, feminine care, sun care, and personal hygiene toiletries.
    - Household: Cleaning supplies, laundry/dish products, paper goods, foil/wraps/bags, batteries, bulbs, and general home/utility items.
    - Pet: Pet food, treats, litter, and pet-care supplies for any animal.
    """

    private static let describeInstructions = """
    You help a shopper who doesn't recognize an item on their grocery / drugstore list. In ONE short clause of about 12 words or fewer, say what it is and which aisle to find it. For a non-food product, lead with its generic CATEGORY and primary use, not a recipe-style line, and add the brand only as an aside — e.g. "Swiffer — floor-cleaning wet/dry mop, the cleaning aisle." For an OTC medicine, name the active ingredient in parentheses (e.g. "Tylenol — pain/fever reliever (acetaminophen), the pharmacy aisle."). For an ambiguous brand word (Dove, Bounty, Gain, Secret) pick the grocery sense, not the homonym. Stay factual: no marketing language, and never invent dosages, sizes, or health claims. No markdown, no lists, no full paragraphs.
    """

    private static let substituteInstructions = """
    You suggest practical cooking substitutes for an ingredient a shopper can't find. Give 1–3 common swaps a typical grocery store stocks, each short (e.g. "1 cup plain yogurt"). Prefer everyday items. Never invent obscure products.
    """
}
