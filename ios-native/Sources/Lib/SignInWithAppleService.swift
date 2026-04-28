import Foundation
import AuthenticationServices

/// Glue between SwiftUI's `SignInWithAppleButton` and the
/// `UserAccount` Observable. The button itself owns the whole
/// `ASAuthorizationController` dance — request, presentation, delegate
/// callbacks — and hands us back a `Result<ASAuthorization, Error>` in
/// its completion. Our job here is the post-button work:
///
/// 1. **Decode** the resulting `ASAuthorization` into our flat
///    `Credential` value type (the Apple type chains through three
///    optional casts to get to the user identifier).
/// 2. **Revocation check** on app launch via `getCredentialState` —
///    if the user opened iOS Settings → Apple ID → Sign in with Apple
///    and revoked our app's access, we need to know on next launch so
///    we can drop them back to the signed-out screen.
/// 3. **Configure** the request scopes in one place so the button's
///    `onRequest` callback stays a one-liner.
///
/// This is the *only* type that imports `AuthenticationServices`;
/// everything downstream (UserAccount, ProfileView) speaks
/// `Credential` and the `CredentialState` enum below, so swapping
/// providers later (Sign-in-with-Google in PR 5+) is a drop-in.
enum SignInWithAppleService {
    /// Flat, Codable-friendly snapshot of an Apple sign-in result. The
    /// fields we care about for downstream use:
    /// - `appleSub` — the stable opaque user identifier. Required.
    /// - `givenName` — only delivered the *first* time the user signs
    ///   in on a given Apple ID + app pair, and only if they agreed to
    ///   share their name on the consent sheet. Cached locally.
    /// - `email` — same first-time-only rule. Apple may relay through
    ///   `…@privaterelay.appleid.com` if the user enabled Hide My
    ///   Email. We don't currently store or use this; it's captured
    ///   here for completeness in case PR 5+ wants notification
    ///   preferences.
    /// - `identityToken` — short-lived JWT. Validated server-side in
    ///   a hypothetical future where we run a backend; for the
    ///   CloudKit-only flow we don't need to send it anywhere.
    struct Credential {
        let appleSub: String
        let givenName: String?
        let email: String?
        let identityToken: Data?
    }

    enum SignInError: LocalizedError {
        case canceled
        case unexpectedCredentialType
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .canceled:
                return "Sign-in canceled."
            case .unexpectedCredentialType:
                return "Apple returned an unexpected credential type."
            case .underlying(let error):
                return error.localizedDescription
            }
        }
    }

    /// State of a previously-issued Apple credential, queried by
    /// `appleSub`. Mirrors `ASAuthorizationAppleIDProvider.CredentialState`
    /// 1:1 but with `transferred` collapsed into `revoked` (we treat
    /// either as "this account is no longer valid, sign the user out").
    enum CredentialState {
        case authorized
        case revoked
        case notFound
    }

    /// Configure the auth request. Called from
    /// `SignInWithAppleButton(onRequest:)`. We only ask for `.fullName`
    /// — `email` is not stored anywhere in the app and asking for it
    /// produces a noisier consent sheet for no benefit.
    static func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName]
    }

    /// Decode the button's completion `Result`. Maps Apple's nested
    /// optional chain into our flat `Credential`, mapping cancel and
    /// other errors into our `SignInError`.
    static func processCompletion(_ result: Result<ASAuthorization, Error>) throws -> Credential {
        switch result {
        case .failure(let error):
            if let asError = error as? ASAuthorizationError, asError.code == .canceled {
                throw SignInError.canceled
            }
            throw SignInError.underlying(error)
        case .success(let auth):
            guard let appleCred = auth.credential as? ASAuthorizationAppleIDCredential else {
                throw SignInError.unexpectedCredentialType
            }
            return Credential(
                appleSub: appleCred.user,
                givenName: appleCred.fullName?.givenName,
                email: appleCred.email,
                identityToken: appleCred.identityToken
            )
        }
    }

    /// Check whether the cached `appleSub` is still valid. Called from
    /// `AppDelegate.didFinishLaunching` so we can drop the user back
    /// to signed-out if they revoked access from iOS Settings while
    /// our app was backgrounded. Apple's API is callback-based;
    /// wrapped here as `async`.
    ///
    /// Returns `.notFound` if `appleSub` is empty or the underlying
    /// API errors out — both should be treated as "we don't currently
    /// have a valid auth session" rather than as a hard failure.
    static func credentialState(for appleSub: String) async -> CredentialState {
        guard !appleSub.isEmpty else { return .notFound }
        let provider = ASAuthorizationAppleIDProvider()
        return await withCheckedContinuation { continuation in
            provider.getCredentialState(forUserID: appleSub) { state, _ in
                switch state {
                case .authorized:
                    continuation.resume(returning: .authorized)
                case .revoked, .transferred:
                    continuation.resume(returning: .revoked)
                case .notFound:
                    continuation.resume(returning: .notFound)
                @unknown default:
                    continuation.resume(returning: .notFound)
                }
            }
        }
    }
}
