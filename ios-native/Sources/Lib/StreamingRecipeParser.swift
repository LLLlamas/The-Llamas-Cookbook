import Foundation
import SwiftUI

// MARK: - Streaming events

/// Typed events emitted by the streaming JSON accumulator as Anthropic's
/// `input_json_delta` chunks arrive. Each event corresponds to a fully-
/// formed sub-value of the `structured_recipe` tool input — emitted only
/// after its closing token (`"` for string fields, `}` for object array
/// elements) has been seen, so the UI never has to render half-built
/// values.
enum StreamingRecipeEvent: Equatable {
    case title(String)
    case summary(String)
    case servings(String)
    case cookTimeMinutes(String)
    case prepTimeMinutes(String)
    case ingredient(DraftIngredient)
    case step(DraftStep)
}

// MARK: - Streaming preview state (UI binding)

/// `@Observable` state that the streaming preview UI binds to. Created
/// by `ImportFromPhotoView.runImport` before the Sonnet call; the
/// `parseImagesStreaming` function fills it as bytes arrive. The
/// `onFirstContent` closure fires exactly once when the title token
/// lands — available for timing instrumentation; the overlay dismiss
/// is driven by `PhotoImportPreviewView` observing `title.isEmpty`.
@Observable
@MainActor
final class StreamingRecipeState {
    var title: String = ""
    var summary: String = ""
    var servings: String = ""
    var cookTimeMinutes: String = ""
    var prepTimeMinutes: String = ""
    var ingredients: [DraftIngredient] = []
    var steps: [DraftStep] = []
    var status: Status = .waitingForFirstByte
    /// Set on successful `message_stop`; UI uses this to enable the Save button.
    var finalDraft: DraftRecipe? = nil
    var cacheHit: Bool = false
    /// Wall-clock instant when the very first content event landed. Used by
    /// the instrumentation layer in `ImportFromPhotoView.runImport` to log
    /// `vision_first_byte_ms`. Nil until first content arrives.
    @ObservationIgnored
    var firstContentAt: Date? = nil

    enum Status: Equatable {
        case waitingForFirstByte
        case streaming
        case completed
        case cancelled
        case failed
    }

    @ObservationIgnored
    var onFirstContent: (() -> Void)? = nil
    @ObservationIgnored
    private var firstContentFired = false

    /// True once any content has landed (title or first ingredient/step/summary).
    /// Drives the preview-pop decision in `ImportFromPhotoView`.
    var hasFirstContent: Bool {
        !title.isEmpty ||
        !ingredients.isEmpty ||
        !steps.isEmpty ||
        !summary.isEmpty
    }

    func applyEvent(_ event: StreamingRecipeEvent) {
        switch event {
        case .title(let t):
            title = t
            // Fire as soon as the title lands — drives the overlay dismiss + preview pop.
            // Fallback: first ingredient fires it if the model emits no title.
            if !firstContentFired && !t.isEmpty {
                firstContentFired = true
                firstContentAt   = Date()
                onFirstContent?()
                onFirstContent   = nil
            }
        case .summary(let s):         summary = s
        case .servings(let s):        servings = s
        case .cookTimeMinutes(let c): cookTimeMinutes = c
        case .prepTimeMinutes(let p): prepTimeMinutes = p
        case .ingredient(let i):
            ingredients.append(i)
            if !firstContentFired {
                firstContentFired = true
                firstContentAt   = Date()
                onFirstContent?()
                onFirstContent   = nil
            }
        case .step(let s):            steps.append(s)
        }
        status = .streaming
    }

    func completeStream(finalDraft: DraftRecipe, cacheHit: Bool) {
        self.finalDraft = finalDraft
        self.cacheHit   = cacheHit
        self.status     = .completed
    }

    func cancel() { status = .cancelled }
    func fail()   { status = .failed }

    /// Snapshot the current streamed state as a draft. Used as a fallback
    /// "what we have so far" if the stream dies after producing usable
    /// content but before `message_stop`. The caller should still set the
    /// final draft via `completeStream` when a full parse is available.
    func snapshotDraft() -> DraftRecipe {
        var draft = DraftRecipe()
        draft.title           = title
        draft.summary         = summary
        draft.servings        = servings
        draft.cookTimeMinutes = cookTimeMinutes
        draft.prepTimeMinutes = prepTimeMinutes
        draft.ingredients     = ingredients
        draft.steps           = steps
        return draft
    }
}

