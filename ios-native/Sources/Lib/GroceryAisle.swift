import Foundation

/// Canonical grocery-aisle vocabulary + grouping. The on-device triage
/// (`IngredientAssistant`) tags each item with one of these aisle names;
/// the Lists detail view, the shared web page, and the plain-text export
/// all group + order by this single source of truth so a list reads in a
/// sensible store-walk order everywhere.
enum GroceryAisle {
    /// Store-walk order — produce first, household/other last. Grouping and
    /// section display follow this sequence.
    static let ordered: [String] = [
        "Produce",
        "Deli",
        "Bakery",
        "Meat & Seafood",
        "Dairy & Eggs",
        "Frozen",
        "Breakfast & Cereal",
        "Canned & Jarred",
        "Condiments & Sauces",
        "Pasta, Rice & Grains",
        "Baking",
        "Spices",
        "Snacks",
        "International",
        "Beverages",
        "Pantry & Dry Goods",
        "Baby",
        "Health & Pharmacy",
        "Personal Care",
        "Household",
        "Pet",
        "Other",
    ]

    /// Bucket for unrecognized / untriaged items.
    static let fallback = "Other"

    private static let index: [String: Int] = Dictionary(
        uniqueKeysWithValues: ordered.enumerated().map { ($0.element.lowercased(), $0.offset) }
    )

    /// Normalize an arbitrary aisle string to one of `ordered` (case- and
    /// whitespace-tolerant). Unknown or nil → `fallback`.
    static func normalize(_ raw: String?) -> String {
        guard let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !key.isEmpty,
              let position = index[key]
        else { return fallback }
        return ordered[position]
    }

    /// Sort rank for an aisle string (lower = earlier in the walk).
    /// Unknown aisles sort to the end alongside `fallback`.
    static func rank(_ raw: String?) -> Int {
        index[GroceryAisle.normalize(raw).lowercased()] ?? ordered.count
    }

    /// Group items into `(aisle, items)` sections in store-walk order —
    /// canonical by default, or a store profile's custom walk when
    /// `order` is provided (run through `resolvedOrder`, so stale/partial
    /// permutations degrade gracefully). Items keep their incoming
    /// relative order within a section; empty sections are omitted.
    /// `aisleOf` extracts each item's raw aisle (nil → `fallback`).
    static func group<T>(
        _ items: [T],
        order customOrder: [String]? = nil,
        aisleOf: (T) -> String?
    ) -> [(aisle: String, items: [T])] {
        var buckets: [String: [T]] = [:]
        for item in items {
            buckets[normalize(aisleOf(item)), default: []].append(item)
        }
        let sequence = customOrder.map(resolvedOrder) ?? ordered
        return sequence.compactMap { aisle in
            guard let bucket = buckets[aisle], !bucket.isEmpty else { return nil }
            return (aisle, bucket)
        }
    }

    /// Heal a stored aisle permutation (a store profile's walk order)
    /// against the current taxonomy: drop entries that no longer name a
    /// canonical aisle (renamed/removed since the profile was saved) and
    /// any duplicates, then append canonical aisles the stored order
    /// predates — so old profiles keep working, with new aisles landing
    /// at the end in canonical order.
    static func resolvedOrder(_ stored: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in stored {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let position = index[key] else { continue }
            let name = ordered[position]
            if seen.insert(name).inserted { out.append(name) }
        }
        for aisle in ordered where !seen.contains(aisle) {
            out.append(aisle)
        }
        return out
    }
}
