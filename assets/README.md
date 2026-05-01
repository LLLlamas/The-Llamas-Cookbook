# Assets

Llama logo + exported app-icon / favicon assets.

- Master vector: `assets/logo.svg`
- iOS app icons: `assets/ios/`
- Transparent PNGs: `assets/png/`
- Favicons: `assets/favicon/`

iOS icons are also copied into `ios-native/Resources/Assets.xcassets/AppIcon.appiconset/`. CI sanitizes them to opaque sRGB before archive.

If the logo changes, re-export from `logo.svg`, replace the matching files, verify TestFlight archive still passes asset validation.
