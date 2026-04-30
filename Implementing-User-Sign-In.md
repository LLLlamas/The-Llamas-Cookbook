# Sign In Summary

Historical plan, condensed after implementation.

## Current Behavior

- Sign in with Apple is optional.
- Required for in-app social/friends features.
- Not required for local cookbook use, file export, or link sharing fallback.
- The app requests display name only, not email.
- Stable identity is stored locally/keychain-backed through `UserAccount` and `KeychainStore`.

## Critical Files

- `ios-native/Sources/App/UserAccount.swift`
- `ios-native/Sources/Lib/SignInWithAppleService.swift`
- `ios-native/Sources/Lib/KeychainStore.swift`
- `ios-native/Sources/Lib/UserProfileMirror.swift`
- `ios-native/Sources/Views/Profile/ProfileView.swift`

## Privacy Notes

- No password is stored or handled by the app.
- Social/shared CloudKit data is public/unlisted; do not describe it as hard-private.
- App Store privacy labels must reflect identifiers, display name/profile data, recipe/user content, and sharing/social records.

## Signing

SIWA entitlement must remain on the main app target:

`com.apple.developer.applesignin = ["Default"]`
