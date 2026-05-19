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
    /// (topmost) visible row. Internal tracking value only — used to
    /// dedupe reports. NOT the magnify-pulse channel: it changes on the
    /// first report (`nil → "A"`), which would flash a stray pulse on
    /// every list appearance. Observers wanting the pulse must use
    /// `magnifyLetter` instead.
    @ObservationIgnored private var currentSection: String?
    /// Letter the right-side `LetterIndex` strip should magnify on a
    /// free-scroll crossing — the visual counterpart of the haptic tick.
    /// Assigned ONLY on a real boundary crossing, in lockstep with
    /// `Haptics.selection()` (after the first-report early-return), so it
    /// never fires on the initial settle. `nil` until the first crossing
    /// and after `reset()`. Mutated at most once per crossing, so
    /// observing it costs nothing per frame.
    private(set) var magnifyLetter: String?
    /// Suppresses the very first tick — entering the list shouldn't
    /// fire a haptic, only *crossing* a boundary should.
    @ObservationIgnored private var hasReported = false

    /// Reports that `section` is now the leading visible section.
    /// Fires the scrubber tick (and the matching `magnifyLetter` pulse)
    /// when it differs from the last value. Cheap and idempotent — safe
    /// to call from `onScrollVisibilityChange`.
    @MainActor
    func report(section: String) {
        guard section != currentSection else { return }
        let isFirst = !hasReported
        currentSection = section
        hasReported = true
        // No tick/pulse on initial settle — only on an actual crossing.
        guard !isFirst else { return }
        magnifyLetter = section
        Haptics.selection()
    }

    /// Resets the ticker — call when the list's contents change wholesale
    /// (e.g. a filter switch) so a re-entry doesn't fire a stray tick.
    @MainActor
    func reset() {
        currentSection = nil
        magnifyLetter = nil
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
