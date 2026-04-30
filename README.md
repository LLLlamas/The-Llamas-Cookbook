# Llamas Cookbook

Personal, offline-first iOS recipe keeper built with SwiftUI + SwiftData.

## Live App

- Code: `ios-native/`
- Preview/share site: `cloudflare-pages/`
- Archived RN prototype: `outdated/rn-expo/`
- Current agent source of truth: `CLAUDE.md`

## Build

This Windows machine cannot build iOS locally. Use the manual GitHub Actions workflow:

`.github/workflows/ios-native-ci.yml`

CI runs on `macos-26`, archives the native app, and can upload to TestFlight.

## Product Shape

Private local cookbook first. Sharing/social features are public/unlisted CloudKit surfaces used for recipe links and friend cookbook discovery; do not promise strict friend-only privacy.
