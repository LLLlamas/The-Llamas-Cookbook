import Foundation
import Observation

/// Source of truth for "who am I" in the cloud-recipe-delivery flow.
/// Sibling pattern to `AppearanceSettings` and `OwnerProfile` —
/// instantiated once in `LlamasCookbookApp`, propagated via
/// `.environment(...)` from `RootView`.
///
/// PR 1 scope (per Implementing-User-Sign-In.md §9):
/// - Sign-in-with-Apple flow lands the Apple stable user identifier.
/// - Identity persists across reinstalls via `KeychainStore`
///   (appleSub + displayName); other fields live in UserDefaults.
/// - Sign Out + Delete Account both clear local state. CloudKit
///   cascade for Delete Account is deferred to PR 2 since the
///   CloudKit container isn't wired yet — the cloud-side `User` and
///   `RecipeShare` records don't exist yet to clean up.
/// - `cloudKitUserRecordID` and `friendCode` on `UserIdentity` are
///   nil throughout PR 1; PR 2 fills them in on first successful
///   `User` record write.
@Observable
final class UserAccount {
    enum Status {
        case signedOut
        case signingIn
        case signedIn(UserIdentity)
        /// Held briefly so the UI can render an inline error after a
        /// failed Apple sign-in; reverts to `.signedOut` on the next
        /// `beginSignIn()` or after the user dismisses.
        case signInFailed(String)

        var isSignedIn: Bool {
            if case .signedIn = self { return true }
            return false
        }

        var identity: UserIdentity? {
            if case .signedIn(let id) = self { return id }
            return nil
        }
    }

    struct UserIdentity: Codable, Equatable {
        let appleSub: String
        var displayName: String
        let createdAt: Date
        /// Filled in by PR 2 after the CloudKit `User` record write
        /// completes; nil throughout PR 1.
        var cloudKitUserRecordID: String?
        /// Filled in by PR 2; nil throughout PR 1.
        var friendCode: String?
    }

    private(set) var status: Status = .signedOut

    private static let createdAtKey = "userAccountCreatedAt"
    private static let cloudKitRecordIDKey = "userAccountCloudKitRecordID"
    private static let friendCodeKey = "userAccountFriendCode"

    init() {
        self.status = Self.rehydrate()
    }

    // MARK: Sign-in / Sign-out

    /// Mark the UI as "Apple sheet is up" so the button can disable
    /// itself and the Profile screen can show a spinner. Optional —
    /// the SwiftUI button does its own modal presentation, but this
    /// keeps our state machine honest.
    func beginSignIn() {
        status = .signingIn
    }

    /// Called from `ProfileView` once the SwiftUI
    /// `SignInWithAppleButton` completion returns a credential.
    /// Resolves the display name (Apple-supplied → OwnerProfile carry-
    /// over → fallback "Cook"), persists, and flips status to
    /// `.signedIn`.
    ///
    /// `ownerProfile` is an in/out parameter — on first sign-in we
    /// snap its `userName` into our display name (one-way migration
    /// per plan §3) so the share flow keeps emitting our resolved
    /// name as `sharedBy` in outbound envelopes.
    func completeSignIn(
        with credential: SignInWithAppleService.Credential,
        ownerProfile: OwnerProfile,
        accentHex: String?
    ) {
        let resolvedName = Self.resolveDisplayName(
            credentialName: credential.givenName,
            ownerProfileName: ownerProfile.userName
        )

        let identity = UserIdentity(
            appleSub: credential.appleSub,
            displayName: resolvedName,
            createdAt: Date(),
            cloudKitUserRecordID: nil,
            friendCode: nil
        )

        persist(identity)

        // One-way migration — copy our resolved name back into
        // OwnerProfile so the existing share flow keeps emitting it
        // if the user shares a recipe via file/link before the cloud
        // path is wired. After PR 2 the share flow can read directly
        // from UserAccount; OwnerProfile stays declared but unused.
        if ownerProfile.userName.isEmpty {
            ownerProfile.userName = resolvedName
        }

        status = .signedIn(identity)

        // Cloud-side mirror bind. Best-effort, fire-and-forget — the
        // local UI flips to .signedIn instantly while CloudKit handles
        // the iCloud-user-record fetch + initial UserProfile upsert in
        // the background. If iCloud isn't signed in or the schema
        // hasn't deployed yet, the mirror silently no-ops; the user's
        // local app continues to function without the friends/cloud
        // features. Captures resolvedName/accentHex by value so the
        // detached task is `Sendable`.
        let mirroredName = resolvedName
        let mirroredAccent = accentHex
        Task.detached {
            await UserProfileMirror.bindAfterSignIn(
                displayName: mirroredName,
                accentHex: mirroredAccent
            )
        }
    }

