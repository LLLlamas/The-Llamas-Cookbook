# Llamas Cookbook

Personal, offline-first iOS recipe keeper. SwiftUI + SwiftData.

- Live app: `ios-native/`
- Web preview / Universal Link host: `cloudflare-pages/`
- Archived RN prototype: `outdated/rn-expo/`
- Agent source of truth: `CLAUDE.md`

## Build

Windows can't build iOS. Use `.github/workflows/ios-native-ci.yml` (manual dispatch). Runs on `macos-26`, archives, optionally uploads to TestFlight.

## Product shape

Local cookbook first. Sharing/social uses public/unlisted CloudKit; do not promise strict friend-only privacy.
