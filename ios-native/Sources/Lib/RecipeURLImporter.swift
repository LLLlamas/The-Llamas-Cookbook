import Foundation

/// Fetches a recipe from a URL and tells the caller, honestly, what
/// shape of result it could produce. Routes per platform because the
/// closed-off ones (Instagram, Facebook) can't hand us caption text
/// without authenticated API access — for those we bow out cleanly so
/// the user can paste the caption into the existing text-import flow
/// instead of staring at a stuck spinner.
///
/// **Platform map:**
/// - Recipe blogs / generic URLs → JSON-LD `Recipe` schema (gold path),
///   then OpenGraph fallback for title + summary.
/// - Pinterest → schema if present (some pins have it), otherwise the
///   pin description from `og:description` is dropped into the paste box.
/// - TikTok → public oEmbed endpoint. `title` is usually the caption,
///   so it lands in the paste box for the user to label up.
/// - Instagram / Facebook → blocked, returns a clear "paste the caption"
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

        case failed(message: String)
    }

    static func fetch(_ urlString: String) async -> Outcome {
        guard let url = normalizeURL(urlString) else {
            return .failed(message: "That doesn't look like a valid link.")
        }
        let host = (url.host ?? "").lowercased()
        switch Platform.from(host: host) {
        case .instagram:
            return blocked(url: url, platform: "Instagram")
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
        if result.recipeFound {
            return .full(result.draft)
        }
        var enrichment = result.draft
        enrichment.sourceUrl = url.absoluteString
        let seed = enrichment.summary
        return .partial(
            enrichment: enrichment,
            seedText: seed,
            hint: seed.isEmpty
                ? "Couldn't read this pin's text. If it links out to a recipe blog, try pasting that link instead."
                : "Got the pin's description. Add labels like \"Ingredients\" and \"Steps\" if needed, then preview."
        )
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
            // Lift hashtags into tags and strip them from the caption so
            // the user isn't left with `#fyp #cooking` glued to a step.
            let (cleaned, tags) = liftHashtags(from: caption)
            enrichment.tags = tags
            return .partial(
                enrichment: enrichment,
                seedText: cleaned,
                hint: "Got the TikTok caption. Add labels like \"Ingredients\" and \"Steps\" above the relevant lines, then preview."
            )
        } catch {
            return blocked(url: url, platform: "TikTok")
        }
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
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
