# Sign In

Sign in with Apple. Optional. Required for in-app social/friends. Display name only, never email. Identity persisted in Keychain via `UserAccount` + `KeychainStore`.

## Files

- `ios-native/Sources/App/UserAccount.swift`
- `ios-native/Sources/Lib/SignInWithAppleService.swift`
- `ios-native/Sources/Lib/KeychainStore.swift`
- `ios-native/Sources/Lib/UserProfileMirror.swift`
- `ios-native/Sources/Views/Profile/ProfileView.swift`

## Privacy

- No password handled.
- Social/shared CloudKit data is public/unlisted; do not describe as hard-private.
- App Store privacy labels must reflect identifiers, display name/profile, recipe/user content, sharing/social records.

## Entitlement

`com.apple.developer.applesignin = ["Default"]` on the main app target.