// MARK: - Incremental JSON accumulator

/// State machine that accumulates `input_json_delta` chunks from the
/// streaming Anthropic response and emits typed `StreamingRecipeEvent`s
/// as sub-values complete. Specialized to the `structured_recipe`
/// schema — top-level fields are `title`, `summary`, `servings`,
/// `cookTimeMinutes`, `prepTimeMinutes`, `ingredients[]`, `steps[]`.
///
/// Emission discipline:
/// - String fields emit once their closing unescaped `"` has arrived.
/// - Object array elements (ingredient / step) emit once their closing
///   `}` at the array's interior depth has arrived. The currently-in-
///   progress trailing element is never emitted until it closes.
/// - `finalize()` (called on `message_stop`) drains any remaining
///   complete values.
///
/// The accumulator never re-emits a field — it tracks which fields have
/// been emitted via `emittedStringFields` and per-array counters.
struct StreamingRecipeAccumulator {
    private var buffer = ""
    private var emittedStringFields = Set<String>()
    private var ingredientsEmitted  = 0
    private var stepsEmitted        = 0

    /// Append a chunk of `input_json_delta` partial JSON and return any
    /// new events that can be emitted from the buffer's current state.
    mutating func consume(_ chunk: String) -> [StreamingRecipeEvent] {
        buffer += chunk
        return extract(allowIncompleteTrailingArrayObjects: false)
    }

    /// Drain any complete remaining values on stream completion.
    mutating func finalize() -> [StreamingRecipeEvent] {
        extract(allowIncompleteTrailingArrayObjects: false)
    }

    private mutating func extract(allowIncompleteTrailingArrayObjects: Bool) -> [StreamingRecipeEvent] {
        var events: [StreamingRecipeEvent] = []
        guard let json = parseWithAutoClose(buffer) else { return events }

        // String fields — only emit when stable (closing quote present in buffer).
        let stringFields: [(String, (String) -> StreamingRecipeEvent)] = [
            ("title",           StreamingRecipeEvent.title),
            ("summary",         StreamingRecipeEvent.summary),
            ("servings",        StreamingRecipeEvent.servings),
            ("cookTimeMinutes", StreamingRecipeEvent.cookTimeMinutes),
            ("prepTimeMinutes", StreamingRecipeEvent.prepTimeMinutes),
        ]
        for (key, makeEvent) in stringFields {
            guard !emittedStringFields.contains(key) else { continue }
            guard isStringFieldComplete(key, in: buffer) else { continue }
            let value = (json[key] as? String) ?? ""
            if !value.isEmpty {
                events.append(makeEvent(value))
            }
            emittedStringFields.insert(key)
        }

        // Ingredients — emit each complete object.
        if let ings = json["ingredients"] as? [[String: Any]] {
            let complete = countCompleteArrayObjects(arrayKey: "ingredients", in: buffer)
            let limit = allowIncompleteTrailingArrayObjects ? ings.count : complete
            while ingredientsEmitted < limit && ingredientsEmitted < ings.count {
                let ing = ings[ingredientsEmitted]
                let q = (ing["quantity"] as? String)?.trimmed ?? ""
                let u = (ing["unit"]     as? String)?.trimmed ?? ""
                let n = (ing["name"]     as? String)?.trimmed ?? ""
                if !n.isEmpty {
                    events.append(.ingredient(DraftIngredient(quantity: q, unit: u, name: n)))
                }
                ingredientsEmitted += 1
            }
        }

        // Steps — emit each complete object.
        if let stps = json["steps"] as? [[String: Any]] {
            let complete = countCompleteArrayObjects(arrayKey: "steps", in: buffer)
            let limit = allowIncompleteTrailingArrayObjects ? stps.count : complete
            while stepsEmitted < limit && stepsEmitted < stps.count {
                let s     = stps[stepsEmitted]
                let text  = (s["text"]        as? String)?.trimmed ?? ""
                let needs = (s["needsTimer"]  as? Bool) ?? false
                let note  = (s["specialNote"] as? String)?.trimmed ?? ""
                if !text.isEmpty {
                    events.append(.step(DraftStep(
                        text: text,
                        needsTimer: needs,
                        specialNote: note.isEmpty ? nil : note
                    )))
                }
                stepsEmitted += 1
            }
        }

        return events
    }

