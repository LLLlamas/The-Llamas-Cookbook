import Foundation
import Security

/// Tiny string-in / string-out wrapper around the iOS Keychain. Used by
/// `UserAccount` to persist the Sign-in-with-Apple stable user
/// identifier across app reinstalls — the Apple `sub` is the primary
/// key for the cloud recipe-delivery flow (see
/// Implementing-User-Sign-In.md §3) and we cannot afford to lose it
/// when the user wipes the app and reinstalls from the App Store.
///
/// Why Keychain (and not UserDefaults)?
/// - **Survives reinstall** by default on iOS 14+ (the OS preserves
///   keychain items across delete-and-reinstall of the same bundle id).
/// - **Does not sync to iCloud Keychain** unless we set
///   `kSecAttrSynchronizable = true`, which we explicitly don't —
///   the Apple `sub` is per-device-team in the spec but per-Apple-ID
///   in practice, and we want the same user signing in on a second
///   device to take a fresh trip through the auth flow rather than
///   inheriting the first device's cached `sub`.
/// - **Encrypted at rest** by the Secure Enclave when the device has a
///   passcode, which it almost always does.
///
/// We don't need keychain access groups (no other targets read these
/// values — the share extension is transparent passthrough).
enum KeychainStore {
    /// Service identifier — every account row scoped under this string.
    /// Tied to the bundle id so a future second app from the same team
    /// can't accidentally collide on the same accounts.
    static let service = "com.llamascookbook.app.account"

    enum Account: String {
        /// Sign-in-with-Apple stable user identifier (`userIdentifier`
        /// from `ASAuthorizationAppleIDCredential`). Lives forever once
        /// written; only cleared on Sign Out / Delete Account.
        case appleSub
        /// Last-known display name. Persisted alongside the sub so the
        /// signed-in UI has a name to show on cold launch before the
        /// (eventually) CloudKit `User` record is fetched.
        case displayName
        /// Anthropic API key for Claude recipe parsing. Seeded at first
        /// launch from the `AnthropicAPIKey` Info.plist entry (injected
        /// via `ANTHROPIC_API_KEY` build setting). Read by
        /// `AnthropicRecipeParser` on every import; never logged or
        /// surfaced in UI. Phase 3 migration removes this and routes
        /// through the Cloudflare Worker proxy instead.
        case anthropicAPIKey
    }

    /// Distinguishes the three states a Keychain read can return.
    /// Most call sites only care about `.found(_)`; the
    /// `rehydrate()` path on `UserAccount` cares about the
    /// `notFound` vs `unavailable` distinction so a transient
    /// `errSecAuthFailed` / `errSecInteractionNotAllowed` doesn't
    /// flip the user to signed-out and force an unnecessary
    /// re-sign-in on the next cold launch.
    enum ReadResult {
        /// The row exists and decoded cleanly.
        case found(String)
        /// The row is genuinely absent (`errSecItemNotFound`). Treat
        /// as legitimate signed-out state.
        case notFound
        /// Keychain returned some other status (locked, auth failed,
        /// entitlement issue, decode failure). The row may still
        /// exist; the caller should NOT assume signed-out.
        case unavailable(OSStatus)
    }

    /// Typed read used by load-bearing call sites that need to
    /// distinguish "no row" from "Keychain temporarily unreachable."
    /// Other call sites can continue to use the convenience
    /// `read(_:) -> String?` overload below.
    static func readResult(_ account: Account) -> ReadResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                return .unavailable(status)
            }
            return .found(string)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable(status)
        }
    }

    /// Reads the value at `account`, returning nil if missing or if any
    /// keychain error fires. Errors are intentionally swallowed — on a
    /// fresh install the read will miss, and surfacing that as a thrown
    /// error would force every callsite to wrap a try? around it.
    /// Use `readResult(_:)` when the call site cares whether the
    /// nil-return reflects a true absence or a transient error.
    static func read(_ account: Account) -> String? {
        if case .found(let string) = readResult(account) { return string }
        return nil
    }

    /// Writes (or replaces) the value at `account`. Returns true on
    /// success. The two-step add → fall-back-to-update dance is the
    /// canonical Apple pattern; `SecItemUpdate` requires the row to
    /// exist already, and `SecItemAdd` errors with `errSecDuplicateItem`
    /// if it does.
    @discardableResult
    static func write(_ value: String, to account: Account) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.rawValue,
        ]
        let addQuery = baseQuery.merging([
            kSecValueData: data,
            // Available after first unlock; survives reboot once the
            // user has unlocked the device once. Required so a timer
            // notification or background push that fires before the
            // user has opened the app post-reboot can still read the
            // user identity. We never need access while the device is
            // locked, so we don't escalate to `AlwaysThisDeviceOnly`.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        if addStatus == errSecDuplicateItem {
            let update: [CFString: Any] = [kSecValueData: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            return updateStatus == errSecSuccess
        }
        return false
    }

    /// Removes the value at `account`. No-op if it doesn't exist.
    @discardableResult
    static func delete(_ account: Account) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Wipes every account row under our service. Called on Delete
    /// Account so a subsequent fresh sign-in starts with no leftover
    /// state from the previous user.
    static func wipeAll() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
