import Foundation

/// Shared formatter instances. `DateFormatter` allocation is expensive
/// (~hundreds of microseconds); rendering code must reuse these rather
/// than constructing a fresh formatter per call.
enum Formatters {
    /// Medium-style date with no time component, e.g. "May 4, 2026".
    /// The single date-display format across the app.
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// Short month+day, e.g. "Jun 1". Used for quota reset dates in ImportFromPhotoView.
    static let shortMonthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}
