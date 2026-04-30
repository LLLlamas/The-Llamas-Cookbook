import Foundation

/// UserDefaults-backed cache for the "Imported by N" chip on
/// `RecipeDetailView`. Holds the last-known transitive import count
/// + its check timestamp, keyed by local recipe UUID.
///
/// **Why not on `Recipe` directly.** Stashing these on the `@Model`
/// triggered SwiftData change notifications on every chip refresh,
/// which propagated `updatedAt` and risked spurious
/// `LibraryMirrorService.enqueueUpsert` re-publishes to CloudKit —
/// a recipe whose Detail view is opened frequently would re-upload
/// the same `PublishedRecipe` envelope repeatedly even though
/// nothing about the recipe itself changed. UserDefaults keeps the
/// presentation cache out of the SwiftData change stream entirely.
///
/// Values are intentionally ephemeral — losing the cache (app
/// reinstall, defaults clear) just means the chip renders 0 once
/// and then stale-while-revalidates against CloudKit on the next
/// open. Cheap to lose, expensive to keep on the model.
enum ImportCountCache {
    private static let countKeyPrefix = "importCount.count.v1."
    private static let checkedAtKeyPrefix = "importCount.checkedAt.v1."

    static func count(for recipeID: UUID) -> Int {
        UserDefaults.standard.integer(forKey: countKey(for: recipeID))
    }

    static func checkedAt(for recipeID: UUID) -> Date? {
        UserDefaults.standard.object(forKey: checkedAtKey(for: recipeID)) as? Date
    }

    static func set(count: Int, checkedAt: Date, for recipeID: UUID) {
        let defaults = UserDefaults.standard
        defaults.set(count, forKey: countKey(for: recipeID))
        defaults.set(checkedAt, forKey: checkedAtKey(for: recipeID))
    }

    /// Drop both keys for a recipe. Called from the recipe-delete
    /// paths (`LibraryView` long-press delete + `RecipeDetailView`
    /// trash) so the defaults database doesn't bloat with entries
    /// for recipes the user no longer has.
    static func clear(for recipeID: UUID) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: countKey(for: recipeID))
        defaults.removeObject(forKey: checkedAtKey(for: recipeID))
    }

    private static func countKey(for recipeID: UUID) -> String {
        countKeyPrefix + recipeID.uuidString
    }

    private static func checkedAtKey(for recipeID: UUID) -> String {
        checkedAtKeyPrefix + recipeID.uuidString
    }
}
