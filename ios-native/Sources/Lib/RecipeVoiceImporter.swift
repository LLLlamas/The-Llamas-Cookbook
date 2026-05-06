import AVFoundation
import Foundation
import Speech

/// Speech wrapper for the voice-import path. The user dictates a
/// recipe out loud; this wraps iOS 26's `SpeechAnalyzer` /
/// `SpeechTranscriber` to produce a single text blob the existing
/// parser (`RecipeAIParser.parseBestOf` → `RecipeImporter.parse`)
/// can consume — exactly the shape OCR feeds in.
///
/// On-device when the speech asset is installed for the user's
/// locale; the modern transcriber transparently falls back to
/// network when the asset isn't available, gated behind the
/// `NSSpeechRecognitionUsageDescription` consent prompt.
///
/// **Why a cleanup pipeline rather than handing raw transcript to
/// the parser:** dictation says "two cups flour" but the regex
/// pipeline expects "2 cups flour". Homophones like "to/for/ate"
/// land where digits should. Each pass collapses one of those
/// failure modes — scoped to measurement contexts only so prose
/// stays untouched (mirrors `RecipeOCRImporter.repairMeasurementOCR`).
enum RecipeVoiceImporter {

    /// True when the modern on-device transcriber is ready for the
    /// user's locale. Caller treats false as "show the unavailable
    /// banner" — same shape as `RecipeAIParser.isAvailable`.
    static var isAvailable: Bool {
        SpeechTranscriber.isAvailable(locale: preferredLocale())
    }

    /// Locale-aware locale pick for the transcriber. Mirrors the
    /// language list discipline in `RecipeOCRImporter` —
    /// device-current first, en-US fallback.
    static func preferredLocale() -> Locale {
        let current = Locale.current
        if current.language.languageCode != nil {
            return current
        }
        return Locale(identifier: "en-US")
    }

    /// Cooking-domain contextual-strings list. Biases the
    /// transcriber toward canonical units and common cookbook
    /// vocabulary so it stops hearing "tablespoon" as "table spoon"
    /// and "tsp" as "TSP". Mirrors `RecipeOCRImporter.customWords`.
    static let contextualStrings: [String] = {
        var words: [String] = []
        // Section / labelled-format headers users say out loud.
        words += [
            "Ingredients", "Directions", "Instructions",
            "Method", "Steps", "Preparation", "Procedure",
        ]
        // Units — pulled from the canonical list. Plurals included.
        words += [
            "cup","cups","tablespoon","tablespoons",
            "teaspoon","teaspoons","ounce","ounces",
            "pound","pounds","gram","grams","kilogram","kilograms",
            "milligram","milligrams","milliliter","milliliters",
            "liter","liters","pint","pints","quart","quarts",
            "gallon","gallons","clove","cloves","pinch","pinches",
            "dash","dashes","slice","slices","piece","pieces",
            "can","cans","stick","sticks","sprig","sprigs",
            "head","heads","bunch","bunches","handful","handfuls",
        ]
        // Time + temperature
        words += [
            "minute","minutes","hour","hours","second","seconds",
            "Fahrenheit","Celsius","degrees","degree",
        ]
        // Yield / serving vocabulary
        words += [
            "servings","serving","serves","portions","portion",
            "yield","yields","makes","prep","preparation",
        ]
        // Common cookbook nouns / verbs
        words += [
            "flour","sugar","butter","salt","pepper","egg","eggs",
            "yeast","starter","sourdough","baking","powder","soda",
            "vanilla","cinnamon","oregano","basil","garlic","onion",
            "olive","oil","milk","cream","yogurt","cheese","stock",
            "broth","water","oven","skillet","saucepan","parchment",
            "paprika","cumin","turmeric","ginger","nutmeg","cilantro",
            "parsley","cardamom","chocolate","chips",
            "bowl","bowls","pan","pans","sheet","tray","whisk",
            "spatula","mixer","blender","preheat","preheated",
        ]
        words += [
            "Preheat","Combine","Knead","Refrigerate","Bake","Roast",
            "Simmer","Boil","Whisk","Stir","Beat","Fold","Pour",
            "Drizzle","Sprinkle","Place","Remove","Cover","Heat",
            "Cool","Toast","Sear","Reduce","Bring","Allow","Cook",
            "Cut","Chop","Slice","Dice","Mince","Brush","Season",
            "Transfer","Roll","Form","Shape","Stretch",
        ]
        return words
    }()

