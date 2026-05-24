import Foundation
import os

/// Signposter for the Anthropic streaming HTTP call. Lets Instruments
/// visualize the upstream request vs. the iOS-side SSE parse separately
/// from the wider photo-import pipeline (which has its own category in
/// `ImportFromPhotoView`).
private let anthropicSignposter = OSSignposter(subsystem: "com.llamascookbook.app", category: "anthropic")

// MARK: - Vision parse result types

/// Outcome of a vision-path photo import parse call.
/// Carries the parsed draft (nil = no usable content) and metadata
/// the UI needs to decide on quota messaging and cache-hit hints.
struct VisionParseOutcome {
    var draft:    DraftRecipe?
    var cacheHit: Bool           = false
    var error:    VisionParseError? = nil
}

/// Typed errors surfaced by the photo-import vision path.
/// The UI maps each case to distinct messaging (auth gate, upsell card).
/// Network/parse failures stay nil (fallback to OCR).
enum VisionParseError: Equatable {
    case authRequired   // 401 — no signed-in user
    case quotaExhausted // 402 — monthly cap hit
    // 429 from Anthropic (rate limit) retries silently up to 3× then falls back to OCR.
}

/// Anthropic Claude API client for recipe parsing.
///
/// Routes through the Cloudflare Worker proxy at
/// `llamascookbook.pages.dev/api/parse` so the Anthropic API key
/// never ships in the app binary. The Worker holds the key in an
/// encrypted env var and injects it before forwarding to Anthropic.
///
/// **Structured output:** Forces the model to call the `structured_recipe`
/// tool so the response is always a JSON object matching the recipe schema
/// rather than free-form prose. Malformed or low-quality responses return
/// nil; the caller falls back to the Apple Intelligence path or the regex
/// pipeline unchanged.
///
/// **Prompt caching:** The system block carries
/// `cache_control: {type: ephemeral, ttl: 1h}`, activated by the
/// `extended-cache-ttl-2025-04-11` beta header. Repeat imports within a
/// 60-minute meal-planning window cost ~90% less for the ~6,300-token
/// cached prefix. The 1h TTL pays a slightly higher cache-write rate on
/// the first call in the window but is net-positive when the user does
/// 2+ imports per hour (the common case for recipe collection).
enum AnthropicRecipeParser {

    // MARK: - Availability

    /// Always true — the proxy is always reachable when the device has
    /// network. Network failures fall through to nil gracefully.
    static let isConfigured: Bool = true
    #if DEBUG
    // Must match BYPASS_SECRET env var in Cloudflare Pages dashboard.
    static let testBypassSecret = "llamas-dev-bypass-2026"
    #endif

    // MARK: - Models

    enum Model {
        /// Fast, cost-efficient. Good for clean text (link import,
        /// social captions, structured blog scrapes).
        static let haiku = "claude-haiku-4-5-20251001"
        /// Higher quality. Used for photo import where OCR noise,
        /// two-column layouts, and handwriting require stronger
        /// instruction following.
        static let sonnet = "claude-sonnet-4-6"
    }

    // MARK: - Parse

    /// Parse a free-form recipe blob via the Cloudflare → Claude path.
    ///
    /// - Parameter model: Which Claude model to call. Defaults to Haiku
    ///   (fast, cheap). Pass `Model.sonnet` for photo-import paths where
    ///   OCR noise warrants higher accuracy.
    ///
    /// Returns nil when:
    /// - The network call fails or the proxy returns an error status.
    /// - The model's response fails the minimum quality gate (at least
    ///   one ingredient or step).
    ///
    /// Callers treat nil as "fall back to the next parser in the chain"
    /// — never as a hard failure the user sees.
    static func parse(_ text: String, sourceUrl: String?, model: String = Model.haiku) async -> DraftRecipe? {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return nil }

        // Cap at ~15 000 chars (≈ 4 000 tokens). Real recipe text rarely
        // exceeds 3 000 chars; the cap prevents runaway cost from a
        // scraper that leaked full page HTML into the text field.
        let capped = trimmed.count > 15_000 ? String(trimmed.prefix(15_000)) : trimmed

