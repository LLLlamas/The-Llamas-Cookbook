# Llamas Cookbook

Personal, offline-first iOS recipe keeper. SwiftUI + SwiftData.

- Live app: `ios-native/`
- Web preview / Universal Link host: `cloudflare-pages/`
- Agent source of truth: `AGENTS.md` (`CLAUDE.md` is local-only/ignored)

(The old React Native / Expo prototype was removed 2026-06-26; recover it from the `archive/rn-expo` git tag if ever needed.)

## Build

Primary: local Xcode on the Mac — see `ios-native/README.md`. Fallback: `.github/workflows/ios-native-ci.yml` (manual dispatch) still archives on `macos-26` and optionally uploads to TestFlight.

## Product shape

Local cookbook first. Sharing/social uses public/unlisted CloudKit; do not promise strict friend-only privacy.

Grocery Lists (free): build a shopping list from any recipe, let the on-device llama sort it into aisles in store-walk order (with optional per-store custom layouts), check items off, and tap "?" on an item for what-it-is plus its likely aisle.

Shared lists: send a list to a friend and watch them shop it live — their check-offs land on your phone, and flagging an item unavailable pushes you a notification. In progress on `claude/prep-ingredient-tracking-goqokv` (`MARKETING_VERSION` 1.2.0, unreleased); needs a real two-device run before shipping. A read-only public web page for a shared list exists at `/list/<recordName>` but has no in-app entry point yet.
