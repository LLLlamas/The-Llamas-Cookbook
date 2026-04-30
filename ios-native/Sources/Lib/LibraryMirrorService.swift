import Foundation
import SwiftUI
import SwiftData

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
    private static let bulkPublishedKey = "libraryMirror.didBulkPublish.v1"

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
    /// Bytes are extracted on the main actor synchronously (to
    /// satisfy `Recipe`'s `@Model`-bound access) and then handed off
    /// to a Task that does the network round-trip off-main.
    func enqueueUpsert(_ recipe: Recipe, sharedBy: String?) {
        guard let ownerID = UserProfileMirror.cachedRecordID() else {
            // No iCloud / not signed in — skip silently.
            return
        }

        let recipeID = recipe.id
        let appVersion = Self.currentAppVersion()
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
                sharedBy: sharedBy,
                appVersion: appVersion,
                recipe: recipe
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
    func bulkPublishIfNeeded(recipes: [Recipe], sharedBy: String?) async {
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

        let appVersion = Self.currentAppVersion()
        // Sequential to avoid swamping CloudKit + the iOS network
        // queue. For a user with 100 recipes this is ~100 round
        // trips; serializing keeps the device polite. Failures
        // don't abort the loop — best-effort, the per-save path
        // catches future updates anyway.
        for recipe in recipes {
            try? await CloudKitService.upsertPublishedRecipe(
                ownerID: ownerID,
                sharedBy: sharedBy,
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

    // MARK: - Helpers

    /// `CFBundleShortVersionString` (e.g. "1.0.0"). Used as the
    /// `appVersion` field in the share envelope so a friend
    /// receiving a stale-schema recipe knows which build to nudge
    /// the publisher toward. Falls back to "0.0.0" if the Info.plist
    /// is missing the key (shouldn't happen in shipping builds).
    static func currentAppVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
}
