import SwiftUI

extension View {
    /// Continuous scroll-focus zoom for card lists: the card nearest the
    /// scroll view's vertical center renders at full scale / full
    /// opacity, cards above and below taper to 0.96 scale with a faint
    /// opacity dim. `.interactive` updates per-frame as the user drags.
    func cardScrollTransition() -> some View {
        scrollTransition(.interactive, axis: .vertical) { content, phase in
            content
                .scaleEffect(1.0 - 0.04 * abs(phase.value))
                .opacity(1.0 - 0.08 * abs(phase.value))
        }
    }
}