        do {
            return try await callAPI(text: capped, sourceUrl: sourceUrl, model: model, attempt: 0)
        } catch {
            return nil
        }
    }

    /// Parse one or more recipe-page images via Claude vision through
    /// the same Cloudflare → Anthropic proxy. Each image becomes its
    /// own `image` content block in the user message; the model reads
    /// pages in order and emits a single structured recipe via the
    /// same `structured_recipe` tool the text path uses.
    ///
    /// Returns a `VisionParseOutcome` which wraps the optional draft,
    /// a `cacheHit` flag (for the "same photo" hint in the UI), and
    /// typed errors for auth/quota/daily-limit rejection so the UI
    /// can surface the right message without parsing HTTP status codes.
    ///
    /// - Parameter images: JPEG-encoded page bytes, in reading order.
    ///   Caller must supply JPEGs (Anthropic vision rejects HEIC) —
    ///   `ImageProcessing.prepare(_:for:.aiVision)` does the right thing.
    /// - Parameter sourceUrl: Optional URL stamped on the resulting
    ///   draft for attribution. Pass nil for camera/library imports.
    /// - Parameter model: Which Claude model. Defaults to Sonnet 4.6.
    static func parseImages(
        _ images: [Data],
        sourceUrl: String?,
        model: String = Model.sonnet
    ) async -> VisionParseOutcome {
        guard !images.isEmpty else { return VisionParseOutcome() }

        // Cap at 3 pages to match the UI's maxSelectionCount.
        let capped = Array(images.prefix(3))

        do {
            return try await callAPIWithImages(
                images: capped,
                sourceUrl: sourceUrl,
                model: model,
                attempt: 0
            )
        } catch {
            return VisionParseOutcome()
        }
    }

    /// Streaming variant of `parseImages`. Identical request shape but
    /// with `stream: true`; the Anthropic SSE response is parsed
    /// incrementally and each completed sub-value of the
    /// `structured_recipe` tool input is delivered to `streamingState`
    /// as a typed event. The final `VisionParseOutcome` carries the
    /// fully-assembled draft (or nil if the stream produced an
    /// unusable result), matching the non-streaming function's contract.
    ///
    /// Cache hits short-circuit the streaming path: the Worker returns
    /// a non-streaming JSON body with `x-llamas-cache: hit`, and this
    /// function parses it as a single buffer — the streaming state is
    /// left untouched, since the caller has the full draft immediately.
    static func parseImagesStreaming(
        _ images: [Data],
        sourceUrl: String?,
        streamingState: StreamingRecipeState,
        model: String = Model.sonnet
    ) async -> VisionParseOutcome {
        guard !images.isEmpty else { return VisionParseOutcome() }
        let capped = Array(images.prefix(3))
        do {
            return try await callAPIWithImagesStreaming(
                images: capped,
                sourceUrl: sourceUrl,
                model: model,
                streamingState: streamingState,
                attempt: 0
            )
        } catch {
            return VisionParseOutcome()
        }
    }

    // MARK: - HTTP

    private static func callAPI(
        text: String,
        sourceUrl: String?,
        model: String,
        attempt: Int
    ) async throws -> DraftRecipe? {
        var request = URLRequest(url: URL(string: "https://llamascookbook.pages.dev/api/parse")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json",              forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01",                    forHTTPHeaderField: "anthropic-version")
        // Activate cache_control blocks on the system prompt and the 1-hour
        // extended TTL — repeat imports in a meal-planning window (typically
        // 15-30 min between captures) hit the cache instead of the cold path.
        request.setValue("extended-cache-ttl-2025-04-11", forHTTPHeaderField: "anthropic-beta")
        // Identity headers — the Worker enforces a per-user (or per-IP for
        // anon) daily cap on text/link parses as an abuse gate. Sign-in is
        // not required for text/link; signed-out users get a tighter cap
        // keyed on Cloudflare client IP.
        request.setValue("text", forHTTPHeaderField: "x-llamas-import-kind")
        if let userId = KeychainStore.read(.appleSub) {
            request.setValue(userId, forHTTPHeaderField: "x-llamas-user")
        }
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "x-llamas-tz")
        #if DEBUG
        request.setValue(AnthropicRecipeParser.testBypassSecret, forHTTPHeaderField: "x-llamas-bypass")
        #endif

        request.httpBody = try buildBody(text: text, model: model)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }

        switch http.statusCode {
        case 200:
            return extractDraft(from: data, sourceUrl: sourceUrl)

        case 429:
            // 429 can come from either Anthropic (upstream rate-limit) OR our
            // Worker's per-identity daily cap. Both want the same behaviour at
            // this layer: stop trying. The retry below only helps with the
            // Anthropic case, but distinguishing them would require parsing
            // the response body; treating both identically is safe — caller
            // falls back to Apple Intelligence → regex unchanged.
            guard attempt < 2 else { return nil }
            let nanos: UInt64 = attempt == 0 ? 1_000_000_000 : 3_000_000_000
            try await Task.sleep(nanoseconds: nanos)
            return try await callAPI(
                text: text, sourceUrl: sourceUrl, model: model, attempt: attempt + 1
            )

        case 529:
            // Anthropic temporary overload — same retry schedule as 429 above.
            guard attempt < 2 else { return nil }
            let nanos: UInt64 = attempt == 0 ? 1_000_000_000 : 3_000_000_000
            try await Task.sleep(nanoseconds: nanos)
            return try await callAPI(
                text: text, sourceUrl: sourceUrl, model: model, attempt: attempt + 1
            )

        default:
            // Includes 413 (payload too large) — caller falls back gracefully.
            return nil
        }
    }

    private static func callAPIWithImages(
        images: [Data],
        sourceUrl: String?,
        model: String,
        attempt: Int
    ) async throws -> VisionParseOutcome {
        var request = URLRequest(url: URL(string: "https://llamascookbook.pages.dev/api/parse")!)
        request.httpMethod = "POST"
        // Vision calls take longer than text — Sonnet on 1-3 page images
        // typically lands in 4-12 s. 60 s gives generous headroom for
        // tail latencies without making a hung request feel infinite.
        request.timeoutInterval = 60
        request.setValue("application/json",              forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01",                    forHTTPHeaderField: "anthropic-version")
        // 1-hour extended cache TTL — meal-planning sessions stretch past the
        // default 5-minute window, so the wider TTL keeps Sonnet warm.
        request.setValue("extended-cache-ttl-2025-04-11", forHTTPHeaderField: "anthropic-beta")
        // Quota enforcement headers — required for photo import.
        request.setValue("photo",                     forHTTPHeaderField: "x-llamas-import-kind")
        if let userId = KeychainStore.read(.appleSub) {
            request.setValue(userId, forHTTPHeaderField: "x-llamas-user")
        }
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "x-llamas-tz")
        #if DEBUG
        request.setValue(AnthropicRecipeParser.testBypassSecret, forHTTPHeaderField: "x-llamas-bypass")
        #endif

        request.httpBody = try buildVisionBody(images: images, model: model)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return VisionParseOutcome() }

        switch http.statusCode {
        case 200:
            let cacheHit = http.value(forHTTPHeaderField: "x-llamas-cache") == "hit"
            let draft    = extractDraft(from: data, sourceUrl: sourceUrl)
            return VisionParseOutcome(draft: draft, cacheHit: cacheHit)

        case 401:
            return VisionParseOutcome(error: .authRequired)

        case 402:
            return VisionParseOutcome(error: .quotaExhausted)

        case 429:
            // Anthropic rate-limit / overload: back off and retry.
            guard attempt < 2 else { return VisionParseOutcome() }
            let nanos: UInt64 = attempt == 0 ? 1_000_000_000 : 3_000_000_000
            try await Task.sleep(nanoseconds: nanos)
            return try await callAPIWithImages(
                images: images, sourceUrl: sourceUrl, model: model, attempt: attempt + 1
            )

        case 529:
            // Anthropic temporary overload — same retry schedule.
            guard attempt < 2 else { return VisionParseOutcome() }
            let nanos: UInt64 = attempt == 0 ? 1_000_000_000 : 3_000_000_000
            try await Task.sleep(nanoseconds: nanos)
            return try await callAPIWithImages(
                images: images, sourceUrl: sourceUrl, model: model, attempt: attempt + 1
            )

        default:
            return VisionParseOutcome()
        }
    }

    // MARK: - Streaming HTTP

    private static func callAPIWithImagesStreaming(
        images: [Data],
        sourceUrl: String?,
        model: String,
        streamingState: StreamingRecipeState,
        attempt: Int
    ) async throws -> VisionParseOutcome {
        var request = URLRequest(url: URL(string: "https://llamascookbook.pages.dev/api/parse")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json",              forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01",                    forHTTPHeaderField: "anthropic-version")
        request.setValue("extended-cache-ttl-2025-04-11", forHTTPHeaderField: "anthropic-beta")
        request.setValue("photo",                         forHTTPHeaderField: "x-llamas-import-kind")
        if let userId = KeychainStore.read(.appleSub) {
            request.setValue(userId, forHTTPHeaderField: "x-llamas-user")
        }
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "x-llamas-tz")
        #if DEBUG
        request.setValue(AnthropicRecipeParser.testBypassSecret, forHTTPHeaderField: "x-llamas-bypass")
        #endif

        request.httpBody = try buildVisionBody(images: images, model: model, stream: true)

        let httpInterval = anthropicSignposter.beginInterval("visionStreamingHTTP")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        defer { anthropicSignposter.endInterval("visionStreamingHTTP", httpInterval) }
        guard let http = response as? HTTPURLResponse else { return VisionParseOutcome() }

        switch http.statusCode {
        case 200:
            let cacheHit = http.value(forHTTPHeaderField: "x-llamas-cache") == "hit"
            if cacheHit {
                // Worker served a buffered JSON body (the assembled tool_use
                // response stored in KV). Drain bytes, parse as non-streaming.
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                let draft = extractDraft(from: data, sourceUrl: sourceUrl)
                return VisionParseOutcome(draft: draft, cacheHit: true)
            }
            return try await consumeSSEStream(
                bytes: bytes,
                sourceUrl: sourceUrl,
                streamingState: streamingState
            )

        case 401:
            return VisionParseOutcome(error: .authRequired)

        case 402:
            return VisionParseOutcome(error: .quotaExhausted)

        case 429:
            // Anthropic rate-limit: back off and retry.
            guard attempt < 2 else { return VisionParseOutcome() }
            let nanos: UInt64 = attempt == 0 ? 1_000_000_000 : 3_000_000_000
            try await Task.sleep(nanoseconds: nanos)
            return try await callAPIWithImagesStreaming(
                images: images, sourceUrl: sourceUrl, model: model,
                streamingState: streamingState, attempt: attempt + 1
            )

        case 529:
            var sink = Data()
            for try await byte in bytes { sink.append(byte) }
            guard attempt < 2 else { return VisionParseOutcome() }
            let nanos: UInt64 = attempt == 0 ? 1_000_000_000 : 3_000_000_000
            try await Task.sleep(nanoseconds: nanos)
            return try await callAPIWithImagesStreaming(
                images: images, sourceUrl: sourceUrl, model: model,
                streamingState: streamingState, attempt: attempt + 1
            )

        default:
            // Drain to free the connection.
            var sink = Data()
            for try await byte in bytes { sink.append(byte) }
            return VisionParseOutcome()
        }
    }

    /// Consume Anthropic's SSE stream. For each `content_block_delta`
    /// with `input_json_delta`, append to the running tool-input buffer
    /// and feed the chunk into the `StreamingRecipeAccumulator` so the
    /// UI sees title / ingredients / steps appear as their JSON objects
    /// close. On `message_stop`, decode the assembled buffer once more
    /// via the canonical `ParsedAPIRecipe` decoder to get the final
    /// post-processed draft.
    private static func consumeSSEStream(
        bytes: URLSession.AsyncBytes,
        sourceUrl: String?,
        streamingState: StreamingRecipeState
    ) async throws -> VisionParseOutcome {
        var accumulator = StreamingRecipeAccumulator()
        var toolName: String? = nil
        var toolJson = ""

        // Per-event state — emitted on each blank line in the SSE stream.
        var currentEventName = "message"
        var currentEventData = ""

        for try await line in bytes.lines {
            if line.isEmpty {
                // Blank line — event boundary.
                if !currentEventData.isEmpty,
                   let payload = parseEventJSON(currentEventData) {
                    let pendingEvents = handleSSEEvent(
                        name: currentEventName,
                        payload: payload,
                        toolName: &toolName,
                        toolJson: &toolJson,
                        accumulator: &accumulator
                    )
                    for event in pendingEvents {
                        await applyEventOnMainActor(event, to: streamingState)
                    }
                }
                currentEventName = "message"
                currentEventData = ""
                continue
            }
            if line.hasPrefix("event:") {
                currentEventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                currentEventData += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
        }

        // Drain any final accumulator state.
        let trailing = accumulator.finalize()
        if !trailing.isEmpty {
            await applyEventsOnMainActor(trailing, to: streamingState)
        }

        // Decode the full assembled tool input as the canonical draft.
        guard toolName == "structured_recipe",
              !toolJson.isEmpty,
              let data = toolJson.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ParsedAPIRecipe.self, from: data) else {
            return VisionParseOutcome()
        }
        let draft = parsed.toDraft(sourceUrl: sourceUrl)
        guard passesQualityGate(draft) else { return VisionParseOutcome() }
        return VisionParseOutcome(draft: draft, cacheHit: false)
    }

    /// Decode the `data:` payload of an SSE event.
    private static func parseEventJSON(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Process one decoded SSE event. Mutates `toolName` / `toolJson` and
    /// the accumulator; returns any new typed events ready for the UI.
    private static func handleSSEEvent(
        name: String,
        payload: [String: Any],
        toolName: inout String?,
        toolJson: inout String,
        accumulator: inout StreamingRecipeAccumulator
    ) -> [StreamingRecipeEvent] {
        switch name {
        case "content_block_start":
            if let cb = payload["content_block"] as? [String: Any],
               (cb["type"] as? String) == "tool_use" {
                toolName = cb["name"] as? String
            }
            return []
        case "content_block_delta":
            guard let delta = payload["delta"] as? [String: Any],
                  (delta["type"] as? String) == "input_json_delta",
                  let partial = delta["partial_json"] as? String else { return [] }
            toolJson += partial
            return accumulator.consume(partial)
        default:
            return []
        }
    }

    @MainActor
    private static func applyEventOnMainActor(
        _ event: StreamingRecipeEvent,
        to state: StreamingRecipeState
    ) {
        state.applyEvent(event)
    }

    @MainActor
    private static func applyEventsOnMainActor(
        _ events: [StreamingRecipeEvent],
        to state: StreamingRecipeState
    ) {
        for event in events {
            state.applyEvent(event)
        }
    }

    // MARK: - Request body

    private static func buildBody(text: String, model: String) throws -> Data {
        let systemBlock: [String: Any] = [
            "type": "text",
            "text": RecipeAIParser.instructions,
            // Cache the ~2 000-token instructions so repeat imports within
            // the 5-minute TTL window hit the cache at 10% of input price.
            // 1-hour TTL via the extended-cache-ttl beta — see callAPI for rationale.
            "cache_control": ["type": "ephemeral", "ttl": "1h"] as [String: Any],
        ]
        let toolChoice: [String: Any] = ["type": "tool", "name": "structured_recipe"]
        let message: [String: Any] = [
            "role": "user",
            "content": "Recipe text to parse:\n\n\(text)",
        ]
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "temperature": 0,
            "system": [systemBlock],
            "tools": [recipeToolDefinition],
            "tool_choice": toolChoice,
            "messages": [message],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Build a vision-mode request body. The user message becomes a
    /// content array: one image block per page (in reading order),
    /// followed by a single text block telling the model what it's
    /// looking at and reminding it to use the same parsing rules.
    ///
    /// The system prompt is identical to the text path so the same
    /// cache entry serves both — repeat imports hit the cached prefix
    /// regardless of whether the user came in via paste or photo.
    ///
    /// - Parameter stream: When true, sets `"stream": true` so Anthropic
    ///   returns SSE deltas. The Worker tees the upstream stream — one
    ///   branch to iOS, one accumulates the assembled tool input for
    ///   the KV cache write.
    private static func buildVisionBody(images: [Data], model: String, stream: Bool = false) throws -> Data {
        var content: [[String: Any]] = []
        for data in images {
            let imageBlock: [String: Any] = [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": data.base64EncodedString(),
                ] as [String: Any],
            ]
            content.append(imageBlock)
        }
        let textBlock: [String: Any] = [
            "type": "text",
            "text": visionUserPrompt(pageCount: images.count),
        ]
        content.append(textBlock)

        let systemBlock: [String: Any] = [
            "type": "text",
            "text": RecipeAIParser.instructions,
            // 1-hour TTL via the extended-cache-ttl beta — see callAPI for rationale.
            "cache_control": ["type": "ephemeral", "ttl": "1h"] as [String: Any],
        ]
        let toolChoice: [String: Any] = ["type": "tool", "name": "structured_recipe"]
        let message: [String: Any] = [
            "role": "user",
            "content": content,
        ]
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "temperature": 0,
            "system": [systemBlock],
            "tools": [recipeToolDefinition],
            "tool_choice": toolChoice,
            "messages": [message],
        ]
        if stream { body["stream"] = true }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// User-message preamble for vision calls. Tells the model how
    /// many pages it's looking at, in what order, and which categories
    /// of source it should expect — printed cookbook pages, magazine
    /// clippings, handwritten cards, screenshots. Compact on purpose;
    /// the heavy guidance still lives in the cached system prompt.
    private static func visionUserPrompt(pageCount: Int) -> String {
        let header = pageCount == 1
            ? "The image above is a single page of a recipe."
            : "The \(pageCount) images above are pages of one recipe in reading order."
        return """
        \(header) The source may be a printed cookbook page, a magazine \
        clipping, a handwritten recipe card, or a screenshot. Read the \
        image(s) directly — use the visible layout (column structure, \
        section headings, callout boxes, sidebar boxes, bold/italic \
        emphasis, indentation) to disambiguate ingredients from steps \
        and to locate the title and metadata. Apply every rule from the \
        system instructions. If two pages are present, treat them as \
        one continuous recipe; ingredient and step lists may span the \
        page break. Do not invent fields that aren't visible in the \
        image — leave them empty per the NEVER FABRICATE rule. On \
        handwritten recipe cards, oven temperature and yield \
        annotations (e.g., '350°F for 30 min', '8 servings') often \
        appear in the top corner — treat these as metadata fields \
        (cookTimeMinutes, servings), never as the recipe title. The \
        title is the recipe name, typically the largest or most \
        prominently written text at the top of the card. If the image \
        contains a two-column ingredient list, read both columns fully \
        before moving on — all items belong to the same recipe. Emit \
        the result via the structured_recipe tool.
        """
    }

    // MARK: - Response parsing

    private static func extractDraft(from data: Data, sourceUrl: String?) -> DraftRecipe? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let blocks = json["content"] as? [[String: Any]]
        else { return nil }

        for block in blocks {
            guard
                block["type"] as? String == "tool_use",
                block["name"] as? String == "structured_recipe",
                let inputObj = block["input"],
                let inputData = try? JSONSerialization.data(withJSONObject: inputObj),
                let parsed = try? JSONDecoder().decode(ParsedAPIRecipe.self, from: inputData)
            else { continue }

            let draft = parsed.toDraft(sourceUrl: sourceUrl)
            return passesQualityGate(draft) ? draft : nil
        }
        return nil
    }

    private static func passesQualityGate(_ draft: DraftRecipe) -> Bool {
        !draft.ingredients.isEmpty || !draft.steps.isEmpty
    }

    // MARK: - Tool definition

    /// JSON schema for the structured_recipe tool. Parsed once at
    /// app start from a JSON literal; avoids deep [String: Any]
    /// nesting which can cause "expression too complex" Swift errors.
    private static let recipeToolDefinition: [String: Any] = {
        let schema = """
        {
          "name": "structured_recipe",
          "description": "Return the recipe parsed from the input text as structured data.",
          "input_schema": {
            "type": "object",
            "required": [
              "title","summary","servings",
              "cookTimeMinutes","prepTimeMinutes",
              "ingredients","steps"
            ],
            "properties": {
              "title": {
                "type": "string",
                "description": "Explicit recipe name only; leave empty if no title is present. Strip @-handles and hashtags."
              },
              "summary": {
                "type": "string",
                "description": "Short blurb if any; empty otherwise."
              },
              "servings": {
                "type": "string",
                "description": "Servings count if stated (e.g. 'Serves 4', 'Yield: 12'). Empty otherwise."
              },
              "cookTimeMinutes": {
                "type": "string",
                "description": "Total cook/bake minutes if stated. Empty otherwise."
              },
              "prepTimeMinutes": {
                "type": "string",
                "description": "Prep minutes if stated separately from cook time. Empty otherwise."
              },
              "ingredients": {
                "type": "array",
                "items": {
                  "type": "object",
                  "required": ["quantity","unit","name"],
                  "properties": {
                    "quantity": {
                      "type": "string",
                      "description": "Number(s) with optional fraction: '2', '1 1/2'. Empty if none."
                    },
                    "unit": {
                      "type": "string",
                      "description": "Singular unit: cup, tbsp, tsp, oz, lb, g, kg, ml, l. Empty if none."
                    },
                    "name": {
                      "type": "string",
                      "description": "Ingredient name only — no quantity, no unit."
                    }
                  }
                }
              },
              "steps": {
                "type": "array",
                "items": {
                  "type": "object",
                  "required": ["text","needsTimer","specialNote"],
                  "properties": {
                    "text": {
                      "type": "string",
                      "description": "Cooking action explicitly stated in the input. No leading 'Step N:' or '1.'."
                    },
                    "needsTimer": {
                      "type": "boolean",
                      "description": "True when the step mentions a duration to time."
                    },
                    "specialNote": {
                      "type": "string",
                      "description": "Parenthetical reminder or 'while X' clause. Empty otherwise."
                    }
                  }
                }
              }
            }
          }
        }
        """
        guard
            let data = schema.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }()
}

