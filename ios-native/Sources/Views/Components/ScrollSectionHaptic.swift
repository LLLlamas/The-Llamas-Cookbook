import SwiftUI

/// Fires the letter-scrubber tick (`Haptics.selection()`) as the user
/// free-scrolls a cookbook list across section boundaries — so dragging
/// the list feels identical to dragging the right-side `LetterIndex`
/// strip, which already ticks once per letter-section.
///
/// **Granularity.** One tick per section-letter boundary crossed,
/// matching `LetterIndex`. Rows that share a section letter (e.g. three
/// recipes starting with "B") are crossed silently; the tick fires only
/// when the topmost visible row's section letter changes.
///
/// **Performance.** Each row reports its section via
/// `onScrollVisibilityChange`, which SwiftUI evaluates in the scroll
/// pass — no per-frame `body` invalidation, no timers. The shared
/// `ScrollSectionTicker` dedupes by section key, so the haptic
/// generator is touched at most once per boundary, never per frame.
///
/// **Usage.** Create one `ScrollSectionTicker` per list with `@State`,
/// then apply `.scrollSectionHaptic(section:ticker:)` to each row
/// inside the `LazyVStack`, passing that row's section letter.
///
/// **Horizontal strips.** The same modifier works unchanged for a
/// horizontal scroller (e.g. the category-chip filter strip):
/// `onScrollVisibilityChange(threshold:0.95)` reports when a chip
/// becomes substantially visible at the leading edge, so each chip
/// crossing the strip's leading edge fires one tick. Give the strip
/// its OWN `ScrollSectionTicker` — never share with the recipe-list
/// ticker, or moving focus between strip and list would mis-tick.
@Observable
final class ScrollSectionTicker {
    /// Section key of the row most recently reported as the leading
    /// (topmost) visible row. `nil` until the first report.
    @ObservationIgnored private var currentSection: String?
    /// Suppresses the very first tick — entering the list shouldn't
    /// fire a haptic, only *crossing* a boundary should.
    @ObservationIgnored private var hasReported = false

    /// Reports that `section` is now the leading visible section.
    /// Fires the scrubber tick when it differs from the last value.
    /// Cheap and idempotent — safe to call from `onScrollVisibilityChange`.
    @MainActor
    func report(section: String) {
        guard section != currentSection else { return }
        let isFirst = !hasReported
        currentSection = section
        hasReported = true
        // No tick on initial settle — only on an actual crossing.
        guard !isFirst else { return }
        Haptics.selection()
    }

    /// Resets the ticker — call when the list's contents change wholesale
    /// (e.g. a filter switch) so a re-entry doesn't fire a stray tick.
    @MainActor
    func reset() {
        currentSection = nil
        hasReported = false
    }
}

extension View {
    /// Marks a list row as belonging to `section` for scroll-haptic
    /// purposes. When the row becomes the topmost visible row, it
    /// reports its section to `ticker`, which fires the scrubber tick
    /// on a section change. Apply to each row inside the list's
    /// `LazyVStack`. See `ScrollSectionTicker` for the full contract.
    func scrollSectionHaptic(section: String, ticker: ScrollSectionTicker) -> some View {
        // `threshold: 0.95` ≈ "the row's top edge is at the viewport
        // top" — the moment it becomes the leading row. Reporting on
        // the *becoming-visible* edge keeps the tick aligned with the
        // boundary crossing rather than firing mid-row.
        onScrollVisibilityChange(threshold: 0.95) { isVisible in
            if isVisible {
                ticker.report(section: section)
            }
        }
    }
}
