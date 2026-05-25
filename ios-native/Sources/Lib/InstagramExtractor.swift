import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Pulls recipe content out of a public Instagram reel/post URL using
/// only what Instagram serves to any unauthenticated visitor — no API
/// key, no third-party scraper, no signed-in account.
///
/// Three-stage strategy (best to worst, fall through on each miss):
///
///   1. **Inline JSON** — when present, IG embeds a JSON blob with the
///      full caption text in `<script type="application/json">` or
///      `application/ld+json` blocks. Best case, no transcription
///      needed. Schema is volatile (changes every few months) so this
///      is best-effort.
///   2. **OpenGraph meta tags** — always present (IG can't break them
///      without breaking link previews everywhere). Gets us the
///      thumbnail, video URL, creator handle, and the first
///      ~150–300 chars of caption. Caller then downloads `og:video`
///      and runs on-device speech recognition over the audio to get
///      the spoken portion of the recipe.
///   3. **Whatever we have** — returned as `seedText` so the user lands
///      in the existing paste flow with the caption snippet
///      pre-filled and can paste/edit the rest.
///
/// All requests fire from the user's device IP (mobile/WiFi) — IG does
/// not block residential IPs the way it blocks Cloudflare Workers'
/// datacenter ranges. Desktop UA is mandatory; mobile UA more often
/// gets the "Open in app" interstitial with no meta tags.
enum InstagramExtractor {
    struct Extraction {
        /// Full or partial caption text — stage 1 returns the full
        /// caption when JSON is parseable, stage 2 returns the
        /// ~200-char truncated preview from `og:description`.
        var captionText: String = ""

        /// Best-effort recipe title pulled from `og:title` or the JSON
        /// payload. Often something like "username on Instagram: …" —
        /// callers should not use this raw as the recipe title;
        /// `RecipeAIParser` will derive a proper title from the
        /// caption + transcript.
        var rawTitleField: String = ""

        /// Creator handle without the `@`. Used for attribution
        /// ("From @{handle} on Instagram") in the recipe summary.
        var ownerHandle: String?

        /// JPEG thumbnail URL (`og:image`). Caller downloads and
        /// attaches as the recipe's hero photo.
        var thumbnailURL: URL?

        /// MP4 video URL (`og:video`). Caller downloads and
        /// transcribes via `SpeechTranscriber`.
        var videoURL: URL?

        /// True when we parsed the full caption out of the inline JSON
        /// (stage 1 success) rather than the truncated og:description.
        /// Callers can use this to skip the audio-transcription step.
        var capturedFullCaption: Bool = false
    }

    enum ExtractionError: Error {
        case invalidURL
        case fetchFailed
        case blocked
        case empty
    }

    /// Maximum HTML response size. Reel pages are typically <1 MB; cap
    /// at 5 MB so a misconfigured or hostile response can't OOM us.
    static let maxHTMLBytes = 5 * 1024 * 1024

    /// Maximum mp4 size we'll download for transcription. Typical reel
    /// is 5–15 MB; cap at 60 MB. A reel longer than ~4 minutes at the
    /// usual bitrate would exceed this — those are vanishingly rare
    /// and "couldn't grab audio, paste the recipe" is a fine
    /// degradation for them.
    static let maxVideoBytes = 60 * 1024 * 1024

    // MARK: - Public surface

