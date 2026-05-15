import SwiftUI

extension View {
    /// Adds a static drop-shadow that makes non-interactive cards appear elevated.
    func liftedCard() -> some View {
        self.shadow(color: .black.opacity(0.13), radius: 6, x: 0, y: 3)
    }
}

struct LiftedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .shadow(
                color: .black.opacity(configuration.isPressed ? 0.06 : 0.13),
                radius: configuration.isPressed ? 2 : 6,
                x: 0,
                y: configuration.isPressed ? 1 : 3
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == LiftedButtonStyle {
    static var lifted: LiftedButtonStyle { LiftedButtonStyle() }
}

/// Scale-only press feedback with no drop shadow. Use for filter chips
/// and other small pill buttons where a shadow would create a halo effect
/// around the pill stroke.
struct ScaleOnlyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ScaleOnlyButtonStyle {
    static var scaleOnly: ScaleOnlyButtonStyle { ScaleOnlyButtonStyle() }
}
