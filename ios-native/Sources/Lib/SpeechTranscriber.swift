import Foundation
import Speech

/// On-device transcription of a local audio/video file. Used by the
/// Instagram-reel import path to pull spoken instructions out of a reel
/// when the caption alone doesn't carry the full recipe.
///
/// We deliberately use `SFSpeechRecognizer` with
/// `requiresOnDeviceRecognition = true` rather than iOS 26's newer
/// `SpeechAnalyzer`. Reasons:
///   • SFSpeechRecognizer has a decade of stability and well-known
///     edge-case behavior.
///   • The 1-minute hard limit on a single recognition request matches
///     the dominant reel length (<60s); longer reels degrade to a
///     partial transcript which still feeds the AI parser usefully.
///   • Migrating to `SpeechAnalyzer` is a future upgrade once we have
///     real reel data showing >60s spoken instructions are common.
///
/// Permission: `NSSpeechRecognitionUsageDescription` in AppInfo.plist
/// is required for the authorization prompt — the very first call
/// blocks on the system dialog.
enum SpeechTranscriber {
    enum TranscriptionError: Error {
        case permissionDenied
        case recognizerUnavailable
        case noSpeechDetected
        case underlying(Error)
    }

    /// Transcribe the audio track of a local file URL (audio or video).
    /// Returns the final transcript text. Throws `permissionDenied` if
    /// the user has refused speech recognition, `recognizerUnavailable`
    /// if the locale has no on-device recognizer, `noSpeechDetected`
    /// when the recognizer finalizes with an empty transcript (silent
    /// reel / music-only soundtrack), and `underlying(_)` for anything
    /// else the recognizer surfaces.
    static func transcribe(fileURL: URL) async throws -> String {
        try await ensureAuthorized()

        let candidateLocales = [Locale.current, Locale(identifier: "en-US")]
        guard let recognizer = candidateLocales
                .lazy
                .compactMap({ SFSpeechRecognizer(locale: $0) })
                .first(where: { $0.isAvailable && $0.supportsOnDeviceRecognition })
        else {
            throw TranscriptionError.recognizerUnavailable
        }
        recognizer.defaultTaskHint = .dictation

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            // SFSpeechRecognizer's callback can technically fire more
            // than once (interim + final, even with partial results
            // disabled on some iOS minor versions). Continuations may
            // only resume once — gate explicitly.
            let lock = NSLock()
            var resumed = false
            func resume(_ result: Result<String, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let s): cont.resume(returning: s)
                case .failure(let e): cont.resume(throwing: e)
                }
            }

            recognizer.recognitionTask(with: request) { recognitionResult, error in
                if let error {
                    resume(.failure(TranscriptionError.underlying(error)))
                    return
                }
                guard let recognitionResult, recognitionResult.isFinal else { return }
                let text = recognitionResult.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    resume(.failure(TranscriptionError.noSpeechDetected))
                } else {
                    resume(.success(text))
                }
            }
        }
    }

    private static func ensureAuthorized() async throws {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in cont.resume() }
            }
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return
        case .denied, .restricted, .notDetermined:
            throw TranscriptionError.permissionDenied
        @unknown default:
            throw TranscriptionError.permissionDenied
        }
    }
}
