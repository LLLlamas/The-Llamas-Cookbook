import Foundation

/// Transient, plain-Swift mirror of a Recipe used by the editor. We edit
/// into a draft and only commit to SwiftData on Save so Cancel is non-destructive.
struct DraftRecipe: Equatable {
    var title: String = ""
    var summary: String = ""
    var sourceUrl: String = ""
    var servings: String = ""
    var cookTimeMinutes: String = ""
    var tags: [String] = []
    var favorite: Bool = false
    var ingredients: [DraftIngredient] = []
    var steps: [DraftStep] = []

    var hasAnyContent: Bool {
        !title.trimmed.isEmpty ||
        !summary.trimmed.isEmpty ||
        !sourceUrl.trimmed.isEmpty ||
        !ingredients.isEmpty ||
        !steps.isEmpty
    }

    var canSave: Bool {
        !title.trimmed.isEmpty
    }
}

struct DraftIngredient: Identifiable, Equatable {
    let id: UUID
    var quantity: String = ""
    var unit: String = ""
    var name: String = ""

    init(id: UUID = UUID(), quantity: String = "", unit: String = "", name: String = "") {
        self.id = id
        self.quantity = quantity
        self.unit = unit
        self.name = name
    }
}

struct DraftStep: Identifiable, Equatable {
    let id: UUID
    var text: String = ""
    var needsTimer: Bool = false
    /// Per-step reminder. Nil = no note; empty string is normalized to nil
    /// at save time so an empty text field doesn't persist as "has note".
    var specialNote: String? = nil

    init(id: UUID = UUID(), text: String = "", needsTimer: Bool = false, specialNote: String? = nil) {
        self.id = id
        self.text = text
        self.needsTimer = needsTimer
        self.specialNote = specialNote
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Recipe {
    func toDraft() -> DraftRecipe {
        DraftRecipe(
            title: title,
            summary: summary ?? "",
            sourceUrl: sourceUrl ?? "",
            servings: servings.map(String.init) ?? "",
            cookTimeMinutes: cookTimeMinutes.map(String.init) ?? "",
            tags: tags,
            favorite: favorite,
            ingredients: sortedIngredients.map {
                DraftIngredient(
                    id: $0.id,
                    quantity: $0.quantity ?? "",
                    unit: $0.unit ?? "",
                    name: $0.name
                )
            },
            steps: sortedSteps.map {
                DraftStep(
                    id: $0.id,
                    text: $0.text,
                    needsTimer: $0.needsTimer,
                    specialNote: $0.specialNote
                )
            }
        )
    }

    func apply(_ draft: DraftRecipe) {
        title = draft.title.trimmed
        summary = draft.summary.trimmed.nilIfEmpty
        sourceUrl = draft.sourceUrl.trimmed.nilIfEmpty
        servings = Int(draft.servings.trimmed)
        cookTimeMinutes = Int(draft.cookTimeMinutes.trimmed)
        // `notes` field is no longer surfaced — UI uses per-step special
        // notes instead. We deliberately don't write here, so any legacy
        // notes data on existing recipes survives untouched until the
        // model field is dropped in a future migration.
        tags = draft.tags
        favorite = draft.favorite
        updatedAt = .now

        // Replace children — SwiftData cascade-deletes via inverse relationship.
        ingredients.removeAll()
        for (idx, item) in draft.ingredients.enumerated() where !item.name.trimmed.isEmpty {
            let ingredient = Ingredient(
                quantity: item.quantity.trimmed.nilIfEmpty,
                unit: item.unit.trimmed.nilIfEmpty,
                name: item.name.trimmed,
                order: idx
            )
            ingredients.append(ingredient)
        }

        steps.removeAll()
        for (idx, item) in draft.steps.enumerated() where !item.text.trimmed.isEmpty {
            let step = RecipeStep(
                text: item.text.trimmed,
                order: idx,
                needsTimer: item.needsTimer,
                specialNote: item.specialNote?.trimmed.nilIfEmpty
            )
            steps.append(step)
        }
    }

    static func new(from draft: DraftRecipe) -> Recipe {
        let recipe = Recipe(title: draft.title.trimmed)
        recipe.apply(draft)
        return recipe
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
