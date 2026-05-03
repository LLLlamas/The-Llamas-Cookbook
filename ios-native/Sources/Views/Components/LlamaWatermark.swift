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

    /// Optional asset override. When nil (default) the watermark
    /// renders the brand `LlamaLogo` — body color baked into the
    /// bitmap, accent only drives the (suppressed) drop shadow.
    /// When set, the named asset is rendered as a template image
    /// tinted in `tint`, so screens with their own mascot variant
    /// (e.g. Friends tab using `Friends_Llama_Icon_Large`) can
    /// substitute artwork without forking the watermark stack.
    var assetName: String? = nil

    /// Tint applied to `assetName` when overriding. Ignored when
    /// `assetName` is nil. Pass the user's resolved accent so the
    /// watermark tracks the live color picker, matching how the
    /// home llama's halo tracks accent on the empty state.
    var tint: Color = AppColor.accent

    var body: some View {
        GeometryReader { geo in
            let dim = min(geo.size.width, geo.size.height) * sizeFraction
            Group {
                if let assetName {
                    Image(assetName)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: dim, height: dim)
                        .foregroundStyle(tint)
                } else {
                    LlamaLogo(size: dim, shadowOpacity: 0)
                }
            }
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
    ///
    /// Forces the modified view to expand to its container's bounds via
    /// `frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)`
    /// before painting the background — without this, a short
    /// content view (e.g. AddFriendSheet's VStack of search field +
    /// hint, ~100pt tall) would only paint cream behind that strip
    /// and the rest of the sheet would fall through to the system
    /// background.
    func llamaBackground(opacity: Double = 0.06) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                ZStack {
                    AppColor.background
                    LlamaWatermark(opacity: opacity)
                }
                .ignoresSafeArea()
            )
    }

    /// Variant of `llamaBackground()` that swaps the brand llama
    /// for a named template asset tinted in `tint`. Use on screens
    /// that have their own mascot artwork (e.g. Friends tab) so
    /// the watermark stays consistent in chrome (cream surface,
    /// faint opacity, full-bleed) but reads as the screen's own
    /// emblem.
    func llamaBackground(
        asset: String,
        tint: Color,
        opacity: Double = 0.06
    ) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                ZStack {
                    AppColor.background
                    LlamaWatermark(opacity: opacity, assetName: asset, tint: tint)
                }
                .ignoresSafeArea()
            )
    }
}
