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
        sweepStaleShareInboxMarkers(olderThan: maxAge)
    }

    // MARK: - Share-inbox provenance markers

    /// Per-handoff sentinel store. Defense-in-depth so the main app
    /// can verify that a `share-incoming/<uuid>` deep link refers to
    /// a UUID this team's own share extension actually issued — not
    /// (for instance) a future second extension that also writes to
    /// the same App Group container, or any other code path that
    /// drops a UUID-named file in `share-inbox/`. The App Group
    /// itself gates filesystem access (only this team's signed
    /// targets can write here), but pinning the contract explicitly
    /// keeps a future "another extension parks data in the inbox
    /// shape" change from silently triggering an import.
    ///
    /// Format: a single dictionary in the shared `UserDefaults` suite
    /// keyed by `markersKey`, mapping `uuid (String) -> issuedAt (Double,
    /// secondsSince1970)`. We use one parent key (rather than a
    /// separate UserDefaults entry per UUID) so the GC sweep below
    /// can mutate it atomically.
    private static let markersKey = "shareInbox.issuedMarkers.v1"

    private static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Called by the share extension immediately before / after
    /// writing the file. Marks the UUID as one we issued so the
    /// main app's `routeShareExtensionFile` can verify provenance
    /// before reading the file.
    static func markShareInboxIssued(uuid: String) {
        guard let defaults = sharedDefaults() else { return }
        var map = (defaults.dictionary(forKey: markersKey) as? [String: Double]) ?? [:]
        map[uuid] = Date().timeIntervalSince1970
        defaults.set(map, forKey: markersKey)
    }

    /// Called by the main app after consuming a share handoff. Returns
    /// `true` if the UUID was present (proving our own extension
    /// issued it) and removes it; returns `false` if the UUID was
    /// never marked. The boolean lets the caller decide whether to
    /// trust the file. Markers from a previous app version that pre-
    /// dates this check are absent, so existing in-flight handoffs
    /// during the upgrade window degrade to "treat as foreign" — a
    /// one-time edge case bounded by the 24-hour sweep.
    @discardableResult
    static func consumeShareInboxMarker(uuid: String) -> Bool {
        guard let defaults = sharedDefaults() else { return false }
        var map = (defaults.dictionary(forKey: markersKey) as? [String: Double]) ?? [:]
        let present = map.removeValue(forKey: uuid) != nil
        defaults.set(map, forKey: markersKey)
        return present
    }

    /// Drop markers older than `maxAge`. Pairs with the file sweep
    /// above so a stale marker can't survive forever after its file
    /// gets pruned (e.g. user invoked the extension, never opened the
    /// app, then 25 hours later opened the app — the file is GC'd by
    /// the file sweep, the marker by this one).
    private static func sweepStaleShareInboxMarkers(olderThan maxAge: TimeInterval) {
        guard let defaults = sharedDefaults() else { return }
        guard let map = defaults.dictionary(forKey: markersKey) as? [String: Double] else { return }
        let cutoff = Date().addingTimeInterval(-maxAge).timeIntervalSince1970
        let trimmed = map.filter { $0.value >= cutoff }
        if trimmed.count != map.count {
            defaults.set(trimmed, forKey: markersKey)
        }
    }
}
