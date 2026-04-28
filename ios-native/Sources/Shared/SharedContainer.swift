import Foundation

/// App Group shared container access. Lives under `Sources/Shared/`
/// so both the main app and the share extension can use it; both
/// targets carry the matching `com.apple.security.application-groups`
/// entitlement (`group.com.llamascookbook.app`).
///
/// Used by:
/// - **Share Extension** (sender side) — writes incoming
///   `.llamarecipe` bytes to `share-inbox/<uuid>.llamarecipe` because
///   the URL transport can't fit photo'd payloads. The extension
///   then deep-links the main app with
///   `llamascookbook://share-incoming/<uuid>`.
/// - **Main app** (receiver side) — reads the file from the same
///   path inside `RootView.routeShareIncoming`, decodes via
///   `RecipeShare.decode(fileData:)`, presents the Import Preview,
///   and deletes the file once it's loaded into memory.
/// - **Main app launch** — `sweepShareInbox` deletes any orphaned
///   files older than 24 hours (e.g. user invoked the extension but
///   never opened the main app, or the main app crashed mid-import).
enum SharedContainer {
    /// Must match the `com.apple.security.application-groups` value
    /// in BOTH `Resources/LlamasCookbook.entitlements` and
    /// `ShareExtension/LlamasCookbookShareExtension.entitlements`,
    /// AND the Apple Developer Portal App Group identifier. Three
    /// strings, three places — keep them in sync.
    static let appGroupID = "group.com.llamascookbook.app"

    /// Returns nil if the App Group entitlement isn't present in the
    /// current process — usually means the share extension's
    /// provisioning profile didn't carry the entitlement (Apple
    /// Developer Portal misconfig). Caller should fail the share
    /// gracefully rather than crashing.
    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Where the share extension parks `.llamarecipe` files for the
    /// main app to pick up. Falls back to the process's temporary
    /// directory if the App Group entitlement is missing — ensures
    /// the extension doesn't crash in an unsigned-build / dev
    /// scenario, but in that case the main app won't find the file
    /// (different process, different tmp).
    static func shareInboxURL() -> URL {
        let base = containerURL() ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("share-inbox", isDirectory: true)
    }

    /// Best-effort sweep of stale `.llamarecipe` files in the share
    /// inbox. Called from the main app on launch. Files older than
    /// `maxAge` (default 24 hours) get deleted. Mirrors how iOS
    /// itself manages temp directories — best-effort cleanup, never
    /// load-bearing. If the inbox doesn't exist or the entitlement is
    /// missing, the function silently no-ops.
    static func sweepShareInbox(olderThan maxAge: TimeInterval = 24 * 60 * 60) {
        guard let inbox = containerURL()?.appendingPathComponent("share-inbox", isDirectory: true)
        else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for entry in entries {
            if let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               date < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }
}
