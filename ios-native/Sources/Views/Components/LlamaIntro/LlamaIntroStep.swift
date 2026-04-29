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
}
