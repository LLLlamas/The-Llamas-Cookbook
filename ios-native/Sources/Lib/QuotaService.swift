import Foundation

// MARK: - QuotaSnapshot

/// Current photo-import quota state for the signed-in user.
/// Decoded from /api/usage and /api/usage/consume responses.
struct QuotaSnapshot: Codable {
    let plan:      String  // "free" | "pro"
    let limit:     Int
    let used:      Int
    let remaining: Int
    let resetAt:   Date

    var isPro:              Bool { plan == "pro" }
    var isMonthlyExhausted: Bool { remaining <= 0 }

    /// "Jun 1" — the local-timezone monthly reset date formatted for display.
    var resetDateFormatted: String { Formatters.shortMonthDay.string(from: resetAt) }
}

// MARK: - ConsumeResult

enum ConsumeResult {
    case incremented(QuotaSnapshot)
    /// Race-condition cap hit: recipe already saved locally, quota was already
    /// at the limit when consume arrived. iOS shows "this one's on us" banner.
    case race
    case failed
}

// MARK: - QuotaService

/// Manages the photo-import quota state for the signed-in user.
///
/// Polls `/api/usage` on import-sheet open and after consume calls.
/// Results are cached for 60 seconds; a `force: true` refresh bypasses the
/// cache for post-consume updates. `consume()` is called fire-and-forget
/// after a successful local save in `PhotoImportPreviewView`.
@MainActor
@Observable
final class QuotaService {

    private(set) var snapshot: QuotaSnapshot?
    private(set) var isLoading = false

    private var lastFetched: Date?
    private let freshnessDuration: TimeInterval = 60

    private static let baseURL = "https://llamascookbook.pages.dev"

    // MARK: Fetch

    func refresh(force: Bool = false) async {
        guard let userId = KeychainStore.read(.appleSub) else {
            snapshot = nil
            return
        }
        guard force || needsRefresh else { return }

        isLoading = true
        defer { isLoading = false }

        var req = URLRequest(url: URL(string: "\(Self.baseURL)/api/usage")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue(userId, forHTTPHeaderField: "x-llamas-user")
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "x-llamas-tz")

        guard
            let (data, response) = try? await URLSession.shared.data(for: req),
            let http = response as? HTTPURLResponse,
            http.statusCode == 200
        else { return }

        if let decoded = try? isoDecoder.decode(QuotaSnapshot.self, from: data) {
            snapshot = decoded
            lastFetched = Date()
        }
    }

    // MARK: Consume

    /// Increment the monthly save counter. Called immediately after a
    /// successful local recipe save. Fire-and-forget from the caller's side.
    func consume() async -> ConsumeResult {
        guard let userId = KeychainStore.read(.appleSub) else { return .failed }

        var req = URLRequest(url: URL(string: "\(Self.baseURL)/api/usage/consume")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue(userId, forHTTPHeaderField: "x-llamas-user")
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "x-llamas-tz")

        guard
            let (data, response) = try? await URLSession.shared.data(for: req),
            let http = response as? HTTPURLResponse
        else { return .failed }

        switch http.statusCode {
        case 200:
            if let s = try? isoDecoder.decode(QuotaSnapshot.self, from: data) {
                snapshot = s
                lastFetched = Date()
                return .incremented(s)
            }
            return .failed

        case 402:
            // Race-condition cap hit. Schedule a fresh fetch so the pill
            // reflects the real server state after a short KV propagation delay.
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                await refresh(force: true)
            }
            return .race

        default:
            return .failed
        }
    }

    // MARK: Helpers

    private var needsRefresh: Bool {
        guard let last = lastFetched else { return true }
        return Date().timeIntervalSince(last) > freshnessDuration
    }

    private let isoDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
