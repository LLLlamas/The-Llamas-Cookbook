import SwiftUI

/// Faint mascot watermark sitting behind a screen's primary content.
/// Sized to nearly fill the smaller dimension of its container and
/// centered in the available area so it reads as a page-wide emblem.
/// Opacity stays low enough that overlaid cards / sheets / text stay
/// legible.
///
/// Hit testing is disabled — the watermark is purely decorative, taps
/// pass through to whatever's beneath it.
///
/// Use as a background layer in a `ZStack`, or via the
/// `.llamaBackground()` View modifier (which combines the watermark
/// with `AppColor.background` for the standard cream-cream-llama
/// stack).
struct LlamaWatermark: View {
    /// Watermark opacity. Default `0.06` matches the LibraryView
    /// treatment that established the pattern. Bump up for screens
    /// with sparser content; drop down for screens packed with cards.
    var opacity: Double = 0.06

    /// Fraction of the smaller dimension the llama fills. Default
    /// 0.95 keeps the mascot inside the safe visible area on every
    /// iPhone width without clipping.
    var sizeFraction: CGFloat = 0.95

    var body: some View {
        GeometryReader { geo in
            let dim = min(geo.size.width, geo.size.height) * sizeFraction
            LlamaLogo(size: dim, shadowOpacity: 0)
                .opacity(opacity)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Standard llama-watermark background — cream `AppColor.background`
    /// with the faint mascot floating behind. Apply at the root of any
    /// screen that wants the brand watermark; safe to layer beneath
    /// existing content because the watermark disables hit testing.
    func llamaBackground(opacity: Double = 0.06) -> some View {
        self.background(
            ZStack {
                AppColor.background
                LlamaWatermark(opacity: opacity)
            }
            .ignoresSafeArea()
        )
    }
}
