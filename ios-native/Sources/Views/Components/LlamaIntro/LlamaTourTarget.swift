import SwiftUI

/// Stable identifier for every field a tour can highlight. Each host
/// view tags its field with `.tourTarget(.foo)`; the overlay reads the
/// merged anchor preferences and resolves the current step's target
/// to a `CGRect` in screen space via `GeometryProxy`.
///
/// The same value also drives `proxy.scrollTo(_:)` for steps that
/// live below the fold — `tourTarget(_:)` applies `.id(...)` alongside
/// the anchor preference so a single identifier covers both jobs.
enum LlamaTourTarget: Hashable {
    // Editor (new-recipe) tour
    case editorHero
    case titleField
    case summaryField
    case servingsField
    case prepTimeField
    case photosButton
    case categoriesHeader
    case ingredientQuickAdd
    case stepQuickAdd
    case specialNotesEditor
    case saveButton

    // Text-import tour
    case textImportHero
    case formatHint
    case pasteEditor
    case previewButton
    case textImportHelpIcon

    // Link-import tour
    case linkImportHero
    case urlField
    case fetchButton
    case linkImportHelpIcon
}

struct LlamaTourTargetKey: PreferenceKey {
    static let defaultValue: [LlamaTourTarget: Anchor<CGRect>] = [:]
    static func reduce(
        value: inout [LlamaTourTarget: Anchor<CGRect>],
        nextValue: () -> [LlamaTourTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Tag this view as a tour-highlightable field. Captures the
    /// view's bounds via `anchorPreference` (so the overlay can punch
    /// a cutout around it) and applies `.id(id)` so a host's
    /// `ScrollViewReader` can scroll the field into view via
    /// `proxy.scrollTo(id, anchor: .center)`.
    func tourTarget(_ id: LlamaTourTarget) -> some View {
        anchorPreference(key: LlamaTourTargetKey.self, value: .bounds) {
            [id: $0]
        }
        .id(id)
    }
}
