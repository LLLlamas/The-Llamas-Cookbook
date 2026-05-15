import SwiftUI

/// The brand llama, swapped for its crowned Pro variant when the user
/// has Llama Pro. Monthly Pro shows the crown; Yearly Pro shows the
/// crown-and-sunglasses variant. Plain state delegates to `LlamaLogo`.
///
/// Shadow radius and y-offset scale with `size` so the shadow reads
/// the same at any logo size.
struct LlamaLogoOrCrown: View {
    let size: CGFloat
    var accent: Color
    var crownAsset: String       = "Llama-Pro-Icon-Crown"
    var yearlyCrownAsset: String = "Llama-Pro-Icon-Crown-Sunglasses"

    @Environment(LlamaProStore.self) private var proStore

    var body: some View {
        if proStore.isPro {
            let asset = proStore.plan == .yearly ? yearlyCrownAsset : crownAsset
            Image(asset)
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
