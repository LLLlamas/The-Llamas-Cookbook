# Share Extension Summary

Historical plan, condensed after implementation.

## Current Behavior

The share extension is a passthrough target. It does not touch SwiftData.

- URLs become `llamascookbook://share-url/<base64url>`.
- `.llamarecipe` files are copied into the App Group inbox, then handed to the main app as `share-incoming/<uuid>`.
- Main app decodes, validates, imports, and sweeps stale inbox files.

## Critical Files

- `ios-native/ShareExtension/ShareViewController.swift`
- `ios-native/ShareExtension/Info.plist`
- `ios-native/ShareExtension/LlamasCookbookShareExtension.entitlements`
- `ios-native/Sources/Shared/SharedContainer.swift`
- `ios-native/Sources/Shared/Base64URL.swift`
- `ios-native/Sources/App/RootView.swift`

## Signing

- Bundle id: `com.llamascookbook.app.shareext`
- App Group must match the main app: `group.com.llamascookbook.app`
- GitHub secret: `IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64`

## Do Not Regress

- Extension remains lightweight and UI-minimal.
- Main app is responsible for validation and persistence.
- Inbox filenames stay UUID-based and size-capped.