    /// Called from `ProfileView` when Apple's completion delivers an
    /// error or the user cancels. Cancellation is silent (no error
    /// message); other errors surface as `.signInFailed(message)`.
    func failSignIn(with error: Error) {
        if let signInError = error as? SignInWithAppleService.SignInError,
           case .canceled = signInError {
            status = .signedOut
            return
        }
        status = .signInFailed(error.localizedDescription)
    }

    /// Belt-and-suspenders recovery: if status is still `.signingIn`
    /// when ProfileView reappears, force it back to `.signedOut` so
    /// the button is interactive again. Hedge against the iOS 18
    /// `SignInWithAppleButton` regression where `onCompletion`
    /// sometimes doesn't deliver on swipe-down dismiss, stranding us
    /// in `.signingIn` indefinitely.
    func cancelInFlightSignIn() {
        if case .signingIn = status {
            status = .signedOut
        }
    }

    /// Clears local identity but does NOT touch any cloud-side records.
    /// The user can sign back in immediately and (in PR 2+) re-bind to
    /// the same CloudKit `User` record via the `appleSub` lookup.
    func signOut() {
        wipeLocalState()
        status = .signedOut
        // Drop the UserProfile mirror cache so subsequent mirror calls
        // (e.g. an accent change while signed out) silently no-op
        // instead of pushing updates against a now-orphaned identity.
        // Synchronous — no network involvement, just clears
        // UserDefaults.
        UserProfileMirror.clearAfterSignOut()
    }

    /// Wipes local identity AND fires a CloudKit cascade to delete
    /// every cloud share this device has authored (per the local
    /// outbox in `CloudKitService.deleteAuthoredShares`). The local
    /// wipe is synchronous so the UI flips to signed-out instantly;
    /// the cloud cleanup runs detached in the background.
    ///
    /// **Persistent retry semantics.** The cascade promotes the
    /// outbox into a pending-delete queue and drains it; per-record
    /// failures (network blip, throttling, etc.) stay queued for
    /// `CloudKitService.retryPendingDeletes` to pick up on the next
    /// launch. Records can only drop from the queue when the cloud
    /// confirms deletion (or already-gone via `unknownItem`).
    /// Required by App Store Review Guideline 5.1.1(v) since 2022 —
    /// any app with account creation must offer in-app deletion,
    /// and reviewers test it under conditions that include slow /
    /// flaky networks.
    func deleteAccount() {
        wipeLocalState()
        status = .signedOut
        Task.detached {
            // Capture the iCloud user record name *before* the
            // mirror's deletion path clears its cache — the
            // friendship cascade below needs it to find every
            // record this user was part of.
            let cascadeUserID = UserProfileMirror.cachedRecordID()
            await CloudKitService.deleteAuthoredShares()
            // Delete the UserProfile mirror record + drop the local
            // cache. PublishedRecipe / RecipeImport cascades land in
            // slices 3 and 6 respectively; account-deletion
            // compliance requires every cloud-side trace get
            // cleaned up, so each slice extends this cascade.
            await UserProfileMirror.deleteOnAccountDeletion()
            if let me = cascadeUserID {
                // Slice 2 cascade: every Friendship record this user
                // appears in. Includes pending requests in either
                // direction so the recipient / requester sees them
                // vanish silently on their next refresh.
                await CloudKitService.deleteAllFriendships(for: me)
            }
        }
    }

