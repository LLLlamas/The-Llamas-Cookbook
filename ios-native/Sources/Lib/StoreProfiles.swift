import Foundation
import Observation

/// A named store with its own aisle walk order — "my Kroger", "Costco run".
/// `aisleOrder` is a permutation of `GroceryAisle.ordered` captured when the
/// profile was created/edited; always read it back through
/// `GroceryAisle.resolvedOrder` so profiles saved before a taxonomy change
/// self-heal (stale names dropped, new aisles appended).
struct StoreProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var aisleOrder: [String]
}

/// Device-local store profiles + per-list store assignment, persisted in
/// UserDefaults as JSON (the `ImportCountCache`/`AppearanceSettings`
/// pattern — a viewing preference, deliberately OUT of the SwiftData
/// schema and never synced: the owner and each recipient of a shared list
/// shop at their own stores, so each device keeps its own walk order.
/// The CloudKit record and shared web page stay in canonical order.)
@Observable
final class StoreProfileStore {
    private(set) var profiles: [StoreProfile] = []
    /// List UUID string → store UUID string. Missing key = default order.
    private var assignments: [String: String] = [:]

    private static let profilesKey = "storeProfiles.v1"
    private static let assignmentsKey = "storeProfileByList.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([StoreProfile].self, from: data) {
            profiles = decoded
        }
        if let stored = defaults.dictionary(forKey: Self.assignmentsKey) as? [String: String] {
            assignments = stored
        }
    }

    // MARK: - Profiles

    /// Create a profile. `aisleOrder` defaults to the canonical walk; pass a
    /// `StoreTemplate.order` to seed a chain's typical layout instead.
    @discardableResult
    func add(named name: String, aisleOrder: [String] = GroceryAisle.ordered) -> StoreProfile {
        let profile = StoreProfile(
            id: UUID(),
            name: name,
            aisleOrder: GroceryAisle.resolvedOrder(aisleOrder)
        )
        profiles.append(profile)
        persistProfiles()
        return profile
    }

    func rename(_ id: UUID, to newName: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = newName
        persistProfiles()
    }

    func setAisleOrder(_ order: [String], for id: UUID) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].aisleOrder = GroceryAisle.resolvedOrder(order)
        persistProfiles()
    }

    /// Delete a profile and scrub any list assignments pointing at it, so
    /// those lists fall back to the default walk order.
    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        let key = id.uuidString
        let orphaned = assignments.filter { $0.value == key }.map(\.key)
        for listKey in orphaned {
            assignments.removeValue(forKey: listKey)
        }
        persistProfiles()
        if !orphaned.isEmpty { persistAssignments() }
    }

    // MARK: - Per-list assignment

    /// Point a list at a store (nil = default canonical order).
    func assign(_ storeID: UUID?, toList listID: UUID) {
        if let storeID {
            assignments[listID.uuidString] = storeID.uuidString
        } else {
            assignments.removeValue(forKey: listID.uuidString)
        }
        persistAssignments()
    }

    func assignedStoreID(forList listID: UUID) -> UUID? {
        assignments[listID.uuidString].flatMap(UUID.init(uuidString:))
    }

    /// Tolerant lookup: an assignment to a since-deleted store resolves to
    /// nil (default order) rather than crashing or lingering.
    func profile(forList listID: UUID) -> StoreProfile? {
        guard let storeID = assignedStoreID(forList: listID) else { return nil }
        return profiles.first { $0.id == storeID }
    }

    /// The healed walk order for a list, or nil to use the canonical order.
    func aisleOrder(forList listID: UUID) -> [String]? {
        profile(forList: listID).map { GroceryAisle.resolvedOrder($0.aisleOrder) }
    }

    // MARK: - Persistence

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.profilesKey)
        }
    }

    private func persistAssignments() {
        defaults.set(assignments, forKey: Self.assignmentsKey)
    }
}

/// A chain's typical-format walk order, offered when creating a store
/// profile so the user starts from a familiar layout instead of a blank
/// canonical walk. These are FORMAT-level approximations — real layouts
/// vary store to store — so the editor's drag-to-reorder is the finishing
/// step, not an afterthought. Every `order` must be a full permutation of
/// `GroceryAisle.ordered` (CI-enforced) so no aisle silently vanishes.
struct StoreTemplate: Identifiable {
    let name: String
    let order: [String]

    var id: String { name }

