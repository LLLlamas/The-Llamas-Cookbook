import Foundation

/// URL-safe base64 helpers (RFC 4648 §5). Lives under `Sources/Shared/`
/// so both the main app target and the share extension target can
/// pull them in without pulling SwiftData / `Recipe` types along.
///
/// Used by:
/// - `RecipeShare.encodeURL` / `decode(url:)` — the
///   `llamascookbook://recipe/v1/<base64url>` deep-link transport
///   (PR 1 / PR 2 of recipe sharing).
/// - `ShareExtension/ShareViewController.handleURL(_:)` — encodes a
///   shared web URL into `llamascookbook://share-url/<base64url>`
///   for handoff to the main app (PR 4).
///
/// Why URL-safe: Foundation's standard base64 emits `+`, `/`, and
/// `=` padding. `+` gets URL-encoded to `%2B` by some chat apps and
/// passes through unchanged on others; `/` is a path separator;
/// `=` is sometimes stripped. Swapping `+/` for `-_` and dropping
/// `=` produces output that survives copy-paste through Messages,
/// Notes, Mail, Slack, and arbitrary clipboards without mangling.
extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Inverse of `base64URLEncodedString()`. Re-pads to a multiple
    /// of 4 before decoding — Foundation's base64 decoder requires
    /// padding even though the URL-safe alphabet drops it.
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let mod = s.count % 4
        if mod > 0 { s.append(String(repeating: "=", count: 4 - mod)) }
        self.init(base64Encoded: s)
    }
}