    /// Fetch the reel HTML and extract everything we can from a single
    /// network round-trip. Does NOT download the video — caller does
    /// that explicitly via `downloadVideo(_:)` so the UI can show
    /// "Downloading…" progress while it happens.
    static func extract(from url: URL) async throws -> Extraction {
        let canonical = canonicalURL(url)
        let html = try await fetchHTML(url: canonical)

        var extraction = Extraction()

        // Stage 1 — inline JSON. Best-effort; failures are silent.
        if let stage1 = parseInlineJSON(html: html) {
            extraction.captionText = stage1.captionText
            extraction.rawTitleField = stage1.rawTitleField
            extraction.ownerHandle = stage1.ownerHandle
            extraction.thumbnailURL = stage1.thumbnailURL
            extraction.videoURL = stage1.videoURL
            extraction.capturedFullCaption = !stage1.captionText.isEmpty
        }

        // Stage 2 — OpenGraph fallback. We always run it because it
        // can fill in fields stage 1 missed (e.g. JSON had caption but
        // no thumbnail).
        let stage2 = parseOpenGraph(html: html)
        if extraction.captionText.isEmpty {
            extraction.captionText = stage2.captionText
        }
        if extraction.rawTitleField.isEmpty {
            extraction.rawTitleField = stage2.rawTitleField
        }
        if extraction.ownerHandle == nil {
            extraction.ownerHandle = stage2.ownerHandle
        }
        if extraction.thumbnailURL == nil {
            extraction.thumbnailURL = stage2.thumbnailURL
        }
        if extraction.videoURL == nil {
            extraction.videoURL = stage2.videoURL
        }

        if extraction.captionText.isEmpty
            && extraction.thumbnailURL == nil
            && extraction.videoURL == nil {
            throw ExtractionError.empty
        }

        return extraction
    }

    /// Download an arbitrary CDN URL (thumbnail or mp4) to a tmp file
    /// with a size cap. Returns the local file URL. Caller is
    /// responsible for cleanup — `FileManager` will GC tmp on its own
    /// eventually but we should `try? remove` after consumption.
    static func downloadVideo(_ url: URL) async throws -> URL {
        try await download(url: url, maxBytes: maxVideoBytes, suffix: "mp4")
    }

    /// Download a thumbnail to bytes. Used for the recipe hero photo —
    /// we want the raw Data, not a file, so it can flow through the
    /// `DraftPhoto.image` field. Small (typically <500 KB).
    static func downloadThumbnail(_ url: URL) async throws -> Data {
        try await fetchBytes(url: url, maxBytes: 5 * 1024 * 1024)
    }

