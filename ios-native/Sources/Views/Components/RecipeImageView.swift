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
///
/// Performance: decoding is async. `init` does a synchronous cache
/// lookup (O(1) hash check) so already-decoded images (e.g. a card
/// thumbnail that scrolled into view before the navigation push) render
/// on the first frame with no flicker. Cache-miss images decode on a
/// background thread via `Task.detached`, keeping the main thread — and
/// the navigation push animation — unblocked.
struct RecipeImageView<Placeholder: View>: View {
    let data: Data?
    let contentMode: ContentMode
    /// Corner radius applied directly to the rendered `Image`. Because
    /// `.fit` content sizes the Image view to the photo's actual
    /// bounds, clipping at this level rounds the *photo edges* — not
    /// the surrounding letterbox space the parent frame might have.
    let cornerRadius: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var decoded: UIImage?

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
        // Warm the @State initial value from the cache synchronously so
        // the very first body eval renders the image immediately — no
        // placeholder flash — when the data was already decoded (e.g. the
        // card thumbnail in LibraryView decoded it before the push).
        if let data, let cached = imageCache.object(forKey: data as NSData) {
            _decoded = State(initialValue: cached)
        }
    }

    var body: some View {
        Group {
            if let decoded {
                Image(uiImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                placeholder()
            }
        }
        .task(id: data) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        guard let data else {
            decoded = nil
            return
        }
        let key = data as NSData
        // Fast path: already in cache (placed by the init warm-check or a
        // previous render of the same data at another call site).
        if let cached = imageCache.object(forKey: key) {
            decoded = cached
            return
        }
        // Clear any stale image from a previous data value before the
        // background decode completes — avoids showing the wrong photo
        // while the new one loads (e.g. after a recipe photo is replaced).
        decoded = nil
        // Slow path: decode HEIC/JPEG on a background thread so the main
        // thread — and any in-flight navigation push animation — stays
        // unblocked. Task.detached escapes the current actor; we await
        // the result back on @MainActor before writing to @State.
        let image = await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
        guard let image else { return }
        imageCache.setObject(image, forKey: key)
        decoded = image
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