// MARK: - Decodable response types

private struct ParsedAPIRecipe: Decodable {
    let title: String
    let summary: String
    let servings: String
    let cookTimeMinutes: String
    let prepTimeMinutes: String
    let ingredients: [Ingredient]
    let steps: [Step]

    struct Ingredient: Decodable {
        let quantity: String
        let unit: String
        let name: String
    }

    struct Step: Decodable {
        let text: String
        let needsTimer: Bool
        let specialNote: String
    }

    /// Convert to `DraftRecipe` using the same post-processing passes
    /// the Apple Intelligence path applies: `cleanTitle`, `enrichAIStep`,
    /// and `mergeOrphanDurationSteps`. Belt-and-suspenders for the cases
    /// where the model drifts from the prompt on edge inputs.
    func toDraft(sourceUrl: String?) -> DraftRecipe {
        var draft = DraftRecipe()
        draft.title = RecipeImporter.cleanTitle(title.trimmed)
        draft.summary = summary.trimmed
        draft.servings = servings.trimmed
        draft.cookTimeMinutes = cookTimeMinutes.trimmed
        draft.prepTimeMinutes = prepTimeMinutes.trimmed
        if let url = sourceUrl, !url.isEmpty {
            draft.sourceUrl = url
        }
        draft.ingredients = ingredients.compactMap { ing in
            let name = ing.name.trimmed
            guard !name.isEmpty else { return nil }
            return DraftIngredient(
                quantity: ing.quantity.trimmed,
                unit: ing.unit.trimmed,
                name: name
            )
        }
        draft.steps = steps.compactMap { s in
            let text = s.text.trimmed
            guard !text.isEmpty else { return nil }
            let note = s.specialNote.trimmed
            let raw = DraftStep(
                text: text,
                needsTimer: s.needsTimer,
                specialNote: note.isEmpty ? nil : note
            )
            return RecipeImporter.enrichAIStep(raw)
        }
        draft.steps = RecipeImporter.mergeOrphanDurationSteps(draft.steps)
        return draft
    }
}
