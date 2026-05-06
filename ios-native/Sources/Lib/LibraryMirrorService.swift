import Foundation
import SwiftUI
import SwiftData
import CloudKit

/// Coordinator for mirroring the local user's library into the public
/// CloudKit `PublishedRecipe` record type. Friends read these in
/// slice 4's `FriendLibraryView`. The service runs as a singleton
/// because the editor save path, the deletion path, and the bulk-
/// publish-on-first-friend trigger all need to converge on the same
/// debounce queue (otherwise a Save followed by a delete-from-Library
/// could race).
///
/// **Why mirror at all.** Slice 1 (`UserProfileMirror`) handles per-
/// user identity; slice 3 handles the recipe corpus. They're
/// complementary: friends see who you are via UserProfile and what
/// you cook via PublishedRecipe.
///
/// **Debounce model.** The editor's Save flow can hit-Save four
/// times in quick succession (typo correction, last-minute photo
/// add). Per-recipe debounce of 5 seconds collapses these into one
/// network upload. Each Recipe.id has its own debounce slot — a
/// busy editing session across multiple recipes doesn't cause one
/// recipe's upload to delay another's.
///
/// **Best-effort semantics.** Mirrors the existing share flow's
/// degradation: silent no-op when iCloud unavailable / schema not
/// deployed / network down. Local app continues to function; the
/// friend-side view just doesn't see the latest version of a
/// recipe until the next successful upload.
///
/// **Bulk publish on first friend.** A user with existing recipes
/// who later gets their first friend wouldn't have any of those
/// recipes published — the per-save mirror only fires on touch.
/// `bulkPublishIfNeeded(_:)` covers this one-time backfill,
/// gated by a UserDefaults flag so the bulk run only happens
/// once per device.
@MainActor
@Observable
final class LibraryMirrorService {
    /// Single instance — referenced from RecipeEditorView, the two
    /// recipe-delete sites (LibraryView, RecipeDetailView), and
    /// ProfileView (for the first-friend bulk trigger). Singleton
    /// avoids threading the service through every layer's
    /// environment chain when it's effectively a static helper with
    /// per-recipe debounce state.
    static let shared = LibraryMirrorService()

    /// UserDefaults key for the one-time bulk-publish marker. The
    /// `.v1` suffix lets a future schema migration force a re-bulk
    /// without wiping all of UserDefaults.
    nonisolated private static let bulkPublishedKey = "libraryMirror.didBulkPublish.v1"

    /// Per-recipe debounce slots. Editor saves the same recipe four
    /// times → four cancels + a single delayed upload at the tail.
    /// Editing a different recipe doesn't interfere with the first
    /// one's pending save.
    private var pendingUploads: [UUID: Task<Void, Never>] = [:]

    /// Per-recipe debounce window. Long enough that the editor's
    /// auto-save chatter coalesces; short enough that a friend
    /// looking at the user's library within ~10 seconds of a save
    /// sees the latest content.
    private static let uploadDebounce: Duration = .seconds(5)

    private init() {}

    // MARK: - Public API