    /// Run a finalized transcript through every cleanup pass in
    /// dependency order. Each pass collapses a known failure mode
    /// of the downstream parser. Order matters — earlier passes
    /// prepare the text for later regex matching.
    static func cleanup(_ raw: String) -> String {
        var s = raw
        s = normalizeNumberWords(s)
        s = repairMeasurementHomophones(s)
        s = collapseWhitespace(s)
        return s
    }

    // MARK: - Cleanup pipeline

    /// "two cups" → "2 cups", "one quarter teaspoon" → "1/4 teaspoon".
    /// Tightly scoped — only fires when the number word is wedged
    /// between a word boundary and a unit token, so prose like
    /// "the two of us tasted it" stays untouched. Mirrors the
    /// scoping discipline of `repairMeasurementOCR`.
    private static func normalizeNumberWords(_ s: String) -> String {
        let unitClass = "(?:cups?|tbsp|tablespoons?|tsp|teaspoons?|oz|ounces?|lbs?|pounds?|grams?|g|kg|kilograms?|ml|milliliters?|l|liters?|pints?|quarts?|gallons?|cloves?|pinch(?:es)?|dashes?|sticks?|sprigs?|heads?|bunches?|handfuls?|cans?|slices?|pieces?|degrees?)"
        var out = s

        // Compound fraction words: "one quarter cup" → "1/4 cup",
        // "one half teaspoon" → "1/2 teaspoon", "three quarters cup"
        // → "3/4 cup". Order matters — match the longer phrase
        // before the single-word-number pass below would consume "one".
        let fractionPhrases: [(String, String)] = [
            ("one\\s+half", "1/2"),
            ("one\\s+third", "1/3"),
            ("two\\s+thirds", "2/3"),
            ("one\\s+quarter", "1/4"),
            ("one\\s+fourth", "1/4"),
            ("three\\s+quarters", "3/4"),
            ("three\\s+fourths", "3/4"),
            ("one\\s+eighth", "1/8"),
            ("a\\s+half", "1/2"),
            ("a\\s+quarter", "1/4"),
            ("a\\s+third", "1/3"),
            ("a\\s+pinch", "1 pinch"),
            ("a\\s+dash", "1 dash"),
        ]
        for (phrase, replacement) in fractionPhrases {
            out = out.replacingOccurrences(
                of: "(?i)\\b\(phrase)\\s+(\(unitClass))\\b",
                with: "\(replacement) $1",
                options: .regularExpression
            )
        }

        // Single-word numbers + unit. "two cups" → "2 cups".
        let numberWords: [(String, String)] = [
            ("one", "1"), ("two", "2"), ("three", "3"), ("four", "4"),
            ("five", "5"), ("six", "6"), ("seven", "7"), ("eight", "8"),
            ("nine", "9"), ("ten", "10"), ("eleven", "11"), ("twelve", "12"),
        ]
        for (word, digit) in numberWords {
            out = out.replacingOccurrences(
                of: "(?i)\\b\(word)\\s+(\(unitClass))\\b",
                with: "\(digit) $1",
                options: .regularExpression
            )
        }

        // "one and a half cups" → "1 1/2 cups", "two and a half
        // teaspoons" → "2 1/2 teaspoons". Run after the single-word
        // pass so the leading number has already collapsed to a digit.
        out = out.replacingOccurrences(
            of: "(?i)\\b(\\d+)\\s+and\\s+a\\s+half\\s+(\(unitClass))\\b",
            with: "$1 1/2 $2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)\\b(\\d+)\\s+and\\s+a\\s+quarter\\s+(\(unitClass))\\b",
            with: "$1 1/4 $2",
            options: .regularExpression
        )

        return out
    }

