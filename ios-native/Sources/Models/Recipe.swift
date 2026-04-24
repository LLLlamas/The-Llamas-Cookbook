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

    @Relationship(deleteRule: .cascade, inverse: \Ingredient.recipe)
    var ingredients: [Ingredient] = []

    @Relationship(deleteRule: .cascade, inverse: \RecipeStep.recipe)
    var steps: [RecipeStep] = []

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
    var recipe: Recipe?

    init(text: String, order: Int, needsTimer: Bool = false, specialNote: String? = nil) {
        self.id = UUID()
        self.order = order
        self.text = text
        self.needsTimer = needsTimer
        self.specialNote = specialNote
    }
}
