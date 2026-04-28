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
    /// per plan §3) and flip its `hasPromptedForName` flag so the
    /// existing share flow stops nagging for a name that's now
    /// authoritative here.
    func completeSignIn(
        with credential: SignInWithAppleService.Credential,
        ownerProfile: OwnerProfile
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
        ownerProfile.hasPromptedForName = true

        status = .signedIn(identity)
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

    /// Clears local identity but does NOT touch any cloud-side records.
    /// The user can sign back in immediately and (in PR 2+) re-bind to
    /// the same CloudKit `User` record via the `appleSub` lookup.
    func signOut() {
        wipeLocalState()
        status = .signedOut
    }

    /// Wipes local identity AND fires a best-effort CloudKit cascade
    /// to delete every cloud share this device has authored (per the
    /// local outbox in `CloudKitService.deleteAuthoredShares`). The
    /// local wipe is synchronous so the UI flips to signed-out
    /// instantly; the cloud cleanup runs detached in the background
    /// and tolerates failures (a stranded record gets garbage-
    /// collected by the eventual TTL janitor / 14-day retention
    /// rather than blocking sign-out on a network blip).
    ///
    /// Required by App Store Review Guideline 5.1.1(v) since 2022 —
    /// any app with account creation must offer in-app deletion.
    func deleteAccount() {
        wipeLocalState()
        status = .signedOut
        Task.detached {
            await CloudKitService.deleteAuthoredShares()
        }
    }

    /// Profile screen edit. No-op when signed out.
    func updateDisplayName(_ name: String) {
        guard case .signedIn(var identity) = status else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "Cook" : trimmed
        identity.displayName = resolved
        persist(identity)
        status = .signedIn(identity)
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
    private static func resolveDisplayName(
        credentialName: String?,
        ownerProfileName: String
    ) -> String {
        if let name = credentialName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        let trimmed = ownerProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "Cook"
    }
}
