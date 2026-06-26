import Foundation
import SwiftData

/// A grocery list the user builds — typically from one or more recipes —
/// and works through at the store. Lives entirely in local SwiftData
/// (`cloudKitDatabase: .none`); when the user shares a list it's mirrored
/// to a `GroceryListShare` CloudKit public record (see
/// `CloudGroceryListService`), but the local model stays the source of
/// truth for the owner's own copy.
///
/// **Why a `@Model` and not a UserDefaults side-store** (the route
/// per-recipe ingredient marks took via `ImportCountCache`): a list is a
/// first-class, multi-recipe, relational object surfaced in its own tab —
/// awkward to express as a UserDefaults blob. A *new* model carries none
/// of the `Ingredient`-migration risk that motivated the side-store
/// pattern, and `LibraryMirrorService` only observes `Recipe`, so list
/// edits never trigger a spurious recipe republish to CloudKit.
@Model
final class GroceryList {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    /// CloudKit `GroceryListShare.recordName` once this list has been
    /// published (web link or app-to-app share). Nil while the list is
    /// purely local. Lets re-shares reuse the same record + permalink.
    var shareRecordName: String?

    /// True for a list the user created; false for one a friend shared
    /// *to* them (mirrored in from CloudKit). Drives ownership-only
    /// affordances (rename, delete-for-everyone) vs. participant ones.
    var ownerIsMe: Bool

    @Relationship(deleteRule: .cascade, inverse: \GroceryItem.list)
    var items: [GroceryItem] = []

    init(
        name: String,
        ownerIsMe: Bool = true,
        shareRecordName: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.ownerIsMe = ownerIsMe
        self.shareRecordName = shareRecordName
        self.createdAt = .now
        self.updatedAt = .now
    }

    /// Relationships come back in insertion order; callers assign an
    /// explicit `order`. Mirrors `Recipe.sortedIngredients`.
    var sortedItems: [GroceryItem] {
        items.sorted { $0.order < $1.order }
    }

    // MARK: - Shopping progress (single source of truth)
    //
    // The Lists row summary, the Lists tab-bar badge, the "all set" done
    // indicator, and the detail-view header ALL read these — never
    // re-derive `needed && !isChecked` inline at a call site. Adding a
    // new surface? Reuse one of these, don't copy the predicate.

    /// Items still to buy: needed and not yet checked into the cart.
    var toBuyCount: Int {
        items.reduce(0) { $0 + (($1.needed && !$1.isChecked) ? 1 : 0) }
    }

    /// A non-empty list with nothing left to buy — every item is either
    /// checked off or marked "have". Drives the green "all set" done
    /// state. An *empty* list is deliberately NOT "all set" (there's
    /// nothing accomplished yet), so callers can show a distinct empty
    /// treatment.
    var isAllSet: Bool {
        !items.isEmpty && toBuyCount == 0
    }

    /// "Open" = still has shopping left to do. The Lists tab badge counts
    /// these. Empty lists and fully-shopped ("all set") lists are not open.
    var isOpen: Bool {
        toBuyCount > 0
    }

    /// Touch `updatedAt`. Call after ANY mutation — including flipping a
    /// child `GroceryItem`'s `isChecked`/`needed` — so the Lists tab sorts
    /// most-recently-touched first and its per-list counts re-render.
    /// (A `@Query` on `GroceryList` isn't guaranteed to re-fire when only a
    /// child scalar changes; bumping `updatedAt` here is what the tab's
    /// summary counts observe. Load-bearing — don't mutate items without it.)
    func touch() {
        updatedAt = .now
    }
}

@Model
final class GroceryItem {
    var id: UUID
    var name: String
    var quantity: String?
    var unit: String?

    /// Grocery aisle/section assigned by the llama triage (or the
    /// heuristic fallback). Nil until triaged. Used purely for grouping
    /// the list — see `GroceryAisle` for the canonical ordering.
    var aisle: String?

    /// have/need. `false` = the user already has it (pantry staple or
    /// hand-marked), so it doesn't need buying. `true` = on the buy list.
    var needed: Bool

    /// In-cart check-off. Flipped by whoever is shopping (owner, a
    /// friend in-app, or a web shopper). Distinct from `needed`: you can
    /// need an item and not yet have checked it into the cart.
    var isChecked: Bool

    /// Shopper flagged "they don't have this" at the store. Drives the
    /// substitution request to the list owner (Phase 7).
    var outOfStock: Bool

    /// The cook's suggested swap for an out-of-stock item, e.g.
    /// "large brown eggs". Nil until the owner answers a request.
    var substitution: String?

    /// The recipe this item came from, when added via a recipe's
    /// "Add to grocery list". Nil for hand-added items. Lets a future
    /// view group/trace a list back to its source recipes.
    var sourceRecipeID: UUID?

    var order: Int
    var list: GroceryList?

    init(
        name: String,
        quantity: String? = nil,
        unit: String? = nil,
        aisle: String? = nil,
        needed: Bool = true,
        isChecked: Bool = false,
        outOfStock: Bool = false,
        substitution: String? = nil,
        sourceRecipeID: UUID? = nil,
        order: Int
    ) {
        self.id = UUID()
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.aisle = aisle
        self.needed = needed
        self.isChecked = isChecked
        self.outOfStock = outOfStock
        self.substitution = substitution
        self.sourceRecipeID = sourceRecipeID
        self.order = order
    }
}
