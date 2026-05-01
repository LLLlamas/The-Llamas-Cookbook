# Project

Durable product/workflow context. Use `CLAUDE.md` for active state.

## Product

Personal iOS cookbook for saving, editing, finding, sharing, and cooking recipes. Local library is offline-first SwiftData. Social sharing is public/unlisted, not strict friend-private storage.

## Layout

- `ios-native/` — live SwiftUI + SwiftData app.
- `cloudflare-pages/` — web preview / Universal Link host.
- `outdated/rn-expo/` — archived Expo/RN prototype, not built.

## Build workflow

- Windows dev box can't build iOS. Use `.github/workflows/ios-native-ci.yml`, manually dispatched.
- Runner `macos-26`, Xcode 26.x.
- Generated Xcode project is disposable; edit `ios-native/project.yml`.

## Targets

- App: `com.llamascookbook.app`
- Widget: `com.llamascookbook.app.widget`
- Share extension: `com.llamascookbook.app.shareext`
- App Group: `group.com.llamascookbook.app`
- CloudKit container: `iCloud.com.llamascookbook.app`
- Team: `GYFN949Q5E`

## Design principles

- Fast capture beats completeness.
- Cook Mode is distraction-free and forgiving.
- Gestures need visible fallbacks.
- Local recipes stay useful without sign-in or network.
- Sharing copy must match the public/unlisted model.

## Secrets

Never commit certs, profiles, keys, env files, or local agent settings. GitHub Actions secrets hold signing material. Cloudflare stores `CLOUDKIT_PRIVATE_KEY` as an encrypted env var.
