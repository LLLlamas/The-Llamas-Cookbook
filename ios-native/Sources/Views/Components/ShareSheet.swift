import SwiftUI
import UIKit

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
