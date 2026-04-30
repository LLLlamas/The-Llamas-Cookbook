# Assets

Llama logo and exported app-icon/favicon assets.

## Source

- Master vector: `assets/logo.svg`
- App icon exports: `assets/ios/`
- Transparent PNGs: `assets/png/`
- Favicons: `assets/favicon/`

## iOS

Current app icons are already copied into:

`ios-native/Resources/Assets.xcassets/AppIcon.appiconset/`

CI sanitizes app icon PNGs to opaque sRGB before archive.

## Regenerate

If the logo changes, re-export from `logo.svg`, replace the matching files, and verify TestFlight archive still passes asset validation.
