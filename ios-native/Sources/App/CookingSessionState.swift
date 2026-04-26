import Foundation

/// On-disk snapshot of one in-progress cook. Persisted whenever the user
/// makes progress (checks an ingredient, strikes a step, starts/extends
/// a timer, switches phase). Restored on app launch so a backgrounded-
/// then-killed app, a notification tap that re-launches us cold, or any
/// other interrupt still drops the user back where they left off — same
/// recipe, same checkmarks, same running timer.
///
/// The store ([CookingSessionStore]) holds an *array* of these so PR 2
/// can light up parallel cooking; PR 1 always holds 0 or 1.
struct CookingSessionState: Codable, Equatable {
    /// Distinct identity per active cook — not the same as `recipeID`
    /// because PR 2 will admit two parallel cooks of the same recipe.
    /// Synthesized fresh on a legacy v1 payload decode (which had no
    /// cookID field).
    let cookID: UUID
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

    init(
        cookID: UUID = UUID(),
        recipeID: UUID,
        phase: PersistedPhase,
        currentServings: Int,
        struckIngredientIDs: [UUID],
        struckStepIDs: [UUID],
        timerEndsAt: Date?,
        timerStepID: UUID?,
        timerLabel: String,
        timerOriginalMinutes: Int
    ) {
        self.cookID = cookID
        self.recipeID = recipeID
        self.phase = phase
        self.currentServings = currentServings
        self.struckIngredientIDs = struckIngredientIDs
        self.struckStepIDs = struckStepIDs
        self.timerEndsAt = timerEndsAt
        self.timerStepID = timerStepID
        self.timerLabel = timerLabel
        self.timerOriginalMinutes = timerOriginalMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case cookID, recipeID, phase, currentServings,
             struckIngredientIDs, struckStepIDs,
             timerEndsAt, timerStepID, timerLabel, timerOriginalMinutes
    }

    /// Custom decoder that synthesizes `cookID` for legacy v1 payloads
    /// (single-cook era — never carried an explicit cook identity).
    /// Without this, decoding a v1 blob into the v2 type would throw on
    /// the missing `cookID` key. The synthesized UUID is stable from
    /// that point forward because the migration immediately re-saves
    /// the record under the v2 key (see CookingSessionStore.load).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.cookID = (try c.decodeIfPresent(UUID.self, forKey: .cookID)) ?? UUID()
        self.recipeID = try c.decode(UUID.self, forKey: .recipeID)
        self.phase = try c.decode(PersistedPhase.self, forKey: .phase)
        self.currentServings = try c.decode(Int.self, forKey: .currentServings)
        self.struckIngredientIDs = try c.decode([UUID].self, forKey: .struckIngredientIDs)
        self.struckStepIDs = try c.decode([UUID].self, forKey: .struckStepIDs)
        self.timerEndsAt = try c.decodeIfPresent(Date.self, forKey: .timerEndsAt)
        self.timerStepID = try c.decodeIfPresent(UUID.self, forKey: .timerStepID)
        self.timerLabel = try c.decode(String.self, forKey: .timerLabel)
        self.timerOriginalMinutes = try c.decode(Int.self, forKey: .timerOriginalMinutes)
    }
}

enum CookingSessionStore {
    /// v2 key — array of states, one element per active cook. Bumped
    /// from v1 (single state) when multi-recipe Cook Mode landed.
    private static let key = "cooking-session-states.v2"

    /// Legacy v1 key — single CookingSessionState, single-cook era.
    /// Read once on first launch under v2 code, migrated into the new
    /// shape, and removed.
    private static let legacyKeyV1 = "cooking-session-state.v1"

    /// Load the current set of cooks from disk. Tries v2 first; falls
    /// back to a one-shot v1 → v2 migration when no v2 payload exists
    /// yet. Returns an empty array when the user has no active cooks.
    static func load() -> [CookingSessionState] {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([CookingSessionState].self, from: data) {
            return decoded
        }
        // v1 → v2 migration: wrap the single-cook payload in a
        // 1-element array, save under the new key, drop the old key.
        // Fires once per device, the first time v2 code runs against a
        // disk left over from v1. A user mid-cook during the upgrade
        // keeps their session.
        if let data = UserDefaults.standard.data(forKey: legacyKeyV1),
           let single = try? JSONDecoder().decode(CookingSessionState.self, from: data) {
            UserDefaults.standard.removeObject(forKey: legacyKeyV1)
            save([single])
            return [single]
        }
        return []
    }

    static func save(_ states: [CookingSessionState]) {
        guard let data = try? JSONEncoder().encode(states) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
