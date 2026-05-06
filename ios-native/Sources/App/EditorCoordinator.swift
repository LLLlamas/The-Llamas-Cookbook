import Foundation
import SwiftUI

/// App-level state for the "there is an editor / import panel currently
/// open" sheet. Lives at RootView (above the NavigationStack) so the
/// sheet survives navigation — user can minimize the editor, browse
/// Library, peek at a different recipe's Detail view, and then pull the
/// editor back up without losing their draft.
///
/// Sibling to `CookingSession`, same pattern.
@Observable
final class EditorCoordinator {
    /// The sheet currently on screen (nil = no editor sheet).
    /// Written only through `attemptSwitch` / `end` so the unsaved-changes
    /// guard can gate every transition in one place.
    private(set) var active: ActiveSheet?

    /// Whatever sheet the user wanted to switch to while the current one
    /// has unsaved changes. RootView shows a discard alert while this is
    /// non-nil. `confirmDiscard` commits the swap; `cancelDiscard` drops it.
    private(set) var pendingSwitch: ActiveSheet?

    /// Fed from the active sheet content (RecipeEditorView /
    /// ImportFromTextLinkView / ImportFromPhotoView)
    /// via onAppear / onChange / onDisappear. When false, switches happen
    /// immediately; when true, they get queued behind a discard alert.
    var hasUnsavedChanges: Bool = false

    enum ActiveSheet: Identifiable, Hashable {
        /// New / blank recipe editor. Optional `seed` carries a
        /// pre-filled `DraftRecipe` for the photo-import "Edit"
        /// hand-off — user taps Edit on the OCR preview, gets the
        /// regular editor opened with every parsed field already in
        /// place. Identity / equality ignores the seed so a switch
        /// from FAB-no-seed to photo-handoff-with-seed doesn't trip
        /// the dirty-state discard alert.
        case new(seed: DraftRecipe? = nil)
        case edit(Recipe)
        /// Merged text-paste + URL-fetch import sheet. Both inputs
        /// live on one screen — `seedText` carries OCR fallback
        /// text into the paste area, `prefilledURL` carries the
        /// share-extension URL handoff into the URL field. Identity /
        /// equality ignores both seeds so switching between FAB,
        /// photo-handoff, and share-extension entries doesn't trip
        /// the dirty-state discard alert.
        case importFromTextLink(seedText: String? = nil, prefilledURL: String? = nil)
        /// Photo import sheet. Camera + library picker live inside
        /// the sheet; on success the OCR'd draft surfaces in a
        /// separate read-only preview view (modeled on the share-
        /// recipient preview).
        case importFromPhoto

        var id: String {
            switch self {
            case .new:                  return "new"
            case .edit(let recipe):     return "edit-\(recipe.id.uuidString)"
            case .importFromTextLink:   return "import-text-link"
            case .importFromPhoto:      return "import-photo"
            }
        }

        static func == (lhs: ActiveSheet, rhs: ActiveSheet) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    func startNew(seed: DraftRecipe? = nil) {
        attemptSwitch(to: .new(seed: seed))
    }
    func startEdit(_ recipe: Recipe) { attemptSwitch(to: .edit(recipe)) }
    func startImportFromText(seedText: String? = nil) {
        attemptSwitch(to: .importFromTextLink(seedText: seedText, prefilledURL: nil))
    }
    func startImportFromLink(url: String? = nil) {
        attemptSwitch(to: .importFromTextLink(seedText: nil, prefilledURL: url))
    }
    func startImportFromTextLink(seedText: String? = nil, url: String? = nil) {
        attemptSwitch(to: .importFromTextLink(seedText: seedText, prefilledURL: url))
    }
    func startImportFromPhoto() {
        attemptSwitch(to: .importFromPhoto)
    }

    /// Explicit close (after Save or Cancel-with-no-changes). Skips the
    /// dirty check because the caller has already decided to discard.
    func end() {
        hasUnsavedChanges = false
        active = nil
        pendingSwitch = nil
    }

    private func attemptSwitch(to new: ActiveSheet) {
        // Nothing open — just show.
        guard let current = active else {
            active = new
            return
        }
        // Same target — no-op (e.g. tapping Edit on the recipe already being edited).
        if current == new { return }
        // Current sheet is clean — swap directly.
        if !hasUnsavedChanges {
            active = new
            return
        }
        // Dirty — queue the target and let RootView's alert ask the user.
        pendingSwitch = new
    }

    func confirmDiscard() {
        if let next = pendingSwitch {
            hasUnsavedChanges = false
            active = next
        }
        pendingSwitch = nil
    }

    func cancelDiscard() {
        pendingSwitch = nil
    }
}