    /// Schedule a debounced mirror upload for `recipe`. Called from
    /// `RecipeEditorView.save` after the local SwiftData save. If
    /// another upload for the same recipe is already pending, it's
    /// canceled and replaced with this one — net effect: one upload
    /// `uploadDebounce` after the user stops mashing Save.
    ///
    /// Slice 5 chain attribution: the published envelope's
    /// `sharedBy` and the parent record's `originalCreatorID` /
    /// `originalRecipeID` fields are all derived from the local
    /// recipe's `originalCreator*` / `originalRecipeID` fields. For
    /// own-authored recipes those are nil; for recipes the user
    /// imported from a friend they carry the chain root's identity
    /// forward so a downstream importer preserves the chain.
    ///
    /// Bytes are extracted on the main actor synchronously (to
    /// satisfy `Recipe`'s `@Model`-bound access) and then handed off
    /// to a Task that does the network round-trip off-main.
    func enqueueUpsert(_ recipe: Recipe) {
        guard let ownerID = UserProfileMirror.cachedRecordID() else {
            // No iCloud / not signed in — skip silently.
            return
        }

        let recipeID = recipe.id
        let appVersion = AppMetadata.currentAppVersion
        // Capture the live SwiftData reference for the @MainActor
        // upsert call. The Task body runs on @MainActor (inherits
        // from the caller), so reading recipe inside is safe.
        pendingUploads[recipeID]?.cancel()
        pendingUploads[recipeID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.uploadDebounce)
            if Task.isCancelled { return }

            // Re-fetch under the assumption the live `recipe`
            // reference may have been deallocated by SwiftData
            // between the schedule and the firing (rare but
            // possible if the recipe was deleted mid-debounce).
            // The deletion path would have already enqueued a
            // delete; this Task fires harmlessly against a now-
            // already-deleted record.
            try? await CloudKitService.upsertPublishedRecipe(
                ownerID: ownerID,
                sharedBy: recipe.originalCreatorDisplayName,
                appVersion: appVersion,
                recipe: recipe,
                originalCreatorID: recipe.originalCreatorUserRecordName,
                originalRecipeID: recipe.originalRecipeID
            )
            self?.pendingUploads.removeValue(forKey: recipeID)
        }
    }

    /// Delete the cloud-side mirror for a recipe. Called from the
    /// two delete sites (`LibraryView` long-press, `RecipeDetailView`
    /// menu) **before** the local `modelContext.delete(recipe)`.
    /// Cancels any pending upload for the same recipe so we don't
    /// race a publish-after-delete. Best-effort — silent on iCloud
    /// unavailability.
    func deleteRecipe(recipeID: UUID) {
        pendingUploads[recipeID]?.cancel()
        pendingUploads.removeValue(forKey: recipeID)
        Task.detached {
            try? await CloudKitService.deletePublishedRecipe(localRecipeID: recipeID)
        }
    }

    /// One-shot backfill triggered the first time the user gains a
    /// friend (FriendsStore.friends transitions from 0 → 1+). Iterates
    /// the local library and publishes everything that hasn't been
    /// published yet. Subsequent calls are no-ops thanks to the
    /// UserDefaults flag.
    ///
    /// Called from `ProfileView`'s `.onChange(of: friendsStore.friends.count)`
    /// where `@Query` already has the recipes in scope.
    func bulkPublishIfNeeded(recipes: [Recipe]) async {
        let alreadyDone = UserDefaults.standard.bool(forKey: Self.bulkPublishedKey)
        guard !alreadyDone else { return }
        guard let ownerID = UserProfileMirror.cachedRecordID() else { return }
        guard !recipes.isEmpty else {
            // Empty library — flip the flag anyway so we don't
            // re-attempt every refresh. Future saves will publish
            // through the per-save path.
            UserDefaults.standard.set(true, forKey: Self.bulkPublishedKey)
            return
        }

        let appVersion = AppMetadata.currentAppVersion
        // Sequential to avoid swamping CloudKit + the iOS network
        // queue. For a user with 100 recipes this is ~100 round
        // trips; serializing keeps the device polite. Failures
        // don't abort the loop — best-effort, the per-save path
        // catches future updates anyway.
        //
        // Chain attribution per recipe — recipes the user imported
        // from a friend keep their chain root identifiers in the
        // published record, so a downstream importer preserves
        // attribution. Own-authored recipes pass nil, which the
        // upsert clears on the cloud record.
        for recipe in recipes {
            try? await Self.upsertWithThrottleBackoff(
                ownerID: ownerID,
                appVersion: appVersion,
                recipe: recipe
            )
        }
        UserDefaults.standard.set(true, forKey: Self.bulkPublishedKey)
    }

    /// Reset the bulk-publish marker. Called from sign-out and
    /// account-deletion paths so a sign-in on a different Apple ID
    /// (or a fresh re-sign-in after delete) gets a fresh bulk-publish
    /// opportunity. Safe to call when the marker is already unset.
    /// `nonisolated` because the body only touches thread-safe
    /// `UserDefaults` — the class-level `@MainActor` is to protect
    /// the per-recipe debounce state, which this method doesn't touch.
    /// Lets sign-out / delete-account paths call it without becoming
    /// `@MainActor` themselves.
    nonisolated static func resetBulkPublishMarker() {
        UserDefaults.standard.removeObject(forKey: bulkPublishedKey)
    }

    /// Diagnostic recovery — force a republish of every local recipe,
    /// ignoring the one-shot bulk-publish marker. Surfaced behind a
    /// "Re-publish library" button in `ProfileView` for users whose
    /// bulk publish ran while the CloudKit schema was still half-
    /// deployed (the marker flipped to "done", but every individual
    /// upload silently failed). Returns a tuple so the UI can render
    /// "published N of M, first failure: <msg>" without needing
    /// granular per-recipe state.
    func republishLibrary(recipes: [Recipe]) async -> (succeeded: Int, failed: Int, firstError: String?) {
        guard let ownerID = UserProfileMirror.cachedRecordID() else {
            return (0, 0, "Not signed into iCloud — cloud sync is unavailable.")
        }
        guard !recipes.isEmpty else {
            UserDefaults.standard.set(true, forKey: Self.bulkPublishedKey)
            return (0, 0, nil)
        }
        let appVersion = AppMetadata.currentAppVersion
        var succeeded = 0
        var failed = 0
        var firstError: String? = nil
        for recipe in recipes {
            do {
                try await Self.upsertWithThrottleBackoff(
                    ownerID: ownerID,
                    appVersion: appVersion,
                    recipe: recipe
                )
                succeeded += 1
            } catch {
                failed += 1
                if firstError == nil {
                    firstError = AppMetadata.describeServerError(error)
                }
            }
        }
        UserDefaults.standard.set(true, forKey: Self.bulkPublishedKey)
        return (succeeded, failed, firstError)
    }

    /// Upsert with CloudKit throttle handling. When the server replies
    /// with `requestRateLimited` / `serviceUnavailable` / `zoneBusy`,
    /// CloudKit attaches a `CKErrorRetryAfterKey` (seconds) to the
    /// error and expects the client to wait that long before retrying.
    /// Without honoring it, every subsequent call in a tight loop also
    /// throttles and the user-visible "republish 0 of N" outcome stays
    /// silent. Retry up to 3 times per recipe; after that, propagate
    /// the error so `republishLibrary` can record it as a failure.
    /// `retryAfter` is clamped to [1s, 60s] — CloudKit usually returns
    /// 1–10s, but a hostile or buggy server response shouldn't park
    /// the bulk loop indefinitely.
    @MainActor
    private static func upsertWithThrottleBackoff(
        ownerID: String,
        appVersion: String,
        recipe: Recipe,
        maxAttempts: Int = 3
    ) async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await CloudKitService.upsertPublishedRecipe(
                    ownerID: ownerID,
                    sharedBy: recipe.originalCreatorDisplayName,
                    appVersion: appVersion,
                    recipe: recipe,
                    originalCreatorID: recipe.originalCreatorUserRecordName,
                    originalRecipeID: recipe.originalRecipeID
                )
                return
            } catch let ckError as CKError {
                guard attempt < maxAttempts,
                      Self.isThrottleCode(ckError.code) else {
                    throw ckError
                }
                let retryAfter = (ckError.userInfo[CKErrorRetryAfterKey] as? Double) ?? 2
                let clamped = max(1, min(retryAfter, 60))
                try? await Task.sleep(for: .seconds(clamped))
            }
        }
    }

    private static func isThrottleCode(_ code: CKError.Code) -> Bool {
        switch code {
        case .requestRateLimited, .serviceUnavailable, .zoneBusy:
            return true
        default:
            return false
        }
    }

}
