import Foundation

/// Coordinator that mirrors the local user's identity into the public
/// CloudKit `UserProfile` record. Friends read these records through
/// the Friends UI in slice 4+ to render display names, accent colors,
/// last-cooked items, and the presence-now glow.
///
/// **Design.** Static-method enum (matching `CloudKitService`'s
/// pattern). Stateless from the caller's perspective — every observable
/// that owns a relevant local field calls into the mirror's methods on
/// change. The mirror handles the cache, debouncing, and best-effort
/// network semantics internally.
///
/// **Cache strategy.** The iCloud user record name (returned by
/// `CloudKitService.fetchCurrentUserRecordID`) is cached in
/// UserDefaults after the first successful fetch on
/// `bindAfterSignIn`. All subsequent mirror calls read from cache —
/// no per-call iCloud round-trip — and silently no-op when the cache
/// is nil. Cleared on sign-out and account deletion.
///
/// **Best-effort semantics.** Every mirror call is fire-and-forget
/// from the caller's perspective. Underlying CloudKit failures
/// (network, throttling, account unavailable, schema not yet
/// deployed) are silently swallowed — these features degrade
/// gracefully when the cloud isn't reachable, and the local UX
/// never blocks on them. Mirrors the existing share-flow's
/// iCloud-unavailable handling.
///
/// **iCloud-not-signed-in.** A user with SIWA but no iCloud account
/// produces a nil cached record name on `bindAfterSignIn`; every
/// subsequent mirror call is a silent no-op until iCloud is enabled.
/// The user gets normal local functionality minus the friends/cloud
/// features — no error UI.
///
/// **Debouncing.** The accent-color update fires per slider tick
/// (the SwiftUI `ColorPicker` calls didSet 30+ times per second
/// during a drag). A 2-second cancellable debounce coalesces these
/// into one network write — last value wins.
enum UserProfileMirror {
    /// UserDefaults key for the iCloud user record name cache.
    /// Versioned so a future schema migration can invalidate the
    /// cache without wiping all of UserDefaults.
    private static let cachedRecordIDKey = "userProfileMirror.cloudKitRecordID.v1"

    /// Cancel-able debounce slot for accent-color updates. Module-
    /// level static is safe — every caller is on the main actor and
    /// the cancel-and-replace pattern explicitly handles concurrent
    /// calls.
    private static var accentDebounceTask: Task<Void, Never>?

    // MARK: - Cache

    /// The iCloud user record name for the currently-bound local
    /// user. Nil when signed out or when iCloud was unavailable at
    /// `bindAfterSignIn` time. Read by every field-update method
    /// before attempting a CloudKit write.
    static func cachedRecordID() -> String? {
        UserDefaults.standard.string(forKey: cachedRecordIDKey)
    }

    private static func setCachedRecordID(_ id: String?) {
        if let id = id {
            UserDefaults.standard.set(id, forKey: cachedRecordIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cachedRecordIDKey)
        }
    }

    // MARK: - Sign-in / sign-out lifecycle

    /// Bind the local user to their iCloud user record name and
    /// write the initial UserProfile mirror. Called from
    /// `UserAccount.completeSignIn` after a successful SIWA flow.
    /// Best-effort — silently no-ops when iCloud is unavailable.
    ///
    /// `accentHex` is read from the live `AppearanceSettings` at
    /// call time; passed by the caller so this enum doesn't need a
    /// reference to the appearance Observable.
    static func bindAfterSignIn(
        displayName: String,
        accentHex: String?
    ) async {
        guard let recordID = await CloudKitService.fetchCurrentUserRecordID() else {
            return
        }
        setCachedRecordID(recordID)
        try? await CloudKitService.upsertUserProfile(userRecordName: recordID) { record in
            record["displayName"] = displayName as NSString
            if let hex = accentHex {
                record["accentHex"] = hex as NSString
            }
            // createdAt is set inside `upsertUserProfile` only on first
            // creation — preserves the original "joined" date across
            // sign-out/sign-back-in cycles on the same Apple ID.
        }
    }

