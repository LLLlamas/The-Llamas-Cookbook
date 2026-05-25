import Foundation

/// Fetches a recipe from a URL and tells the caller, honestly, what
/// shape of result it could produce. Routes per platform because each
/// closed-off site needs its own coaxing — for the rest we bow out
/// cleanly so the user can paste the caption into the existing
/// text-import flow instead of staring at a stuck spinner.
///
/// **Platform map:**
/// - Recipe blogs / generic URLs → JSON-LD `Recipe` schema (gold path),
///   then OpenGraph fallback for title + summary.
/// - Pinterest → schema if present (some pins have it), otherwise the
///   pin description from `og:description` is dropped into the paste box.
/// - TikTok → public oEmbed endpoint. `title` is usually the caption,
///   so it lands in the paste box for the user to label up.
/// - Instagram → three-stage device-side extraction (inline JSON →
///   og:* + on-device audio transcription → paste fallback). See
///   `InstagramExtractor` + `SpeechTranscriber`.
/// - Facebook → blocked, returns a clear "paste the caption"
///   message with the source URL preserved.
enum RecipeURLImporter {
    enum Outcome {
        /// Full recipe parsed — caller drops straight into editor preview.
        case full(DraftRecipe)

        /// Got something useful (title, partial fields, caption text)
        /// but the user needs to look at it / paste more before saving.
        /// `seedText` populates the existing paste box; `enrichment`
        /// carries fields like sourceUrl + tags that should be merged
        /// into the eventual preview draft.
        case partial(enrichment: DraftRecipe, seedText: String, hint: String)

        /// Platform doesn't allow caption fetching from a URL alone.
        /// `enrichment` carries at least the source URL so attribution
        /// survives the paste flow.
        case blocked(enrichment: DraftRecipe, hint: String)

        /// Caption/page was reachable, but did not contain usable
        /// ingredient/step content.
        case noRecipeInCaption(enrichment: DraftRecipe, hint: String)

        case failed(message: String)
    }

    static func fetch(_ urlString: String) async -> Outcome {
        guard let url = normalizeURL(urlString) else {
            return .failed(message: "That doesn't look like a valid link.")
        }
        let host = (url.host ?? "").lowercased()
        switch Platform.from(host: host) {
        case .instagram:
            return await fetchInstagram(url: url)
        case .facebook:
            return blocked(url: url, platform: "Facebook")
        case .tiktok:
            return await fetchTikTok(url: url)
        case .pinterest:
            return await fetchPinterest(url: url)
        case .other:
            return await fetchHTML(url: url)
        }
    }

    // MARK: - Platform routing

    private enum Platform {
        case tiktok, instagram, facebook, pinterest, other

        static func from(host: String) -> Platform {
            if host.contains("tiktok.com") || host.contains("vm.tiktok.com") { return .tiktok }
            if host.contains("instagram.com") || host.contains("instagr.am") { return .instagram }
            if host.contains("facebook.com") || host.contains("fb.com") || host.contains("fb.me") {
                return .facebook
            }
            if host.contains("pinterest.com") || host.contains("pinterest.")
                || host == "pin.it" || host.hasSuffix(".pin.it") { return .pinterest }
            return .other
        }
    }

    private static func blocked(url: URL, platform: String) -> Outcome {
        var enrichment = DraftRecipe()
        enrichment.sourceUrl = url.absoluteString
        return .blocked(
            enrichment: enrichment,
            hint: "\(platform) doesn't share captions through links — but the source link is saved. Paste the caption text below to fill ingredients & steps."
        )
    }

    // MARK: - Generic HTML / blog path

