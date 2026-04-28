import Foundation
import AuthenticationServices
import CryptoKit

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
///
/// **Nonce handling.** Every request generates a fresh cryptographic
/// nonce via `SecRandomCopyBytes`; the SHA256 hash is set as
/// `request.nonce` so Apple's identity token JWT carries it as the
/// `nonce` claim. The raw nonce is stashed in `pendingNonce` for the
/// duration of one sign-in round trip so a future server-side
/// validator can compare `sha256(pendingNonce)` against the JWT's
/// claim. We don't currently validate (no backend for the
/// CloudKit-only flow), but emitting the nonce future-proofs every
/// sign-in for the day we do — and per Apple's HIG, even client-only
/// flows are recommended to attach one.
enum SignInWithAppleService {
    /// Raw nonce from the most recent `configure(_:)` call. Held in
    /// memory only for the duration of one sign-in round trip; cleared
    /// on `processCompletion(_:)` regardless of outcome. Static so the
    /// SwiftUI `SignInWithAppleButton(onRequest:onCompletion:)` callback
    /// pair (separate closures, no shared instance) can see it across
    /// the call sequence.
    private(set) static var pendingNonce: String?
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
    /// Generates a fresh nonce per call and sets the SHA256 hash as
    /// `request.nonce`; raw value stored in `pendingNonce` for any
    /// future server-side validation against the JWT's `nonce` claim.
    static func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName]
        let nonce = makeNonce()
        pendingNonce = nonce
        request.nonce = sha256Hex(nonce)
    }

    /// Decode the button's completion `Result`. Maps Apple's nested
    /// optional chain into our flat `Credential`, mapping cancel and
    /// other errors into our `SignInError`. Always clears the
    /// `pendingNonce` on the way out so a stale nonce from a prior
    /// canceled attempt can't bleed into the next request.
    static func processCompletion(_ result: Result<ASAuthorization, Error>) throws -> Credential {
        defer { pendingNonce = nil }
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

    // MARK: - Nonce helpers

    /// 32 random bytes hex-encoded (64-char hex string). 256 bits of
    /// entropy is well above the practical replay-attack threshold and
    /// matches what Apple's sample code uses. `SecRandomCopyBytes` is
    /// CSPRNG; falls back to `UUID().uuidString` only if the system
    /// RNG fails (which essentially never happens on iOS, but the
    /// fallback keeps sign-in working rather than crashing).
    private static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
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
