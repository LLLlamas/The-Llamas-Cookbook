import Foundation
import SwiftData

// Renamed from `description` (reserved in Swift for CustomStringConvertible)
// and `Step` (common enough to collide with other imports).
@Model
final class Recipe {
    var id: UUID
    var title: String
    var summary: String?
    var sourceUrl: String?
    var imageUri: String?
    var servings: Int?
    var cookTimeMinutes: Int?
    var prepTimeMinutes: Int?
    var notes: String
    var favorite: Bool
    var tags: [String]
    var lastCookedAt: Date?
    var cookCount: Int
    var createdAt: Date
    var updatedAt: Date

    /// Stand-alone notes that don't belong to any single step. The editor
    /// surfaces these as alternative slots in the Special Notes picker:
    /// `prefaceNote` rides above step 1, `epilogueNote` after the last
    /// step, and `generalNote` is a roving reminder not tied to position.
    /// Optional + nil-default so existing recipes don't need migration.
    var prefaceNote: String?
    var epilogueNote: String?
    var generalNote: String?

    /// Provenance metadata for recipes imported from another user via
    /// the app-to-app share flow (`.llamarecipe` file or
    /// `llamascookbook://recipe/...` deep link). Nil for locally-
    /// authored recipes — the user made it themselves. Stamped at
    /// materialize time by `RecipeShare.materialize(_:into:)` and
    /// **intentionally never touched by `Recipe.apply(_:)`** (the editor
    /// save path) so a recipient can tweak the recipe without losing the
    /// original sharer's credit. Surfaced in Detail as
    /// "Originally shared by {sharedBy} · {sharedAt}". `sourceShareID`
    /// records the sender's original `Recipe.id` for future re-import
    /// detection. See Recipe-Sharing.md §5 + §8.3.
    var sharedBy: String?
    var sharedAt: Date?
    var sourceShareID: UUID?

    /// Friends-feature attribution (slice 5). Stamped at materialize
    /// time by `RecipeShare.materializeFromPublished(...)` when the
    /// user imports a recipe from a friend's cookbook. Distinct from
    /// the `sharedBy`/`sharedAt`/`sourceShareID` triple above —
    /// those drive the file/link share path's display chrome and
    /// stay untouched by friend imports so the two flows can
    /// coexist without semantic overload.
    ///
    /// **Two layers of attribution.**
    /// - `originalSharer*` — the friend you tapped to import. May
    ///   equal the original creator (you imported directly from
    ///   them) or differ (the friend had themselves imported it
    ///   from someone earlier in the chain).
    /// - `originalCreator*` — the chain root. The person whose
    ///   library this recipe was first published from. This is the
    ///   value the "Originally shared by [name]" header surfaces in
    ///   `RecipeDetailView`, since users care about the creator
    ///   regardless of how many hops it took to reach them.
    ///
    /// Display names are denormalized so the attribution line
    /// renders correctly offline — the original creator's
    /// `UserProfile` may not be fetchable when the user opens
    /// detail without iCloud.
    ///
    /// `originalRecipeID` is a String (not UUID) because the
    /// chain root might be a recipe authored on a future schema
    /// where ids aren't UUIDs. Treating it opaquely is forward-
    /// compatible.
    ///
    /// **`Recipe.apply(_:)` must never touch these** — same rule
    /// as the share fields above. Edits to an imported recipe
    /// preserve the chain.
    var originalSharerUserRecordName: String?
    var originalSharerDisplayName: String?
    var originalCreatorUserRecordName: String?
    var originalCreatorDisplayName: String?
    var originalRecipeID: String?
    var importedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Ingredient.recipe)
    var ingredients: [Ingredient] = []

    @Relationship(deleteRule: .cascade, inverse: \RecipeStep.recipe)
    var steps: [RecipeStep] = []

    /// Per-recipe gallery photos. Cascade-deletes the sidecar files when
    /// the recipe is deleted. Surfaced through the gallery button in
    /// Detail and Editor; deliberately not shown on the Library card or
    /// inside Cook Mode (UX principle 3 — Cook Mode is the cooking flow,
    /// not the recipe's identity).
    @Relationship(deleteRule: .cascade, inverse: \RecipePhoto.recipe)
    var photos: [RecipePhoto] = []

    init(
        title: String,
        summary: String? = nil,
        sourceUrl: String? = nil,
        imageUri: String? = nil,
        servings: Int? = nil,
        cookTimeMinutes: Int? = nil,
        prepTimeMinutes: Int? = nil,
        notes: String = "",
        favorite: Bool = false,
        tags: [String] = []
    ) {
        self.id = UUID()
        self.title = title
        self.summary = summary
        self.sourceUrl = sourceUrl
        self.imageUri = imageUri
        self.servings = servings
        self.cookTimeMinutes = cookTimeMinutes
        self.prepTimeMinutes = prepTimeMinutes
        self.notes = notes
        self.favorite = favorite
        self.tags = tags
        self.cookCount = 0
        self.createdAt = .now
        self.updatedAt = .now
    }

    func markCooked() {
        let now = Date.now
        lastCookedAt = now
        cookCount += 1
        updatedAt = now
    }

    /// Relationships come back in insertion order; the editor assigns an
    /// explicit `order` on save. Views and the export all want the same
    /// user-intended sequence, so expose it once here.
    var sortedIngredients: [Ingredient] {
        ingredients.sorted { $0.order < $1.order }
    }

    var sortedSteps: [RecipeStep] {
        steps.sorted { $0.order < $1.order }
    }

    /// Mirrors `sortedIngredients` / `sortedSteps`. Photos are stored with
    /// an explicit `order` because pickers don't return reliable ordering
    /// and the user expects insertion order in the carousel.
    var sortedPhotos: [RecipePhoto] {
        photos.sorted { $0.order < $1.order }
    }
}

