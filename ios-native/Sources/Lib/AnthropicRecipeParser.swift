import Foundation

/// Anthropic Claude API client for recipe parsing.
///
/// **Phase 2 (TestFlight only):** The API key is injected at build time
/// via the `ANTHROPIC_API_KEY` build setting → Info.plist, then moved
/// into Keychain on first launch by `provisionKeyIfNeeded()`. The key
/// is technically present in the compiled binary, which is acceptable
/// for internal TestFlight. Before App Store submission, migrate to the
/// Cloudflare Worker proxy (Phase 3 of implement-new-ai-import.md) so
/// the key never ships in a public binary.
///
/// **Structured output:** Forces the model to call the `structured_recipe`
/// tool so the response is always a JSON object matching the recipe schema
/// rather than free-form prose. Malformed or low-quality responses return
/// nil; the caller falls back to the Apple Intelligence path or the regex
/// pipeline unchanged.
///
/// **Prompt caching:** The system block carries `cache_control: ephemeral`
/// so repeat imports within the 5-minute cache TTL cost ~90% less for the
/// ~2,000-token instruction prefix. The beta header is required to activate
/// caching; it has no effect on accounts that haven't opted in.
enum AnthropicRecipeParser {

    // MARK: - Setup

    /// Read the Anthropic API key baked into Info.plist at build time
    /// (via `ANTHROPIC_API_KEY` build setting) and store it in Keychain.
    /// Call once at app start from `LlamasCookbookApp.init()`. Idempotent
    /// — rewrites Keychain whenever the bundle value is non-empty and
    /// valid, which allows key rotation by updating the build setting
    /// without reinstalling the app.
    ///
    /// The `$(...)` guard prevents writing the literal unexpanded
    /// placeholder string that Xcode leaves in Info.plist when
    /// `ANTHROPIC_API_KEY` is undefined in the active build configuration.
    static func provisionKeyIfNeeded() {
        guard
            let bundleKey = Bundle.main.object(forInfoDictionaryKey: "AnthropicAPIKey") as? String,
            !bundleKey.isEmpty,
            !bundleKey.hasPrefix("$(")
        else { return }
        KeychainStore.write(bundleKey, to: .anthropicAPIKey)
    }

    /// True when a non-empty API key is present in Keychain. Used by
    /// `RecipeAIParser.parseBestOf` to gate the Claude path without a
    /// network round-trip.
    static var isConfigured: Bool {
        guard let key = KeychainStore.read(.anthropicAPIKey) else { return false }
        return !key.isEmpty
    }

    // MARK: - Parse

    /// Parse a free-form recipe blob via the Claude Haiku API.
    ///
    /// Returns nil when:
    /// - No API key is configured in Keychain.
    /// - The network call fails or the API returns an error status.
    /// - The model's response fails the minimum quality gate (title +
    ///   at least one ingredient or step).
    ///
    /// Callers treat nil as "fall back to the next parser in the chain"
    /// — never as a hard failure the user sees.
    static func parse(_ text: String, sourceUrl: String?) async -> DraftRecipe? {
        guard let apiKey = KeychainStore.read(.anthropicAPIKey), !apiKey.isEmpty else {
            return nil
        }
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return nil }

        // Cap at ~15 000 chars (≈ 4 000 tokens). Real recipe text rarely
        // exceeds 3 000 chars; the cap prevents runaway cost from a
        // scraper that leaked full page HTML into the text field.
        let capped = trimmed.count > 15_000 ? String(trimmed.prefix(15_000)) : trimmed

        do {
            return try await callAPI(text: capped, sourceUrl: sourceUrl, apiKey: apiKey, attempt: 0)
        } catch {
            return nil
        }
    }

    // MARK: - HTTP

    private static func callAPI(
        text: String,
        sourceUrl: String?,
        apiKey: String,
        attempt: Int
    ) async throws -> DraftRecipe? {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json",          forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey,                      forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",                forHTTPHeaderField: "anthropic-version")
        // Required to activate cache_control blocks on the system prompt.
        request.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")

        request.httpBody = try buildBody(text: text)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }

        switch http.statusCode {
        case 200:
            return extractDraft(from: data, sourceUrl: sourceUrl)

        case 429, 529:
            // Anthropic rate-limit (429) or temporary overload (529).
            // Back off and retry: 1 s then 3 s, 3 attempts total.
            guard attempt < 2 else { return nil }
            let nanos: UInt64 = attempt == 0 ? 1_000_000_000 : 3_000_000_000
            try await Task.sleep(nanoseconds: nanos)
            return try await callAPI(
                text: text, sourceUrl: sourceUrl, apiKey: apiKey, attempt: attempt + 1
            )

        default:
            return nil
        }
    }

    // MARK: - Request body

    private static func buildBody(text: String) throws -> Data {
        let systemBlock: [String: Any] = [
            "type": "text",
            "text": RecipeAIParser.instructions,
            // Cache the ~2 000-token instructions so repeat imports within
            // the 5-minute TTL window hit the cache at 10% of input price.
            "cache_control": ["type": "ephemeral"] as [String: Any],
        ]
        let toolChoice: [String: Any] = ["type": "tool", "name": "structured_recipe"]
        let message: [String: Any] = [
            "role": "user",
            "content": "Recipe text to parse:\n\n\(text)",
        ]
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 2048,
            "system": [systemBlock],
            "tools": [recipeToolDefinition],
            "tool_choice": toolChoice,
            "messages": [message],
        ]
        return try JSONSerialization.data(withJSONObject: body)
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
        !draft.title.trimmed.isEmpty
            && (!draft.ingredients.isEmpty || !draft.steps.isEmpty)
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
                "description": "The recipe name. Strip @-handles and hashtags."
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
                      "description": "The cooking action. No leading 'Step N:' or '1.'."
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
