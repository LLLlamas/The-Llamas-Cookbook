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

    /// Group items into `(aisle, items)` sections in canonical store-walk
    /// order. Items keep their incoming relative order within a section;
    /// empty sections are omitted. `aisleOf` extracts each item's raw aisle
    /// (nil → `fallback`).
    static func group<T>(_ items: [T], aisleOf: (T) -> String?) -> [(aisle: String, items: [T])] {
        var buckets: [String: [T]] = [:]
        for item in items {
            buckets[normalize(aisleOf(item)), default: []].append(item)
        }
        return ordered.compactMap { aisle in
            guard let bucket = buckets[aisle], !bucket.isEmpty else { return nil }
            return (aisle, bucket)
        }
    }
}