    /// Common US chains, roughly by format: full supermarkets first, then
    /// supercenters, warehouse, small-box, and drugstore.
    static let all: [StoreTemplate] = [
        StoreTemplate(name: "Kroger", order: [
            "Produce", "Deli", "Bakery", "Meat & Seafood", "International",
            "Canned & Jarred", "Condiments & Sauces", "Pasta, Rice & Grains",
            "Baking", "Spices", "Breakfast & Cereal", "Snacks", "Beverages",
            "Pantry & Dry Goods", "Baby", "Health & Pharmacy", "Personal Care",
            "Household", "Pet", "Frozen", "Dairy & Eggs", "Other",
        ]),
        StoreTemplate(name: "Safeway / Albertsons", order: [
            "Produce", "Bakery", "Deli", "Meat & Seafood", "Canned & Jarred",
            "Condiments & Sauces", "Pasta, Rice & Grains", "International",
            "Baking", "Spices", "Breakfast & Cereal", "Snacks", "Beverages",
            "Pantry & Dry Goods", "Baby", "Health & Pharmacy", "Personal Care",
            "Household", "Pet", "Frozen", "Dairy & Eggs", "Other",
        ]),
        StoreTemplate(name: "Publix", order: [
            "Produce", "Deli", "Bakery", "Meat & Seafood", "Breakfast & Cereal",
            "Canned & Jarred", "Condiments & Sauces", "Pasta, Rice & Grains",
            "International", "Baking", "Spices", "Snacks", "Beverages",
            "Pantry & Dry Goods", "Baby", "Health & Pharmacy", "Personal Care",
            "Household", "Pet", "Frozen", "Dairy & Eggs", "Other",
        ]),
        StoreTemplate(name: "Whole Foods", order: [
            "Produce", "Bakery", "Deli", "Meat & Seafood", "International",
            "Pasta, Rice & Grains", "Canned & Jarred", "Condiments & Sauces",
            "Spices", "Baking", "Breakfast & Cereal", "Snacks", "Beverages",
            "Pantry & Dry Goods", "Frozen", "Dairy & Eggs",
            "Health & Pharmacy", "Personal Care", "Baby", "Household", "Pet",
            "Other",
        ]),
        StoreTemplate(name: "Trader Joe's", order: [
            "Produce", "Bakery", "Deli", "Meat & Seafood", "Frozen",
            "Dairy & Eggs", "Snacks", "Breakfast & Cereal",
            "Pasta, Rice & Grains", "Canned & Jarred", "Condiments & Sauces",
            "International", "Spices", "Baking", "Pantry & Dry Goods",
            "Beverages", "Health & Pharmacy", "Personal Care", "Baby",
            "Household", "Pet", "Other",
        ]),
        StoreTemplate(name: "Walmart Supercenter", order: [
            "Produce", "Deli", "Bakery", "Meat & Seafood", "Dairy & Eggs",
            "Frozen", "Breakfast & Cereal", "Canned & Jarred",
            "Condiments & Sauces", "Pasta, Rice & Grains", "Baking", "Spices",
            "International", "Snacks", "Beverages", "Pantry & Dry Goods",
            "Baby", "Health & Pharmacy", "Personal Care", "Household", "Pet",
            "Other",
        ]),
        StoreTemplate(name: "Target", order: [
            "Produce", "Bakery", "Deli", "Meat & Seafood", "Dairy & Eggs",
            "Frozen", "Breakfast & Cereal", "Snacks", "Canned & Jarred",
            "Condiments & Sauces", "Pasta, Rice & Grains", "Baking", "Spices",
            "International", "Beverages", "Pantry & Dry Goods",
            "Health & Pharmacy", "Personal Care", "Baby", "Pet", "Household",
            "Other",
        ]),
        StoreTemplate(name: "Costco", order: [
            "Snacks", "Canned & Jarred", "Condiments & Sauces",
            "Pasta, Rice & Grains", "Breakfast & Cereal", "Baking", "Spices",
            "International", "Beverages", "Pantry & Dry Goods",
            "Health & Pharmacy", "Personal Care", "Baby", "Pet", "Household",
            "Produce", "Meat & Seafood", "Deli", "Dairy & Eggs", "Frozen",
            "Bakery", "Other",
        ]),
        StoreTemplate(name: "Aldi", order: [
            "Produce", "Bakery", "Snacks", "Breakfast & Cereal",
            "Canned & Jarred", "Condiments & Sauces", "Pasta, Rice & Grains",
            "Baking", "Spices", "International", "Meat & Seafood", "Deli",
            "Dairy & Eggs", "Frozen", "Beverages", "Pantry & Dry Goods",
            "Baby", "Health & Pharmacy", "Personal Care", "Pet", "Household",
            "Other",
        ]),
        StoreTemplate(name: "CVS / Walgreens", order: [
            "Snacks", "Beverages", "Breakfast & Cereal", "Canned & Jarred",
            "Condiments & Sauces", "Pantry & Dry Goods", "Personal Care",
            "Health & Pharmacy", "Baby", "Household", "Pet", "Dairy & Eggs",
            "Frozen", "Pasta, Rice & Grains", "Baking", "Spices",
            "International", "Produce", "Deli", "Bakery", "Meat & Seafood",
            "Other",
        ]),
    ]
}