@Model
final class Ingredient {
    var id: UUID
    var quantity: String?
    var unit: String?
    var name: String
    var order: Int
    var recipe: Recipe?

    init(
        quantity: String? = nil,
        unit: String? = nil,
        name: String,
        order: Int
    ) {
        self.id = UUID()
        self.quantity = quantity
        self.unit = unit
        self.name = name
        self.order = order
    }
}

@Model
final class RecipeStep {
    var id: UUID
    var order: Int
    var text: String
    var needsTimer: Bool = false
    /// Optional per-step reminder shown in Cook Mode when this step is
    /// active — e.g. "Don't forget to cut vertically". Authored from the
    /// editor's Notes section via `SpecialNotesEditor`.
    var specialNote: String? = nil
    /// **Deprecated** single-image slot. Left declared so SwiftData's
    /// lightweight migration doesn't have to drop an attribute on
    /// existing TestFlight installs that already wrote step bytes here.
    /// New code paths read/write through the `photos` relationship
    /// below instead — this field is no longer surfaced anywhere in
    /// the UI and will be removed in a future cleanup migration.
    @Attribute(.externalStorage) var image: Data? = nil
    var recipe: Recipe?

    /// Per-step gallery — up to 3 photos. Hidden behind a button on
    /// every viewing surface (Detail, Cook Mode); the editor surfaces
    /// the same button to add/manage. Cascade-delete cleans up
    /// sidecars when the step or its parent recipe is removed.
    @Relationship(deleteRule: .cascade, inverse: \RecipeStepPhoto.step)
    var photos: [RecipeStepPhoto] = []

    init(
        text: String,
        order: Int,
        needsTimer: Bool = false,
        specialNote: String? = nil
    ) {
        self.id = UUID()
        self.order = order
        self.text = text
        self.needsTimer = needsTimer
        self.specialNote = specialNote
    }

    /// Mirrors `Recipe.sortedPhotos` / `sortedSteps` — relationships
    /// come back in insertion order, the UI wants explicit ordering.
    var sortedStepPhotos: [RecipeStepPhoto] {
        photos.sorted { $0.order < $1.order }
    }
}

/// One photo attached to a recipe step. Mirrors `RecipePhoto`'s shape
/// and storage strategy. Capped at 3 per step at the editor / draft
/// layer; nothing in the model itself enforces the cap so legacy data
/// or future expansion stays compatible.
///
/// `caption` is optional free-form text the user attaches to a photo
/// (e.g. "after the autolyse", "doubled in size"). Lightweight
/// SwiftData migration handles existing rows — they decode with
/// `caption == nil`.
@Model
final class RecipeStepPhoto {
    var id: UUID
    @Attribute(.externalStorage) var image: Data?
    var caption: String?
    var order: Int
    var step: RecipeStep?

    init(image: Data?, caption: String? = nil, order: Int) {
        self.id = UUID()
        self.image = image
        self.caption = caption
        self.order = order
    }
}

/// One photo attached to a recipe's gallery. Stored as external-storage
/// bytes so the SwiftData store stays small and the sidecar file is
/// cascade-deleted with the recipe (and with the photo itself when the
/// user removes it from the carousel).
///
/// Lifetime: created by the editor (via DraftPhoto carry-through in
/// `Recipe.apply(_:)`) and by the Detail-quick-edit path (which mutates
/// `recipe.photos` directly). Order is set by the caller — newest photo
/// usually appended at `recipe.photos.count`.
@Model
final class RecipePhoto {
    var id: UUID
    @Attribute(.externalStorage) var image: Data?
    var caption: String?
    var order: Int
    var recipe: Recipe?

    init(image: Data?, caption: String? = nil, order: Int) {
        self.id = UUID()
        self.image = image
        self.caption = caption
        self.order = order
    }
}
