import SwiftUI
import UIKit

/// Single rendering surface for every photo display in the app — gallery
/// thumbnails, gallery carousel page, step thumbnails in Detail, step
/// images full-width in Cook Mode. **One implementation, four callers.**
///
/// Behavior contract:
/// - `data == nil` → renders the `placeholder` closure verbatim.
/// - Decodable bytes → renders an `Image(uiImage:)` at the requested
///   `contentMode`. Caller is responsible for clipping / framing.
/// - Undecodable bytes (corrupt picker output, sidecar missing) → falls
///   back to the placeholder silently. Never crashes, never shows a
///   broken-image glyph — that would be a worse UX than "no photo".
///
/// Decoded UIImages flow through a module-scoped `NSCache` so swiping
/// back-and-forth in the carousel doesn't re-decode the same `Data`
/// repeatedly. The cache key is the data's hash; same bytes → same
/// cached image regardless of which call site asked.
struct RecipeImageView<Placeholder: View>: View {
    let data: Data?
    let contentMode: ContentMode
    /// Corner radius applied directly to the rendered `Image`. Because
    /// `.fit` content sizes the Image view to the photo's actual
    /// bounds, clipping at this level rounds the *photo edges* — not
    /// the surrounding letterbox space the parent frame might have.
    let cornerRadius: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder

    init(
        data: Data?,
        contentMode: ContentMode = .fill,
        cornerRadius: CGFloat = 0,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.data = data
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        self.placeholder = placeholder
    }

    var body: some View {
        if let data, let image = decode(data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            placeholder()
        }
    }

    /// Decode-with-cache. Cache miss → decode + insert + return.
    /// Decode failure → return nil so the caller paints the placeholder.
    private func decode(_ data: Data) -> UIImage? {
        let key = data as NSData
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }
}

/// Module-scoped cache shared across every `RecipeImageView`. NSCache
/// purges automatically under memory pressure, so no manual eviction
/// is wired. Capped at 60 images / 80 MB — plenty for a Detail view
/// scrolling its gallery while step images sit below.
private let imageCache: NSCache<NSData, UIImage> = {
    let cache = NSCache<NSData, UIImage>()
    cache.countLimit = 60
    cache.totalCostLimit = 80 * 1024 * 1024
    return cache
}()

/// Convenience overload for the common case: no placeholder needed,
/// caller wraps the view in an `if data != nil` block themselves.
extension RecipeImageView where Placeholder == EmptyView {
    init(data: Data?, contentMode: ContentMode = .fill, cornerRadius: CGFloat = 0) {
        self.init(data: data, contentMode: contentMode, cornerRadius: cornerRadius) {
            EmptyView()
        }
    }
}
