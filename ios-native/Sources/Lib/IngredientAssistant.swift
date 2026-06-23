import Foundation
import FoundationModels

/// On-device grocery intelligence: triages a list into aisles + have/need,
/// explains an unfamiliar item ("what is this?"), and suggests substitutes
/// for an out-of-stock one. Mirrors `RecipeAIParser`'s availability gating
/// and error-swallowing — every path degrades to `GroceryKnowledge`'s
/// researched reference data when Apple Intelligence is unavailable, so the
/// feature works on every device. The model, when present, is *grounded* by
/// the same reference data (aisle vocabulary, staple definition) so its
/// output stays consistent with the heuristic.
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
        /// input index → likely already-on-hand (pantry staple)
        var stapleByIndex: [Int: Bool]
    }

    /// Classify each name into an aisle + pantry-staple guess. Uses the
    /// on-device model when available, else the researched heuristic. Pure
    /// in/out (no SwiftData) so the caller applies the result on the main
    /// actor.
    static func triage(names: [String]) async -> TriageResult {
        guard !names.isEmpty else { return TriageResult(aisleByIndex: [:], stapleByIndex: [:]) }
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
        var staple: [Int: Bool] = [:]
        for (i, name) in names.enumerated() {
            aisle[i] = GroceryKnowledge.aisle(for: name)
            staple[i] = GroceryKnowledge.isPantryStaple(name)
        }
        return TriageResult(aisleByIndex: aisle, stapleByIndex: staple)
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
            var staple: [Int: Bool] = [:]
            for item in response.content.items where item.index >= 0 && item.index < names.count {
                aisle[item.index] = GroceryAisle.normalize(item.aisle)
                staple[item.index] = item.isPantryStaple
            }
            // Backfill anything the model skipped with the heuristic so no
            // row is ever left unclassified.
            let fallback = heuristicTriage(names: names)
            for i in names.indices {
                if aisle[i] == nil { aisle[i] = fallback.aisleByIndex[i] }
                if staple[i] == nil { staple[i] = fallback.stapleByIndex[i] }
            }
            return TriageResult(aisleByIndex: aisle, stapleByIndex: staple)
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
        @Guide(description: "Grocery aisle. Choose exactly one of: Produce, Bakery, Meat & Seafood, Dairy & Eggs, Frozen, Pantry & Dry Goods, Spices, Beverages, Household, Other.")
        let aisle: String
        @Guide(description: "True only for shelf-stable basics a home cook usually already has (salt, pepper, sugar, flour, oil, common dried spices, baking soda or powder, water). False for anything fresh, refrigerated, or specific.")
        let isPantryStaple: Bool
    }

    @Generable
    struct SubstituteSuggestions {
        @Guide(description: "1 to 3 common substitutes, each a short grocery item name with amounts if relevant.")
        let substitutes: [String]
    }

    // MARK: - Instructions (grounded by GroceryKnowledge)

    private static let triageInstructions = """
    You sort grocery items for a shopping list. For each numbered item, pick the single best grocery aisle from EXACTLY this list: \(GroceryKnowledge.aisleVocabulary). Also mark whether the item is a basic pantry staple a home cook almost always already has at home. Use each item's own number as its index. Never invent items and never change their names.
    """

    private static let describeInstructions = """
    You help a grocery shopper who doesn't recognize an item. In 1–2 short, friendly sentences, say what the item is, what it looks like, and which grocery aisle or section to look in. Be concrete and brief. No markdown, no lists.
    """

    private static let substituteInstructions = """
    You suggest practical cooking substitutes for an ingredient a shopper can't find. Give 1–3 common swaps a typical grocery store stocks, each short (e.g. "1 cup plain yogurt"). Prefer everyday items. Never invent obscure products.
    """
}