    // MARK: Parsing helpers

    /// Attempt to parse the buffer as a JSON object by walking the bracket
    /// stack and appending the necessary closing tokens. Returns nil if
    /// the buffer cannot be coerced into valid JSON (e.g. trailing
    /// `,"key` with no value yet) — caller treats that as "not ready".
    private func parseWithAutoClose(_ s: String) -> [String: Any]? {
        if let parsed = tryClose(s) { return parsed }
        // Failed parse — likely a dangling key fragment. Trim back to the
        // last unescaped `,` outside a string and retry. One trim is
        // sufficient for our schema because keys are always paired with
        // values; a partial value is what tryClose can already close.
        if let safer = trimToLastCompleteValue(s) {
            return tryClose(safer)
        }
        return nil
    }

    private func tryClose(_ s: String) -> [String: Any]? {
        var stack: [Character] = []
        var inString = false
        var escaped  = false
        for c in s {
            if escaped { escaped = false; continue }
            if inString {
                if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"":          inString = true
            case "{":           stack.append("}")
            case "[":           stack.append("]")
            case "}", "]":      if !stack.isEmpty { stack.removeLast() }
            default:            break
            }
        }
        var attempt = s
        if inString { attempt += "\"" }
        attempt += String(stack.reversed())
        guard let data = attempt.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Walk backwards from the end of the buffer to the last unescaped
    /// `,` outside a string. Returns the prefix up to (and excluding)
    /// that `,`. If no such position exists, returns nil. Used when
    /// `tryClose` fails because the buffer ends with a key fragment.
    private func trimToLastCompleteValue(_ s: String) -> String? {
        let chars = Array(s)
        var inString = false
        var escaped  = false
        var lastCommaIdx = -1
        for (i, c) in chars.enumerated() {
            if escaped { escaped = false; continue }
            if inString {
                if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"":   inString = true
            case ",":    lastCommaIdx = i
            default:     break
            }
        }
        guard lastCommaIdx > 0 else { return nil }
        return String(chars[..<lastCommaIdx])
    }

    /// True iff the buffer contains `"key": "<value>"` with the closing
    /// quote of the value present (not escaped). The value itself may be
    /// empty; this only signals that the field is "stable" — no more
    /// characters will arrive for it.
    private func isStringFieldComplete(_ key: String, in s: String) -> Bool {
        guard let keyRange = s.range(of: "\"\(key)\"") else { return false }
        var idx = keyRange.upperBound
        // Skip `:` and whitespace
        while idx < s.endIndex && (s[idx] == ":" || s[idx].isWhitespace) {
            idx = s.index(after: idx)
        }
        guard idx < s.endIndex, s[idx] == "\"" else { return false }
        idx = s.index(after: idx)
        // Walk to unescaped closing quote
        var escaped = false
        while idx < s.endIndex {
            let c = s[idx]
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { return true }
            idx = s.index(after: idx)
        }
        return false
    }

    /// Count complete `{...}` objects inside the array named `arrayKey`.
    /// "Complete" = the object's closing `}` has arrived and was not
    /// followed by content suggesting it's still being modified (the
    /// JSON grammar guarantees a `}` ends the object cleanly).
    private func countCompleteArrayObjects(arrayKey: String, in s: String) -> Int {
        guard let keyRange = s.range(of: "\"\(arrayKey)\"") else { return 0 }
        var idx = keyRange.upperBound
        // Find `[`
        while idx < s.endIndex && s[idx] != "[" {
            idx = s.index(after: idx)
        }
        guard idx < s.endIndex else { return 0 }
        idx = s.index(after: idx)

        var depth    = 0
        var inString = false
        var escaped  = false
        var count    = 0
        while idx < s.endIndex {
            let c = s[idx]
            if escaped { escaped = false; idx = s.index(after: idx); continue }
            if inString {
                if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                idx = s.index(after: idx)
                continue
            }
            switch c {
            case "\"":  inString = true
            case "{":   depth += 1
            case "}":
                depth -= 1
                if depth == 0 { count += 1 }
            case "]":
                if depth == 0 { return count }
            default:
                break
            }
            idx = s.index(after: idx)
        }
        return count
    }
}
