import SwiftUI

/// Horizontal shake driven by a counter — flip `trigger` to play one shake.
/// Each increment runs a single ~0.4s shake sequence.
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    var amount: CGFloat = 8
    var shakesPerUnit: CGFloat = 4

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = amount * sin(animatableData * .pi * shakesPerUnit)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

extension View {
    /// Drive `count` upward (e.g. `count += 1`) to play one shake.
    func shake(count: CGFloat) -> some View {
        modifier(ShakeEffect(animatableData: count))
            .animation(.linear(duration: 0.42), value: count)
    }
}
