import Foundation

extension Optional where Wrapped == String {
    /// Trimmed value when non-empty, `nil` otherwise. Collapses
    /// whitespace-only and missing strings to a single `nil` case so
    /// callers can `if let` on "has real content."
    var trimmedIfNonEmpty: String? {
        flatMap { s in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }
}
