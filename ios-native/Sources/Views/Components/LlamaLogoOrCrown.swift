import SwiftUI

/// The brand llama, swapped for its crowned Pro variant when the user
/// has Llama Pro. Plain state delegates to `LlamaLogo`; the Pro state
/// renders the crown asset with a proportional accent drop shadow
/// (radius and y-offset scale with `size` so the shadow reads the same
/// at any logo size).
///
/// `crownAsset` defaults to the picker-surface crown — the Profile
/// header passes its own `Llama-Pro-Icon-Profile-Crown` variant.
struct LlamaLogoOrCrown: View {
    let size: CGFloat
    var accent: Color
    var crownAsset: String = "Llama-Pro-Icon-Crown"

    @Environment(LlamaProStore.self) private var proStore

    var body: some View {
        if proStore.isPro {
            Image(crownAsset)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .shadow(
                    color: accent.opacity(0.45),
                    radius: size * 0.0643,
                    x: 0,
                    y: size * 0.05
                )
                .accessibilityHidden(true)
        } else {
            LlamaLogo(size: size, shadowColor: accent)
        }
    }
}
