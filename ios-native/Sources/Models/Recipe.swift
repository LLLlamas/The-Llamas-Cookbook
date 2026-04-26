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
    /// Optional photo attached to this step. External-storage so the
    /// bytes live in a sidecar file and don't bloat the SwiftData store
    /// itself. Surfaced as a thumbnail in Detail and full-width in Cook
    /// Mode. Bytes flow through `DraftStep.image` on save — see the
    /// gotcha called out in [Photo-Capability.md §3](../../../Photo-Capability.md).
    @Attribute(.externalStorage) var image: Data? = nil
    var recipe: Recipe?

    init(
        text: String,
        order: Int,
        needsTimer: Bool = false,
        specialNote: String? = nil,
        image: Data? = nil
    ) {
        self.id = UUID()
        self.order = order
        self.text = text
        self.needsTimer = needsTimer
        self.specialNote = specialNote
        self.image = image
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
    var order: Int
    var recipe: Recipe?

    init(image: Data?, order: Int) {
        self.id = UUID()
        self.image = image
        self.order = order
    }
}