    /// Extract a clean first frame from a downloaded mp4. Uses
    /// `AVAssetImageGenerator` at ~0.1s (not 0) because IG sometimes
    /// serves a black or single-pixel first frame. Returns
    /// JPEG-encoded bytes (quality 0.85) ready for `DraftPhoto.image`.
    /// Returns nil on any failure (corrupt mp4, no video track,
    /// generator error) — caller falls back to `og:image`. Used to
    /// dodge the white play-triangle IG bakes into the `og:image`
    /// for any video post.
    static func extractFirstFrame(from fileURL: URL) async -> Data? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Tolerate codec keyframe spacing — many reels don't have a
        // keyframe at exactly 0.1s and an exact-tolerance request
        // throws on those.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        do {
            let (cgImage, _) = try await generator.image(
                at: CMTime(seconds: 0.1, preferredTimescale: 600)
            )
            return encodeJPEG(cgImage: cgImage, quality: 0.85)
        } catch {
            return nil
        }
    }

    /// Encode a `CGImage` as JPEG bytes via `ImageIO`. Returns nil on
    /// any failure so callers can fall back without a throw.
    private static func encodeJPEG(cgImage: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - HTML fetch

    private static func fetchHTML(url: URL) async throws -> String {
        let data: Data
        do {
            data = try await fetchBytes(url: url, maxBytes: maxHTMLBytes, accept: htmlAcceptHeader)
        } catch let urlError as URLError where urlError.code == .userAuthenticationRequired
            || urlError.code == .badServerResponse {
            throw ExtractionError.blocked
        } catch {
            throw ExtractionError.fetchFailed
        }
        if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1), !latin1.isEmpty {
            return latin1
        }
        throw ExtractionError.empty
    }

    private static let htmlAcceptHeader =
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"

    /// Desktop Safari UA. Instagram serves a richer HTML payload
    /// (including og:video and the inline JSON blob) to desktop UAs
    /// than to mobile ones — mobile gets a stub that says "Open in
    /// app" and link-preview crawlers get the full meta tags. We want
    /// the crawler payload.
    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/17.0 Safari/605.1.15"

    private static func fetchBytes(
        url: URL,
        maxBytes: Int,
        accept: String = "*/*"
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.google.com/", forHTTPHeaderField: "Referer")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 429 {
                throw ExtractionError.blocked
            }
            if !(200..<400).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
        }
        if response.expectedContentLength > Int64(maxBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var buffer = Data()
        let hint = Int(max(response.expectedContentLength, 0))
        buffer.reserveCapacity(min(hint, maxBytes))
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count > maxBytes {
                throw URLError(.dataLengthExceedsMaximum)
            }
        }
        return buffer
    }

    private static func download(
        url: URL,
        maxBytes: Int,
        suffix: String
    ) async throws -> URL {
        let data = try await fetchBytes(url: url, maxBytes: maxBytes)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ig-\(UUID().uuidString).\(suffix)")
        try data.write(to: tmp, options: .atomic)
        return tmp
    }

    // MARK: - URL canonicalisation

    /// Strip tracking query params (`?igsh=…`, `?utm_*`) and trailing
    /// slashes so the fetched URL is the canonical post URL. IG
    /// sometimes redirects shortened links — let URLSession follow.
    static func canonicalURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        if let items = components.queryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                return !(name == "igsh" || name == "igshid"
                    || name.hasPrefix("utm_") || name == "ref" || name == "ref_src")
            }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return components.url ?? url
    }

    // MARK: - Stage 1: inline JSON

    /// Best-effort caption extraction from inline JSON blobs in the
    /// page. Tries (a) schema.org `application/ld+json` first because
    /// those are stable and standardized, then (b) the generic
    /// `application/json` blocks IG ships for client hydration.
    ///
    /// Schema-shapes targeted (any one of these is enough):
    ///   • `VideoObject.description` (ld+json)
    ///   • `caption.text` deep in the data tree
    ///   • `edge_media_to_caption.edges[0].node.text` (legacy)
    ///   • `video_url` / `display_url` for media URLs
    ///   • `owner.username` for the handle
    ///
    /// Returns nil when no usable fields are found. Failures here are
    /// silent — caller falls through to OpenGraph parsing.
    static func parseInlineJSON(html: String) -> Extraction? {
        var aggregate = Extraction()

        for block in scriptJSONBlocks(html: html, type: "application/ld+json") {
            if let parsed = try? JSONSerialization.jsonObject(with: Data(block.utf8)) {
                walkJSON(parsed, into: &aggregate)
            }
        }

        // Don't trip over the larger `application/json` blocks unless we
        // need to — they can be megabytes. Only mine them if ld+json
        // didn't give us a caption.
        if aggregate.captionText.isEmpty {
            for block in scriptJSONBlocks(html: html, type: "application/json") {
                if let parsed = try? JSONSerialization.jsonObject(with: Data(block.utf8)) {
                    walkJSON(parsed, into: &aggregate)
                    if !aggregate.captionText.isEmpty { break }
                }
            }
        }

        if aggregate.captionText.isEmpty
            && aggregate.videoURL == nil
            && aggregate.thumbnailURL == nil
            && aggregate.ownerHandle == nil {
            return nil
        }
        return aggregate
    }

    /// Walk a deserialized JSON tree and stuff anything that looks
    /// caption-like into the accumulator. Bounded recursion depth — IG
    /// has shipped 30+ nesting levels in their hydration JSON.
    private static func walkJSON(_ node: Any, into out: inout Extraction, depth: Int = 0) {
        guard depth < 40 else { return }

        if let dict = node as? [String: Any] {
            // schema.org VideoObject / ImageObject "description"
            if (dict["@type"] as? String)?.localizedCaseInsensitiveContains("VideoObject") == true
                || (dict["@type"] as? String)?.localizedCaseInsensitiveContains("ImageObject") == true {
                if let desc = dict["description"] as? String, !desc.isEmpty,
                   desc.count > out.captionText.count {
                    out.captionText = desc
                }
                if let name = dict["name"] as? String, !name.isEmpty,
                   out.rawTitleField.isEmpty {
                    out.rawTitleField = name
                }
                if let thumb = dict["thumbnailUrl"] as? String,
                   let url = URL(string: thumb), out.thumbnailURL == nil {
                    out.thumbnailURL = url
                }
                if let video = dict["contentUrl"] as? String,
                   let url = URL(string: video), out.videoURL == nil {
                    out.videoURL = url
                }
                if let author = dict["author"] as? [String: Any],
                   let handle = (author["alternateName"] as? String)
                       ?? (author["name"] as? String),
                   out.ownerHandle == nil {
                    out.ownerHandle = handle.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
                }
            }

            // Generic caption.text pattern (IG hydration data)
            if let caption = dict["caption"] as? [String: Any],
               let text = caption["text"] as? String,
               !text.isEmpty,
               text.count > out.captionText.count {
                out.captionText = text
            }

            // Legacy edge_media_to_caption pattern
            if let edges = (dict["edge_media_to_caption"] as? [String: Any])?["edges"]
                as? [[String: Any]],
               let node = edges.first?["node"] as? [String: Any],
               let text = node["text"] as? String,
               !text.isEmpty,
               text.count > out.captionText.count {
                out.captionText = text
            }

            if let videoURLString = dict["video_url"] as? String,
               let url = URL(string: videoURLString), out.videoURL == nil {
                out.videoURL = url
            }
            if let displayURLString = dict["display_url"] as? String,
               let url = URL(string: displayURLString), out.thumbnailURL == nil {
                out.thumbnailURL = url
            }

            if let owner = dict["owner"] as? [String: Any],
               let username = owner["username"] as? String,
               out.ownerHandle == nil {
                out.ownerHandle = username
            }

            for (_, value) in dict {
                walkJSON(value, into: &out, depth: depth + 1)
            }
        } else if let array = node as? [Any] {
            for item in array {
                walkJSON(item, into: &out, depth: depth + 1)
            }
        }
    }

    /// Pull the contents of every `<script type="<typeName>">…</script>`
    /// block out of the HTML. Order-preserving so ld+json blocks
    /// (which come early in the head) get tried first.
    static func scriptJSONBlocks(html: String, type: String) -> [String] {
        var results: [String] = []
        let pattern = #"<script[^>]*type=["']\#(NSRegularExpression.escapedPattern(for: type))["'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return results
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        for match in matches where match.numberOfRanges >= 2 {
            let body = ns.substring(with: match.range(at: 1))
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { results.append(trimmed) }
        }
        return results
    }

    // MARK: - Stage 2: OpenGraph meta tags

    static func parseOpenGraph(html: String) -> Extraction {
        var out = Extraction()

        let title = metaContent(html: html, property: "og:title")
        if let title, !title.isEmpty {
            out.rawTitleField = title
            // og:title looks like "username on Instagram: …" — peel
            // off the handle when present.
            out.ownerHandle = parseOwnerFromOGTitle(title)
        }

        if let desc = metaContent(html: html, property: "og:description"),
           !desc.isEmpty {
            out.captionText = parseCaptionSnippet(ogDescription: desc) ?? desc
            // og:description sometimes carries the handle before the
            // colon when og:title doesn't; backfill.
            if out.ownerHandle == nil {
                out.ownerHandle = parseOwnerFromOGDescription(desc)
            }
        }

        if let imageStr = metaContent(html: html, property: "og:image"),
           let url = URL(string: imageStr) {
            out.thumbnailURL = url
        }

        if let videoStr = metaContent(html: html, property: "og:video")
            ?? metaContent(html: html, property: "og:video:secure_url"),
           let url = URL(string: videoStr) {
            out.videoURL = url
        }

        return out
    }

    /// Extract `content="..."` from a `<meta property="..." …>` tag.
    /// Tolerates property/content attribute order swap and stray
    /// whitespace. Returns the HTML-entity-decoded string.
    static func metaContent(html: String, property: String) -> String? {
        let propEscaped = NSRegularExpression.escapedPattern(for: property)
        // Two patterns because property and content can appear in
        // either order. IG ships them as `property="…" content="…"`
        // but other sites swap; we want to be tolerant.
        let patterns = [
            #"<meta[^>]*?property=["']\#(propEscaped)["'][^>]*?content=["']([^"']*)["'][^>]*?/?>"#,
            #"<meta[^>]*?content=["']([^"']*)["'][^>]*?property=["']\#(propEscaped)["'][^>]*?/?>"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let ns = html as NSString
                if let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
                   match.numberOfRanges >= 2 {
                    return decodeHTMLEntities(ns.substring(with: match.range(at: 1)))
                }
            }
        }
        return nil
    }

    /// IG's og:description wraps the caption in a fixed prefix:
    ///   `"162K likes, 155 comments - username on Aug 5, 2025: \"<caption>\""`
    /// Peel off the prefix and the quote characters so we hand the
    /// parser the caption-only text. Returns nil if the description
    /// doesn't match the expected shape (we then use the raw string).
    static func parseCaptionSnippet(ogDescription: String) -> String? {
        // Locate the first `: "` which separates the metadata
        // preamble from the caption. The closing quote is at the
        // end of the description (sometimes followed by a `.` IG
        // appends for emoji-only captions).
        guard let colonQuoteRange = ogDescription.range(of: ": \"") else {
            // Some descriptions use curly quotes:
            if let curlyRange = ogDescription.range(of: ": \u{201C}") {
                let after = ogDescription[curlyRange.upperBound...]
                return trimTrailingQuote(String(after))
            }
            return nil
        }
        let after = ogDescription[colonQuoteRange.upperBound...]
        return trimTrailingQuote(String(after))
    }

    private static func trimTrailingQuote(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = out.last, last == "\"" || last == "\u{201D}" || last == "." {
            out.removeLast()
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull `username` out of `"username on Instagram: …"`.
    static func parseOwnerFromOGTitle(_ title: String) -> String? {
        // Match the leading non-space run before " on Instagram"
        guard let range = title.range(of: " on Instagram") else { return nil }
        let prefix = title[..<range.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return nil }
        // Strip any leading "@" that some embeds include
        let cleaned = prefix.hasPrefix("@") ? String(prefix.dropFirst()) : prefix
        // Sanity-cap so a weird title doesn't pollute attribution
        guard cleaned.count <= 60, !cleaned.contains(" ") else { return nil }
        return cleaned
    }

    /// Pull `username` out of `"N likes, M comments - username on …"`.
    static func parseOwnerFromOGDescription(_ desc: String) -> String? {
        // Match " - <username> on " pattern
        let pattern = #"\s-\s([^\s]+)\son\s"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = desc as NSString
        guard let match = regex.firstMatch(in: desc, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        let raw = ns.substring(with: match.range(at: 1))
        let cleaned = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        guard cleaned.count <= 60 else { return nil }
        return cleaned
    }

    // MARK: - HTML entity decode

    /// Decode the small subset of HTML entities IG actually emits in
    /// meta-tag content. Full HTML-entity decoding would be overkill
    /// (and `String(htmlDecoding:)` doesn't exist in Foundation
    /// proper). Order matters — decode `&amp;` last so we don't
    /// double-decode entities that legitimately contain `&`.
    static func decodeHTMLEntities(_ s: String) -> String {
        var out = s
        let replacements: [(String, String)] = [
            ("&quot;", "\""),
            ("&#34;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " "),
            ("&amp;", "&"),
        ]
        for (entity, char) in replacements {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }
}
