import Foundation

/// On-disk snapshot of an in-progress Cook Mode session. Persisted to
/// UserDefaults whenever the user makes progress (checks an ingredient,
/// strikes a step, starts/extends a timer, switches phase). Restored on
/// app launch so a backgrounded-then-killed app, a notification tap that
/// re-launches us cold, or any other interrupt still drops the user back
/// where they left off — same recipe, same checkmarks, same running timer.
struct CookingSessionState: Codable, Equatable {
    let recipeID: UUID
    var phase: PersistedPhase
    var currentServings: Int
    var struckIngredientIDs: [UUID]
    var struckStepIDs: [UUID]
    var timerEndsAt: Date?
    var timerStepID: UUID?
    var timerLabel: String
    var timerOriginalMinutes: Int

    enum PersistedPhase: String, Codable {
        case prep, cook
    }
}

enum CookingSessionStore {
    /// Versioned key — bump the suffix if the struct shape ever changes
    /// in a non-additive way so old payloads decode-fail and clear out.
    private static let key = "cooking-session-state.v1"

    static func load() -> CookingSessionState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CookingSessionState.self, from: data)
    }

    static func save(_ state: CookingSessionState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