    private static func fetchHTML(url: URL) async -> Outcome {
        let html: String
        do {
            html = try await fetchString(url: url)
        } catch {
            return .failed(message: "Couldn't reach that site. Check the link and your connection.")
        }
        let result = RecipeSchemaParser.parse(html: html, sourceUrl: url.absoluteString)
        if result.recipeFound {
            return .full(result.draft)
        }
        var enrichment = result.draft
        enrichment.sourceUrl = url.absoluteString
        let hasMeta = !enrichment.title.trimmed.isEmpty || !enrichment.summary.trimmed.isEmpty
        guard hasMeta else {
            return .failed(message: "No recipe content found on that page.")
        }
        if !enrichment.summary.isEmpty,
           let aiDraft = await RecipeAIParser.parseBestOf(enrichment.summary, sourceUrl: url.absoluteString) {
            return .full(aiDraft)
        }
        return .partial(
            enrichment: enrichment,
            seedText: enrichment.summary,
            hint: "Got the page title and summary — couldn't find a structured recipe. Paste or edit the recipe text below to fill ingredients & steps."
        )
    }

    // MARK: - Pinterest

    private static func fetchPinterest(url: URL) async -> Outcome {
        let html: String
        do {
            html = try await fetchString(url: url)
        } catch {
            return .failed(message: "Couldn't reach Pinterest. Check the link and your connection.")
        }
        let result = RecipeSchemaParser.parse(html: html, sourceUrl: url.absoluteString)
        if result.recipeFound, !result.draft.steps.isEmpty {
            return .full(result.draft)
        }
        if let followed = await followPinterestSharedContent(from: html, originalURL: url) {
            return followed
        }
        if result.recipeFound {
            return .partial(
                enrichment: result.draft,
                seedText: "",
                hint: "Got the ingredients from this pin. For the steps, try the pin's Visit link to the original recipe."
            )
        }
        var enrichment = result.draft
        enrichment.sourceUrl = url.absoluteString
        let seed = ""
        return .partial(
            enrichment: enrichment,
            seedText: seed,
            hint: seed.isEmpty
                ? "Couldn't read this pin's text. If it links out to a recipe blog, try pasting that link instead."
                : "Got the pin's description. Make sure line 1 is the title — leave a blank line between title, ingredients, and steps."
        )
    }

    private static func followPinterestSharedContent(from html: String, originalURL: URL) async -> Outcome? {
        guard let shared = RecipeSchemaParser.extractPinterestSharedContent(from: html),
              let destination = normalizeURL(shared),
              !isPinterestHost(destination.host ?? "")
        else { return nil }

        let downstream = await fetch(destination.absoluteString)
        switch downstream {
        case .full(var draft):
            draft.sourceUrl = originalURL.absoluteString
            return .full(draft)
        case .partial(var enrichment, let seedText, let hint):
            enrichment.sourceUrl = originalURL.absoluteString
            return .partial(enrichment: enrichment, seedText: seedText, hint: hint)
        case .blocked(var enrichment, let hint):
            enrichment.sourceUrl = originalURL.absoluteString
            return .blocked(enrichment: enrichment, hint: hint)
        case .noRecipeInCaption(var enrichment, let hint):
            enrichment.sourceUrl = originalURL.absoluteString
            return .noRecipeInCaption(enrichment: enrichment, hint: hint)
        case .failed:
            return nil
        }
    }

