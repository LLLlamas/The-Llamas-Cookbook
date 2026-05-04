import Foundation

/// One coach-mark step in a tour. The overlay walks the array and
/// renders the highlight + bubble for the current index.
struct LlamaIntroStep: Identifiable, Equatable {
    /// Position in the parent tour (1-indexed for human reading;
    /// `Int` rather than `UUID` so step dots can render quickly).
    let id: Int
    /// Field to spotlight. `nil` centers the bubble with no cutout —
    /// reserved for future "screen summary" beats; not used in v1.
    let target: LlamaTourTarget?
    /// One-line headline above the body copy. Serif heading face.
    let headline: String
    /// Short explainer below the headline. Rendered with
    /// `lineLimit(8)` to keep the bubble bounded at large
    /// Dynamic Type sizes.
    let body: String
    /// True for the first step of each tour — triggers the wave
    /// animation on the llama after the initial fade-in.
    let waveOnEnter: Bool
    /// Additional fields to include in the highlight halo. The
    /// overlay unions `target`'s rect with each of these to compute
    /// a single bounding cutout — used when one walkthrough beat
    /// covers two adjacent fields (e.g. servings + prep time, or
    /// the steps editor + the special-notes block below it).
    /// Resolved targets that aren't laid out yet are silently
    /// skipped so a missing optional field doesn't break the step.
    let extraTargets: [LlamaTourTarget]

    init(
        id: Int,
        target: LlamaTourTarget?,
        headline: String,
        body: String,
        waveOnEnter: Bool,
        extraTargets: [LlamaTourTarget] = []
    ) {
        self.id = id
        self.target = target
        self.headline = headline
        self.body = body
        self.waveOnEnter = waveOnEnter
        self.extraTargets = extraTargets
    }
}
