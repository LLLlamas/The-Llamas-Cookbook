import SwiftUI

/// Brand llama logo, rendered from the `LlamaLogo` asset (`.imageset`
/// shipped under `Resources/Assets.xcassets/`).
///
/// Drop shadow contract — mirrors the design system's SVG export, where
/// the shadow color is driven by a `--llama-shadow` CSS custom property
/// so the user's color picker can swap it live without re-rendering the
/// artwork. In SwiftUI we do the same with a parameter: pass the user's
/// picked accent (`appearance.accentColor`) and the logo's halo tracks
/// the live color picker. Default falls back to `AppColor.accent` for
/// previews and contexts that don't have `AppearanceSettings` in scope.
///
/// Replaces the old hand-drawn `LlamaMascot` Canvas at every call site
/// — the body color is baked into the bitmap artwork, only the shadow
/// is tintable.
struct LlamaLogo: View {
    /// Edge length in points. The artwork is square; both width and
    /// height frame to this value.
    var size: CGFloat = 120

    /// Drop-shadow tint. Mirrors the SVG export's `--llama-shadow`
    /// CSS variable. Pass the user's picked accent (typically
    /// `appearance.accentColor`) so the halo tracks the live color
    /// picker.
    var shadowColor: Color = AppColor.accent

    /// Opacity applied to `shadowColor` before the shadow renders.
    /// Default `0.45` matches the SVG export's `rgba(…, 0.45)`. Drop
    /// to a lower value for faint-watermark uses where the whole
    /// logo is rendered at reduced opacity.
    var shadowOpacity: Double = 0.45

    var body: some View {
        Image("LlamaLogo")
            .resizable()
            // High-quality downscaling so the logo stays crisp in
            // the small toolbar slot (~28–44pt) while still rendering
            // nicely at watermark size (~300pt). Without this, iOS
            // defaults to `.medium` which can soften small renders.
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            // Proportional shadow — radius and y-offset scale with
            // logo size so a 32pt toolbar logo gets a 2pt-ish halo
            // and a 300pt watermark gets a much larger one. Numbers
            // come from the SVG export's `drop-shadow(0 14px 18px …)`
            // applied at the 280pt native viewBox: radius 18/280 ≈
            // 0.0643, y 14/280 = 0.05.
            .shadow(
                color: shadowColor.opacity(shadowOpacity),
                radius: size * 0.0643,
                x: 0,
                y: size * 0.05
            )
            .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 32) {
        LlamaLogo(size: 140)
        LlamaLogo(size: 64, shadowColor: .purple)
        LlamaLogo(size: 32)
    }
    .padding()
    .background(AppColor.background)
}