    private static func isPinterestHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower.contains("pinterest.") || lower == "pin.it" || lower.hasSuffix(".pin.it")
    }

    // MARK: - TikTok

    private static func fetchTikTok(url: URL) async -> Outcome {
        let encoded = url.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? url.absoluteString
        guard let oembed = URL(string: "https://www.tiktok.com/oembed?url=\(encoded)") else {
            return blocked(url: url, platform: "TikTok")
        }
        do {
            let data = try await fetchData(url: oembed)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return blocked(url: url, platform: "TikTok")
            }
            var enrichment = DraftRecipe()
            enrichment.sourceUrl = url.absoluteString
            let caption = (json["title"] as? String)?.trimmed ?? ""
            guard !caption.isEmpty else {
                return blocked(url: url, platform: "TikTok")
            }
            // Strip hashtags (and creator @-handle) from the caption so
            // the user isn't left with `#fyp #cooking` glued to a step.
            // Tags are deliberately NOT auto-populated — categories are
            // the user's call, not the import path's.
            let (cleaned, _) = liftHashtags(from: caption)
            let exploded = RecipeImporter.explodeSingleParagraph(cleaned)
            let regexDraft = RecipeImporter.parse(exploded)
            guard RecipeImporter.hasUsableRecipeContent(regexDraft) else {
                if let outbound = RecipeImporter.extractCaptionURL(cleaned) {
                    return .partial(
                        enrichment: enrichment,
                        seedText: "",
                        hint: "This caption mentions \(outbound.host ?? outbound.absoluteString). Try importing that link instead."
                    )
                }
                return .noRecipeInCaption(
                    enrichment: enrichment,
                    hint: "This caption doesn't seem to contain a recipe. Paste the recipe text when you have it and I'll import that."
                )
            }
            if let aiDraft = await RecipeAIParser.parseBestOf(cleaned, sourceUrl: url.absoluteString) {
                return .full(aiDraft)
            }
            // TikTok ships captions as one long paragraph — pre-explode
            // before handing back as seed text so the user sees a
            // multi-line preview they can sanity-check, not a wall.
            return .partial(
                enrichment: enrichment,
                seedText: exploded,
                hint: "Got the TikTok caption. Make sure line 1 is the title — leave a blank line between title, ingredients, and steps."
            )
        } catch {
            return blocked(url: url, platform: "TikTok")
        }
    }

    // MARK: - Instagram

    /// Three-stage device-side extraction:
    ///   1. Fetch the reel HTML, try inline-JSON for the full caption.
    ///   2. Fall back to OpenGraph meta tags (truncated caption +
    ///      og:video URL). Download the mp4, transcribe its audio with
    ///      `SpeechTranscriber`, combine caption snippet + transcript.
    ///   3. Whatever we have → seed the paste flow with caption +
    ///      thumbnail + creator handle attribution.
    ///
    /// Stage 1's success means we can skip the video download +
    /// transcription entirely. Stage 2 is the audio path for the
    /// dominant case (recipe spoken in the reel, short caption).
    /// Stage 3 is the final degradation — the user paste fallback we
    /// already shipped, but now with a populated thumbnail + handle
    /// attribution attached.
    ///
    /// All network requests fire from the user's residential IP; IG
    /// does not block residential ranges the way it blocks
    /// Cloudflare's datacenter IPs.
    private static func fetchInstagram(url: URL) async -> Outcome {
        let extraction: InstagramExtractor.Extraction
        do {
            extraction = try await InstagramExtractor.extract(from: url)
        } catch InstagramExtractor.ExtractionError.blocked {
            return blocked(url: url, platform: "Instagram")
        } catch {
            return blocked(url: url, platform: "Instagram")
        }

        // Build the base enrichment (source URL + attribution +
        // hero photo) before we know whether the parse will be
        // confident — every outcome below carries it forward.
        var enrichment = DraftRecipe()
        enrichment.sourceUrl = url.absoluteString
        if let handle = extraction.ownerHandle, !handle.isEmpty {
            enrichment.summary = "From @\(handle) on Instagram"
        }
        if let thumbURL = extraction.thumbnailURL,
           let bytes = try? await InstagramExtractor.downloadThumbnail(thumbURL),
           !bytes.isEmpty {
            enrichment.photos = [DraftPhoto(image: bytes)]
        }

        // Stage 1 — inline JSON gave us the full caption. Skip the
        // audio path entirely.
        if extraction.capturedFullCaption, !extraction.captionText.isEmpty {
            let (cleaned, _) = liftHashtags(from: extraction.captionText)
            return await finishInstagramParse(
                rawText: cleaned,
                url: url,
                enrichment: enrichment,
                stage: .fullCaption
            )
        }

        // Stage 2 — caption snippet + audio transcript.
        var assembledText = extraction.captionText
        if let videoURL = extraction.videoURL,
           let videoFile = try? await InstagramExtractor.downloadVideo(videoURL) {
            defer { try? FileManager.default.removeItem(at: videoFile) }
            if let transcript = try? await SpeechTranscriber.transcribe(fileURL: videoFile),
               !transcript.isEmpty {
                if assembledText.isEmpty {
                    assembledText = transcript
                } else {
                    assembledText += "\n\n" + transcript
                }
            }
        }

        if !assembledText.isEmpty {
            let (cleaned, _) = liftHashtags(from: assembledText)
            return await finishInstagramParse(
                rawText: cleaned,
                url: url,
                enrichment: enrichment,
                stage: .snippetPlusTranscript
            )
        }

        // Stage 3 — nothing usable. Hand back whatever we have as
        // a paste-fallback seed.
        return .blocked(
            enrichment: enrichment,
            hint: "Couldn't read the caption from that Instagram link. Paste the caption text below to fill ingredients & steps."
        )
    }

    private enum InstagramStage {
        case fullCaption
        case snippetPlusTranscript
    }

    /// Shared tail end of stages 1 and 2: feed the cleaned text into
    /// the AI parser, return `.full` when confident, `.partial` with
    /// the assembled text as seedText otherwise. The enrichment
    /// (source URL, attribution, hero photo) flows through both
    /// branches.
    private static func finishInstagramParse(
        rawText: String,
        url: URL,
        enrichment: DraftRecipe,
        stage: InstagramStage
    ) async -> Outcome {
        let exploded = RecipeImporter.explodeSingleParagraph(rawText)

        if let aiDraft = await RecipeAIParser.parseBestOf(rawText, sourceUrl: url.absoluteString),
           !aiDraft.title.trimmed.isEmpty,
           (!aiDraft.ingredients.isEmpty || !aiDraft.steps.isEmpty) {
            // Merge enrichment fields into the AI draft so the
            // source URL, attribution, and hero photo survive.
            var draft = aiDraft
            if draft.sourceUrl.trimmed.isEmpty {
                draft.sourceUrl = enrichment.sourceUrl
            }
            if draft.summary.trimmed.isEmpty, !enrichment.summary.trimmed.isEmpty {
                draft.summary = enrichment.summary
            }
            if draft.photos.isEmpty, !enrichment.photos.isEmpty {
                draft.photos = enrichment.photos
            }
            return .full(draft)
        }

        let hint: String
        switch stage {
        case .fullCaption:
            hint = "Got the caption from Instagram. Make sure line 1 is the title — leave a blank line between title, ingredients, and steps."
        case .snippetPlusTranscript:
            hint = "Got what Instagram shares about this reel. Fill in or paste anything missing below."
        }
        return .partial(
            enrichment: enrichment,
            seedText: exploded,
            hint: hint
        )
    }

    private static func liftHashtags(from text: String) -> (text: String, tags: [String]) {
        var tags: [String] = []
        for match in text.matches(of: #/#([\p{L}\p{N}_]+)/#) {
            let tag = String(match.output.1).lowercased()
            if !tags.contains(tag) { tags.append(tag) }
        }
        let stripped = text
            .replacing(#/#[\p{L}\p{N}_]+/#, with: "")
            // Strip any @user / @user.name mentions — TikTok oEmbed often
            // suffixes the caption with the creator's handle, which has
            // no business being in the recipe text.
            .replacing(#/@[\p{L}\p{N}_.]+/#, with: "")
            .replacing(#/[ \t]{2,}/#, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped, tags)
    }

    // MARK: - URL hygiene + networking

    private static func normalizeURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "https://" + trimmed
        }
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    private static func fetchString(url: URL) async throws -> String {
        let data = try await fetchData(url: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return ""
    }

    /// 10 MB cap on response bodies. Real recipe pages are well under
    /// 1 MB; anything larger is either a misconfigured server, a video
    /// page we can't parse anyway, or an adversarial response designed
    /// to push us toward an OOM. Stream-aborts above the cap so we
    /// never hold the full body in memory.
    private static let maxResponseBytes = 10 * 1024 * 1024

    private static func fetchData(url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        // Mobile Safari UA — recipe sites and Pinterest both serve a
        // friendlier (less script-heavy) page to phone clients, and a
        // generic URLSession UA gets bot-walled often enough to matter.
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,application/json,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        // Fast reject when the server is honest about size.
        if response.expectedContentLength > Int64(maxResponseBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var buffer = Data()
        let hint = Int(max(response.expectedContentLength, 0))
        buffer.reserveCapacity(min(hint, maxResponseBytes))
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count > maxResponseBytes {
                throw URLError(.dataLengthExceedsMaximum)
            }
        }
        return buffer
    }
}
