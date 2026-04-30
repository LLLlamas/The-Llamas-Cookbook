# Project Summary

Use `CLAUDE.md` for current agent instructions. This file keeps the durable product and workflow context.

## Product

Llamas Cookbook is a personal iOS cookbook for saving, editing, finding, sharing, and cooking recipes. The core library is local/offline-first. Social sharing is public/unlisted, not strict friend-private storage.

## Current App

- Native app: SwiftUI + SwiftData in `ios-native/`.
- Web preview: Cloudflare Pages in `cloudflare-pages/`.
- Archived prototype: Expo/RN in `outdated/rn-expo/`.

## Build Workflow

- Windows dev box cannot build iOS locally.
- Use `.github/workflows/ios-native-ci.yml`, manually dispatched.
- CI runs on `macos-26` and Xcode 26.
- App target uses explicit `ios-native/Resources/AppInfo.plist`.
- Generated Xcode project is disposable; edit `ios-native/project.yml`.

## App Targets

- App: `com.llamascookbook.app`
- Widget: `com.llamascookbook.app.widget`
- Share extension: `com.llamascookbook.app.shareext`
- App Group: `group.com.llamascookbook.app`
- CloudKit container: `iCloud.com.llamascookbook.app`

## Design Principles

- Fast capture beats completeness.
- Cook Mode is distraction-free and forgiving.
- Gestures need visible fallbacks.
- Local recipes stay useful without sign-in or network.
- Sharing copy must match the public/unlisted model.

## Secrets

Do not commit certs, profiles, keys, env files, or local agent settings. GitHub Actions secrets hold signing material. Cloudflare stores `CLOUDKIT_PRIVATE_KEY` as an encrypted env var.