    /// Spoken homophones in measurement context only. "to cups" →
    /// "2 cups", "for tablespoons" → "4 tablespoons", "ate ounces"
    /// → "8 ounces". Constrained to <homophone>+<unit> so prose
    /// like "add to the bowl" or "for best results" survives
    /// untouched. Same conservative scoping as
    /// `repairMeasurementOCR`'s digit-letter-digit rules.
    private static func repairMeasurementHomophones(_ s: String) -> String {
        let unitClass = "(?:cups?|tbsp|tablespoons?|tsp|teaspoons?|oz|ounces?|lbs?|pounds?|grams?|g|kg|kilograms?|ml|milliliters?|l|liters?|pints?|quarts?|gallons?|cloves?|sticks?|sprigs?|heads?|bunches?|handfuls?|cans?|slices?|pieces?|degrees?)"
        var out = s
        let pairs: [(String, String)] = [
            ("to", "2"),
            ("too", "2"),
            ("for", "4"),
            ("fore", "4"),
            ("ate", "8"),
        ]
        for (word, digit) in pairs {
            out = out.replacingOccurrences(
                of: "(?i)\\b\(word)\\s+(\(unitClass))\\b",
                with: "\(digit) $1",
                options: .regularExpression
            )
        }
        return out
    }

    /// Multi-space runs collapse to a single space; multiple blank
    /// lines collapse to a single blank line so the block-format
    /// parser sees clean separators.
    private static func collapseWhitespace(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return out
    }
}

// MARK: - Live recording session

/// Driver for an in-progress voice import. Owns the AVAudioEngine
/// tap and the `SpeechAnalyzer` pipeline. Surfaces a published
/// `transcript` so the recording UI can render a live preview, and
/// a `finish()` that returns the cleaned final transcript ready to
/// feed `RecipeAIParser.parseBestOf`.
@MainActor
@Observable
final class VoiceImportSession {
    /// Live transcript — partial results are surfaced as the user
    /// speaks so the UI can update in real time. On `finish()` this
    /// holds the finalized text for one last pass through cleanup.
    private(set) var transcript: String = ""
    /// True between `start()` and `finish()` / `cancel()`.
    private(set) var isRecording: Bool = false
    /// Most recent error surfaced by the audio engine or the
    /// transcriber. UI consumes via observation.
    private(set) var errorMessage: String?

    private var engineHolder: AudioEngineHolder?
    private var modernSession: ModernTranscribeSession?

    /// Pre-warm the speech model so the first tap of Record doesn't
    /// stall on a cold model load. Safe to call multiple times.
    func prepare() async {
        await ModernTranscribeSession.prewarm(
            locale: RecipeVoiceImporter.preferredLocale()
        )
    }

    /// Request authorization (mic + speech recognition) and start
    /// recording. Sets `errorMessage` and returns false on any
    /// failure path so the caller can surface a banner.
    func start() async -> Bool {
        guard !isRecording else { return true }
        errorMessage = nil
        transcript = ""

        let speechAuthorized = await Self.requestSpeechAuthorization()
        guard speechAuthorized else {
            errorMessage = "Speech recognition isn't authorized. Enable it in Settings → Privacy → Speech Recognition."
            return false
        }

        do {
            let holder = try AudioEngineHolder()
            engineHolder = holder

            let session = try await ModernTranscribeSession.start(
                engine: holder,
                onPartial: { [weak self] partial in
                    Task { @MainActor in self?.transcript = partial }
                }
            )
            modernSession = session
            isRecording = true
            return true
        } catch {
            errorMessage = "Couldn't start recording. \(error.localizedDescription)"
            await teardown()
            return false
        }
    }

