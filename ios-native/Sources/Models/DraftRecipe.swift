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
    /// Gallery photos. Bytes are carried through the draft so
    /// `apply(_:)` can rebuild the photo relationship without losing
    /// images on save. Without this, the relationship's `removeAll()`
    /// would cascade-delete every photo's external-storage sidecar.
    var photos: [DraftPhoto] = []
    /// Free-form note shown above the first step in detail / cook view.
    var prefaceNote: String = ""
    /// Free-form note shown below the last step.
    var epilogueNote: String = ""
    /// Free-form note not tied to a position — surfaces in detail view in a
    /// dedicated "Note" callout, separate from per-step reminders.
    var generalNote: String = ""

    var hasAnyContent: Bool {
        !title.trimmed.isEmpty ||
        !summary.trimmed.isEmpty ||
        !sourceUrl.trimmed.isEmpty ||
        !ingredients.isEmpty ||
        !steps.isEmpty ||
        !photos.isEmpty ||
        !prefaceNote.trimmed.isEmpty ||
        !epilogueNote.trimmed.isEmpty ||
        !generalNote.trimmed.isEmpty
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
    /// Up to 3 photo blobs attached to this step. Carried through the
    /// draft so the `RecipeStep` rebuild in `Recipe.apply(_:)` doesn't
    /// lose images on every save — the `photos` relationship is wiped
    /// and recreated each time, just like `ingredients` and `steps`
    /// themselves. Bytes flow Recipe -> toDraft -> editor -> apply ->
    /// Recipe. The 3-cap is enforced at the UI layer
    /// (`PhotoToggleButton`); apply also clamps defensively.
    var images: [Data] = []

    init(
        id: UUID = UUID(),
        text: String = "",
        needsTimer: Bool = false,
        specialNote: String? = nil,
        images: [Data] = []
    ) {
        self.id = id
        self.text = text
        self.needsTimer = needsTimer
        self.specialNote = specialNote
        self.images = images
    }
}

/// Editor-side mirror of `RecipePhoto`. Same shape as the persisted
/// model; carrying it as a separate struct keeps the editor decoupled
/// from SwiftData (the gallery sheet doesn't need a `ModelContext`)
/// and lets Cancel discard the in-progress add without touching disk.
struct DraftPhoto: Identifiable, Equatable {
    let id: UUID
    var image: Data?

    init(id: UUID = UUID(), image: Data? = nil) {
        self.id = id
        self.image = image
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
            steps: sortedSteps.map { step in
                // Migration: a step from a previous TestFlight build may
                // still have its bytes in the deprecated `RecipeStep.image`
                // single-image slot. When the new `photos` relationship is
                // empty but the legacy field has data, lift those bytes
                // into the draft so the next save rebuilds them as a
                // `RecipeStepPhoto` row instead of cascade-deleting the
                // sidecar via `steps.removeAll()`. After the user opens +
                // saves a recipe once, `step.image` ends up nil (no
                // writes target it), and SwiftData drops the orphan
                // sidecar. New paths (toDraft for fresh recipes) just
                // see the relationship and skip the migration branch.
                let relationshipBytes = step.sortedStepPhotos.compactMap(\.image)
                let images: [Data] = relationshipBytes.isEmpty
                    ? (step.image.map { [$0] } ?? [])
                    : relationshipBytes
                return DraftStep(
                    id: step.id,
                    text: step.text,
                    needsTimer: step.needsTimer,
                    specialNote: step.specialNote,
                    images: images
                )
            },
            photos: sortedPhotos.map {
                DraftPhoto(id: $0.id, image: $0.image)
            },
            prefaceNote: prefaceNote ?? "",
            epilogueNote: epilogueNote ?? "",
            generalNote: generalNote ?? ""
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
        prefaceNote = draft.prefaceNote.trimmed.nilIfEmpty
        epilogueNote = draft.epilogueNote.trimmed.nilIfEmpty
        generalNote = draft.generalNote.trimmed.nilIfEmpty
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
            // Carry up to 3 photo blobs through the draft into
            // RecipeStepPhoto rows on the new relationship. Same
            // bytes-through-the-draft pattern used for ingredients,
            // steps, and recipe-level photos — without it, every save
            // would silently delete every step photo's sidecar.
            for (photoIdx, bytes) in item.images.prefix(3).enumerated() {
                step.photos.append(RecipeStepPhoto(image: bytes, order: photoIdx))
            }
            steps.append(step)
        }

        // Photos. `removeAll()` cascade-deletes the external-storage
        // sidecars; we then rebuild from the draft, copying bytes back
        // in. Without this carry-through, every Save would silently
        // drop every photo. Drafts whose `image` ended up nil
        // (e.g. picker cancel mid-add) are filtered out so empty rows
        // don't persist as "has photo, but it's nothing".
        photos.removeAll()
        for (idx, item) in draft.photos.enumerated() where item.image != nil {
            photos.append(RecipePhoto(image: item.image, order: idx))
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
