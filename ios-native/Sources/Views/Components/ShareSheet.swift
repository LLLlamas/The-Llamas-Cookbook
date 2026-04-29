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
        let metadata = LPLinkMetadata()
        metadata.title = recipeTitle
        if let url = payload as? URL {
            metadata.originalURL = url
            metadata.url = url
        }
        if let icon = UIImage(named: "LlamaLogo") {
            metadata.iconProvider = NSItemProvider(object: icon)
        }
        return metadata
    }
}