    /// Drop the cache so subsequent mirror calls no-op until a
    /// `bindAfterSignIn` re-binds. Does NOT delete the CloudKit
    /// record — the user can sign back in on any device and re-bind
    /// to the same UserProfile (display name, friend graph, last-
    /// cooked all preserved). For full deletion, callers go through
    /// `deleteOnAccountDeletion()` instead.
    static func clearAfterSignOut() {
        accentDebounceTask?.cancel()
        accentDebounceTask = nil
        setCachedRecordID(nil)
    }

    /// Account-deletion cascade. Deletes the UserProfile record on
    /// the cloud in addition to clearing the local cache. Friendship
    /// and PublishedRecipe records get wiped by their own slices'
    /// cascade extensions (slice 2 and slice 3 respectively).
    static func deleteOnAccountDeletion() async {
        accentDebounceTask?.cancel()
        accentDebounceTask = nil
        let recordID = cachedRecordID()
        setCachedRecordID(nil)
        guard let recordID = recordID else { return }
        try? await CloudKitService.deleteUserProfile(userRecordName: recordID)
    }

    // MARK: - Field updates

    /// Push a new display name. Called from
    /// `UserAccount.updateDisplayName` after the local Keychain
    /// write completes.
    static func updateDisplayName(_ name: String) async {
        guard let recordID = cachedRecordID() else { return }
        try? await CloudKitService.upsertUserProfile(userRecordName: recordID) { record in
            record["displayName"] = name as NSString
        }
    }

    /// Push a new accent color. Debounced 2 seconds — the SwiftUI
    /// color picker fires didSet on every drag tick during a slider
    /// drag, and we don't want to spam the cloud with ~30 writes/s.
    /// Cancellable; the latest value wins. Called synchronously
    /// from `AppearanceSettings.accentColor.didSet`.
    static func updateAccent(_ hex: String) {
        accentDebounceTask?.cancel()
        accentDebounceTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard let recordID = cachedRecordID() else { return }
            try? await CloudKitService.upsertUserProfile(userRecordName: recordID) { record in
                record["accentHex"] = hex as NSString
            }
        }
    }

    // MARK: - Cooking lifecycle

    /// Record that the local user just started (or is continuing) a
    /// cook. Sets `cookingStartedAt = .now` unconditionally — the
    /// "preserve original start time" semantic isn't surfaced
    /// anywhere in the UI; all that matters is the 6-hour staleness
    /// window for the friends-list dot. Always-set avoids a stale-
    /// data bug where a previous force-killed session's
    /// `cookingStartedAt` (now >6h old, friends already see "not
    /// cooking") would be preserved and friends would never see the
    /// dot turn back on for the new session. Called from
    /// `CookingSession.start` and `addParallel`.
    static func recordCookStarted() async {
        guard let recordID = cachedRecordID() else { return }
        try? await CloudKitService.upsertUserProfile(userRecordName: recordID) { record in
            record["cookingStartedAt"] = Date() as NSDate
        }
    }

    /// Record that the local user has zero active cooks. Clears
    /// `cookingStartedAt`. Called from `CookingSession.endAll`,
    /// which fires on the transition to an empty session (last cook
    /// removed, end-all from cover close, kill-everything path).
    static func recordCookSessionEmpty() async {
        guard let recordID = cachedRecordID() else { return }
        try? await CloudKitService.upsertUserProfile(userRecordName: recordID) { record in
            record["cookingStartedAt"] = nil
        }
    }

    /// Record a cook completion. Updates `lastCookedAt`,
    /// `lastCookedRecipeID`, and `lastCookedTitle`. Called next to
    /// `Recipe.markCooked()` at the existing call sites in
    /// `CookModeView`. The recipe model itself stays mirror-
    /// agnostic — the cloud-side fan-out is a UI-layer concern.
    static func recordCookCompleted(recipeID: UUID, recipeTitle: String) async {
        guard let recordID = cachedRecordID() else { return }
        try? await CloudKitService.upsertUserProfile(userRecordName: recordID) { record in
            record["lastCookedAt"] = Date() as NSDate
            record["lastCookedRecipeID"] = recipeID.uuidString as NSString
            record["lastCookedTitle"] = recipeTitle as NSString
        }
    }
}
