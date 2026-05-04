import UIKit
import UniformTypeIdentifiers

/// Entry point for the Llamas Cookbook share extension. Runs in a
/// separate process from the main app, invoked when the user picks
/// "Llamas Cookbook" from another app's share sheet (Safari, Files,
/// Mail, Reddit, etc.).
///
/// **Architecture: transparent passthrough.** The extension does
/// minimal work — read the `NSItemProvider`, encode a handoff to the
/// main app, dismiss. The main app does the actual import via the
/// existing `RootView.onOpenURL` flow. No SwiftData in the extension,
/// no duplicated parsers, no UI beyond a brief cream-colored backdrop
/// while the handoff resolves. See Share-Extension-Plan.md §2 + §5.
///
/// Two handoff paths:
///
/// - **URLs** (Safari, Reddit, recipe-blog readers) → encode the URL
///   as base64url into `llamascookbook://share-url/<...>` and open
///   the main app via `extensionContext.open(_:)`. Main app routes
///   to the existing import-from-text sheet with the URL pre-filled.
/// - **`.llamarecipe` files** (from Files / Mail attachments) →
///   write bytes to the App Group shared container at
///   `share-inbox/<uuid>.llamarecipe`, hand off via
///   `llamascookbook://share-incoming/<uuid>`. Main app reads from
///   the shared container, decodes via `RecipeShare.decode(fileData:)`,
///   presents the Import Preview sheet.
final class ShareViewController: UIViewController {
    private static let llamaRecipeUTI = "com.llamascookbook.recipe"

    /// Hard cap on `.llamarecipe` bytes the extension will commit to
    /// the App Group inbox. Pulls the value from the shared
    /// `RecipeShareLimits` so the extension's pre-write cap and the
    /// main app's decode-time cap can never drift apart.
    private static let maxInboundBytes = RecipeShareLimits.maxInboundBytes

    override func viewDidLoad() {
        super.viewDidLoad()
        // Cream backdrop matches the main app's chrome so the brief
        // flash before the main app takes over doesn't read as
        // broken. ~250–400ms of this view, then the main app fades
        // in.
        view.backgroundColor = UIColor(red: 1.00, green: 0.97, blue: 0.92, alpha: 1)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await processInput() }
    }

    private func processInput() async {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachment = item.attachments?.first
        else {
            await complete()
            return
        }

        // Custom UTI is more specific — check first so a `.llamarecipe`
        // (which conforms to public.json + public.data) never falls
        // through to the URL branch.
        if attachment.hasItemConformingToTypeIdentifier(Self.llamaRecipeUTI) {
            await handleLlamaRecipeFile(attachment)
        } else if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            await handleURL(attachment)
        } else {
            await complete()
        }
    }

    // MARK: handlers

    private func handleURL(_ attachment: NSItemProvider) async {
        do {
            let raw = try await attachment.loadItem(forTypeIdentifier: UTType.url.identifier)
            guard let url = raw as? URL else {
                await complete(); return
            }
            let encoded = Data(url.absoluteString.utf8).base64URLEncodedString()
            guard let deepLink = URL(string: "llamascookbook://share-url/\(encoded)") else {
                await complete(); return
            }
            await openMainApp(with: deepLink)
        } catch {
            await complete()
        }
    }

    private func handleLlamaRecipeFile(_ attachment: NSItemProvider) async {
        do {
            let raw = try await attachment.loadItem(forTypeIdentifier: Self.llamaRecipeUTI)
            let data: Data
            if let url = raw as? URL {
                // Stat-check before reading. A hostile 500 MB
                // attachment from another app would otherwise be fully
                // read into the extension's memory before we even know
                // its size. Memory pressure in an extension causes
                // jetsam-kill before the main app handoff lands.
                let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                if let size = attrs[.size] as? Int, size > Self.maxInboundBytes {
                    await complete(); return
                }
                data = try Data(contentsOf: url)
            } else if let direct = raw as? Data {
                data = direct
            } else {
                await complete(); return
            }
            // Belt-and-suspenders: in-memory `Data` path (no URL stat
            // available) is also checked before write.
            guard data.count <= Self.maxInboundBytes else {
                await complete(); return
            }

            let id = UUID().uuidString
            let inbox = SharedContainer.shareInboxURL()
            try? FileManager.default.createDirectory(
                at: inbox,
                withIntermediateDirectories: true
            )
            let fileURL = inbox.appendingPathComponent("\(id).llamarecipe")
            try data.write(to: fileURL)

            guard let deepLink = URL(string: "llamascookbook://share-incoming/\(id)") else {
                await complete(); return
            }
            await openMainApp(with: deepLink)
        } catch {
            await complete()
        }
    }

    @MainActor
    private func openMainApp(with url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // `extensionContext.open(_:)` is the documented API for a
            // share extension to launch its containing app. Returns
            // false on iOS in some edge cases; we complete the
            // request regardless so the share UI dismisses cleanly.
            extensionContext?.open(url) { _ in
                self.extensionContext?.completeRequest(
                    returningItems: nil,
                    completionHandler: nil
                )
                cont.resume()
            }
        }
    }

    @MainActor
    private func complete() async {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