    /// Profile screen edit. No-op when signed out.
    /// Capped + sanitized via `RecipeShare.cappedDisplayName` so the
    /// stored name can never exceed the wire-format limit; a sender
    /// can't smuggle a longer name into a share envelope by editing
    /// their profile and immediately sharing.
    func updateDisplayName(_ name: String) {
        guard case .signedIn(var identity) = status else { return }
        let resolved = RecipeShare.cappedDisplayName(name) ?? "Cook"
        identity.displayName = resolved
        persist(identity)
        status = .signedIn(identity)

        // Push the new display name to CloudKit so friends searching
        // for this user (or already-friended viewers) see the updated
        // label. Best-effort, fire-and-forget.
        Task.detached {
            await UserProfileMirror.updateDisplayName(resolved)
        }
    }

    /// Cold-launch revocation check. Called from `AppDelegate`. If the
    /// user opened iOS Settings → Apple ID → Sign in with Apple →
    /// "Stop Using Apple ID" for our app while the app was
    /// backgrounded, we drop them back to signed-out so the next
    /// Profile open prompts a fresh sign-in. CloudKit `User` record is
    /// left dangling for now (PR 2 will reap on next sign-in).
    func refreshCredentialState() async {
        guard case .signedIn(let identity) = status else { return }
        let state = await SignInWithAppleService.credentialState(for: identity.appleSub)
        if case .revoked = state {
            await MainActor.run { self.signOut() }
        }
    }

    // MARK: Persistence

    private func persist(_ identity: UserIdentity) {
        KeychainStore.write(identity.appleSub, to: .appleSub)
        KeychainStore.write(identity.displayName, to: .displayName)
        UserDefaults.standard.set(identity.createdAt.timeIntervalSince1970, forKey: Self.createdAtKey)
        if let recordID = identity.cloudKitUserRecordID {
            UserDefaults.standard.set(recordID, forKey: Self.cloudKitRecordIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cloudKitRecordIDKey)
        }
        if let friendCode = identity.friendCode {
            UserDefaults.standard.set(friendCode, forKey: Self.friendCodeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.friendCodeKey)
        }
    }

    private func wipeLocalState() {
        KeychainStore.wipeAll()
        UserDefaults.standard.removeObject(forKey: Self.createdAtKey)
        UserDefaults.standard.removeObject(forKey: Self.cloudKitRecordIDKey)
        UserDefaults.standard.removeObject(forKey: Self.friendCodeKey)
    }

    /// Reads Keychain + UserDefaults into a Status. `appleSub`
    /// presence is the gate — if it's missing, we treat the user as
    /// signed-out regardless of any leftover UserDefaults values
    /// (paranoia against the Keychain being wiped without us being
    /// notified, e.g. by a passcode reset on iOS < 14 — which we
    /// don't support, but cheap belt-and-suspenders).
    private static func rehydrate() -> Status {
        guard let appleSub = KeychainStore.read(.appleSub), !appleSub.isEmpty else {
            return .signedOut
        }
        let displayName = KeychainStore.read(.displayName) ?? "Cook"
        let createdAtInterval = UserDefaults.standard.double(forKey: Self.createdAtKey)
        let createdAt = createdAtInterval > 0
            ? Date(timeIntervalSince1970: createdAtInterval)
            : Date()
        let cloudKitRecordID = UserDefaults.standard.string(forKey: Self.cloudKitRecordIDKey)
        let friendCode = UserDefaults.standard.string(forKey: Self.friendCodeKey)
        let identity = UserIdentity(
            appleSub: appleSub,
            displayName: displayName,
            createdAt: createdAt,
            cloudKitUserRecordID: cloudKitRecordID,
            friendCode: friendCode
        )
        return .signedIn(identity)
    }

    // MARK: Helpers

    /// Cascade: Apple-supplied first name (only delivered on first
    /// sign-in, only if the user agreed) → existing OwnerProfile
    /// userName (carryover from the file/link share path) → "Cook"
    /// (the Apple-blessed default in §11.4 of the plan).
    /// Each candidate runs through `RecipeShare.cappedDisplayName`
    /// so the stored name conforms to the wire-format display-name
    /// rules from the moment it lands.
    private static func resolveDisplayName(
        credentialName: String?,
        ownerProfileName: String
    ) -> String {
        if let name = RecipeShare.cappedDisplayName(credentialName) {
            return name
        }
        if let name = RecipeShare.cappedDisplayName(ownerProfileName) {
            return name
        }
        return "Cook"
    }
}
