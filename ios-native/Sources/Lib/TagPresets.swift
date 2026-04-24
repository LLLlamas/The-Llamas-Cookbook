import Foundation

/// Canonical set of cooking tags we surface as one-tap chips in the
/// editor. Stored lowercase (matching how `TagInputView.commit` writes
/// any custom tag); rendered via `StringCase.titleCase` for display.
/// Keep this list stable and short — the point is quick tagging, not
/// an exhaustive taxonomy.
enum TagPresets {
    static let all: [String] = [
        "dessert",
        "dinner",
        "bread",
        "baking",
        "breakfast",
    ]
}
