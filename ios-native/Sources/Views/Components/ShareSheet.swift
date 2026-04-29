import SwiftUI
import UIKit
import LinkPresentation

/// Programmatically-presentable iOS share sheet. SwiftUI's `ShareLink`
/// only presents in response to a tap on its own button — there's no
/// `.shareSheet(isPresented:)` modifier or programmatic-trigger API
/// as of iOS 18. The Recipe Detail share flow needs state-driven
/// presentation so the first-share name prompt (Recipe-Sharing.md
/// §7.4) can complete BEFORE the share sheet opens, so we wrap
/// `UIActivityViewController` here.
///
/// **Third deliberate UIKit exception** alongside the keyboard-tint
/// (`UIView.appearance().tintColor`) and PageControl dot-color
/// (`UIPageControl.appearance()`) proxies. Single-purpose, isolated
/// to this wrapper — every caller sees only a SwiftUI
/// `.sheet(isPresented:)` containing this view.
///
/// `onComplete` fires after the user dismisses the sheet (whether by
/// completing a share, cancelling, or backgrounding). Pass `true` to
/// the closure when an activity completed; callers use this to clean
/// up temp files (e.g. the `.llamarecipe` written under
/// `FileManager.temporaryDirectory`).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: ((Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, completed, _, _ in
            onComplete?(completed)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// `UIActivityItemSource` wrapper that brands the share-sheet preview
/// header (and the rich preview recipients see in Messages / Mail /
/// AirDrop) with the recipe title and the llama app logo. Without
/// this, sharing a custom-scheme URL like
/// `llamascookbook://share/USUL9G` renders a generic "Untitled"
/// placeholder because iOS's link-preview engine can't fetch metadata
/// from non-HTTP schemes — we provide `LPLinkMetadata` inline (iOS
/// 13+ rich-preview API) so the title and icon come from us.
///
/// Underlying payload (URL, file URL, or String — the three shapes
/// the existing share flow already produces) is returned unchanged
/// via the standard item-source methods, so AirDrop / Messages /
/// Mail / Copy / Files all keep their existing behavior. Only the
/// preview chrome changes.
final class RecipeShareActivityItem: NSObject, UIActivityItemSource {
    let payload: Any
    let recipeTitle: String

    init(payload: Any, recipeTitle: String) {
        self.payload = payload
        self.recipeTitle = recipeTitle
        super.init()
    }

    /// Rich preview metadata used for both the sender's share-sheet
    /// header AND as the per-activity item for rich-preview-aware
    /// activities (Messages, Mail, AirDrop) when the payload is a
    /// URL. Built lazily so we only construct it once per share.
    ///
    /// **Why this is the only lever for branding the recipient bubble
    /// for custom URL schemes:** Messages on the recipient's side
    /// normally fetches `LPLinkMetadata` from the URL host (Open Graph
    /// scrape) to render the rich-link bubble. For HTTP URLs that
    /// works automatically; for custom-scheme URLs like
    /// `llamascookbook://share/USUL9G` there's nothing to fetch, so
    /// Messages falls back to plain URL text. Returning this metadata
    /// inline as the activity item embeds it directly in the iMessage
    /// payload, which Messages on the recipient *can* render — though
    /// with caveats around Apple's anti-spoofing rules for
    /// non-Universal-Link URLs (some Messages versions still strip it).
    /// The guaranteed fix for recipient-side rich previews is
    /// Universal Links (HTTPS URLs that open into the app).
    private lazy var richMetadata: LPLinkMetadata = {
        let metadata = LPLinkMetadata()
        metadata.title = recipeTitle
        if let url = payload as? URL {
            metadata.originalURL = url
            metadata.url = url
        }
        // Uses `LlamaShareIcon` (a tightly-cropped variant matching the
        // 1024×1024 AppIcon) rather than `LlamaLogo`, which has
        // substantial transparent padding intended for in-app surfaces
        // where the logo sits inside a larger view. In the share-sheet
        // preview header iOS renders the icon into a fixed thumbnail
        // square, so the padded logo appeared visually small; the
        // app-icon-cropped version fills the thumbnail the way the
        // home-screen app icon does.
        if let icon = UIImage(named: "LlamaShareIcon") {
            // `iconProvider` drives the small thumbnail in the
            // share-sheet header; `imageProvider` drives the larger
            // preview image in the recipient's Messages bubble.
            // Same llama icon serves both surfaces.
            metadata.iconProvider = NSItemProvider(object: icon)
            metadata.imageProvider = NSItemProvider(object: icon)
        }
        return metadata
    }()

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        // Same type as the real payload so iOS picks the right
        // activities while resolving. The placeholder is shown
        // briefly during activity discovery; the real payload comes
        // back via `itemForActivityType` once the user picks one.
        payload
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        // ALWAYS return the raw payload — URL, file URL, or string.
        // Messages / Mail / etc. need the URL in the message body so
        // the recipient has something tappable; the rich preview
        // bubble is then generated by Messages itself fetching OG
        // tags from the (HTTPS) URL. Returning `LPLinkMetadata` here
        // instead of the URL would leave Messages with nothing to
        // insert into the body, producing an empty message — that's
        // a recurring pitfall and the comment is here so we don't
        // re-introduce it.
        payload
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        // Used by Mail (and similar subject-aware activities) as the
        // outgoing message subject.
        recipeTitle
    }

    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        // Drives the **sender's** share-sheet preview header (recipe
        // title + llama icon). Does NOT control the recipient's
        // bubble — that comes from Messages fetching OG tags from
        // the URL on its end.
        richMetadata
    }
}