    /// Stop recording and return the cleaned final transcript. Nil
    /// when nothing was captured. Always tears down audio resources
    /// regardless of result.
    func finish() async -> String? {
        guard isRecording else { return nil }
        let final: String
        if let session = modernSession {
            final = (try? await session.finalize()) ?? transcript
        } else {
            final = transcript
        }
        await teardown()
        let cleaned = RecipeVoiceImporter.cleanup(final)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cleaned
    }

    /// Cancel without producing a transcript. Always safe to call.
    func cancel() async {
        await teardown()
    }

    private func teardown() async {
        isRecording = false
        if let session = modernSession {
            await session.stop()
            modernSession = nil
        }
        engineHolder?.stop()
        engineHolder = nil
    }

    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

// MARK: - Audio engine holder

/// Owns the shared audio-session activation + AVAudioEngine + input
/// tap. The transcribe pipeline feeds off the buffer stream — the
/// holder lets us swap pipelines without re-plumbing the engine.
final class AudioEngineHolder {
    let engine: AVAudioEngine
    let inputFormat: AVAudioFormat
    private var bufferHandlers: [(AVAudioPCMBuffer, AVAudioTime) -> Void] = []
    private let handlerQueue = DispatchQueue(label: "com.llamascookbook.voice.handlers")

    init() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            let handlers = self.handlerQueue.sync { self.bufferHandlers }
            for handler in handlers {
                handler(buffer, when)
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.inputFormat = format
    }

    func addHandler(_ handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        handlerQueue.sync { bufferHandlers.append(handler) }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Modern (iOS 26+) transcribe session

final class ModernTranscribeSession {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let resultTask: Task<Void, Never>

    private init(
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        resultTask: Task<Void, Never>
    ) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.inputBuilder = inputBuilder
        self.resultTask = resultTask
    }

    /// Pre-fetch the speech asset for the requested locale so the
    /// first record tap doesn't stall on a model download. Best-
    /// effort — failure here just means the first start() pays the
    /// download cost as before.
    static func prewarm(locale: Locale) async {
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveLiveTranscription
        )
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try? await request.downloadAndInstall()
        }
    }

    static func start(
        engine: AudioEngineHolder,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> ModernTranscribeSession {
        let locale = RecipeVoiceImporter.preferredLocale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveLiveTranscription
        )
        transcriber.contextualStrings = RecipeVoiceImporter.contextualStrings

        // Make sure the speech asset is installed before we start
        // streaming audio — without this, the first analyzer call
        // throws on a clean install.
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try? await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        try await analyzer.start(inputSequence: inputStream)

        // Forward live results to the partial-results callback. Each
        // result carries an attributed string; we collect finalized
        // segments + the most recent volatile one so the UI sees a
        // smooth running transcript.
        let resultTask = Task { @Sendable in
            var finalizedSegments: [String] = []
            for await result in transcriber.results {
                let textValue = String(result.text.characters)
                if result.isFinal {
                    finalizedSegments.append(textValue)
                }
                let combined = (finalizedSegments + (result.isFinal ? [] : [textValue]))
                    .joined(separator: " ")
                let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
                onPartial(trimmed)
            }
        }

        // Bridge the AVAudioEngine tap into the analyzer input stream.
        engine.addHandler { buffer, when in
            let input = AnalyzerInput(buffer: buffer, presentationTime: when)
            inputContinuation.yield(input)
        }

        return ModernTranscribeSession(
            analyzer: analyzer,
            transcriber: transcriber,
            inputBuilder: inputContinuation,
            resultTask: resultTask
        )
    }

    func finalize() async throws -> String {
        inputBuilder.finish()
        try await analyzer.finalizeAndFinish(through: .infinity)
        var collected: [String] = []
        for await result in transcriber.results where result.isFinal {
            collected.append(String(result.text.characters))
        }
        resultTask.cancel()
        return collected.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stop() async {
        inputBuilder.finish()
        try? await analyzer.cancelAndFinishNow()
        resultTask.cancel()
    }
}
