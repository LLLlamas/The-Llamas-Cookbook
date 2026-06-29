# Llamas Cookbook

Personal, offline-first iOS recipe keeper. SwiftUI + SwiftData.

- Live app: `ios-native/`
- Web preview / Universal Link host: `cloudflare-pages/`
- Agent source of truth: `AGENTS.md` (`CLAUDE.md` is local-only/ignored)

(The old React Native / Expo prototype was removed 2026-06-26; recover it from the `archive/rn-expo` git tag if ever needed.)

## Build

Windows can't build iOS. Use `.github/workflows/ios-native-ci.yml` (manual dispatch). Runs on `macos-26`, archives, optionally uploads to TestFlight.

## Product shape

Local cookbook first. Sharing/social uses public/unlisted CloudKit; do not promise strict friend-only privacy.

Grocery Lists (free): build a shopping list from any recipe, let the on-device llama sort it by aisle and guess have/need, check items off, and tap "?" on an item for what-it-is or out-of-stock swaps. Shareable lists (web link + friends) are in progress on `claude/prep-ingredient-tracking-goqokv`.
