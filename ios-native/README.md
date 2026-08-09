# iOS Native

Live SwiftUI app.

## Layout

- `project.yml` — XcodeGen config.
- `Sources/App/` — entry, root navigation, coordinators.
- `Sources/Models/` — SwiftData models.
- `Sources/Lib/` — shared logic.
- `Sources/Views/` — feature UI.
- `Sources/Theme/` — colors, fonts, spacing.
- `Sources/Shared/` — cross-target Foundation-only helpers.
- `Resources/` — plist, entitlements, assets, privacy manifest.
- `Resources/Localizations/en.lproj/Localizable.strings` — push-notification
  bodies that CloudKit resolves on the receiving device. Must stay inside an
  `.lproj`, and `project.yml` must reference the PARENT dir — see Notes.
- `ShareExtension/` — extension target.
- `WidgetExtension/` — Live Activity widget.

## Build

Local Xcode (26.x stable, not beta) is the primary path. Automatic signing, team `GYFN949Q5E`; targets `com.llamascookbook.app` / `.widget` / `.shareext`.

```sh
brew install xcodegen
cd ios-native
xcodegen generate
open LlamasCookbookNative.xcodeproj
```

TestFlight upload: after `xcodegen generate`, set the build number (required — every shipped build uses a Unix timestamp, so lower values are rejected):

```sh
agvtool new-version -all $(date -u +%s)
```

then Product → Archive → Distribute App → TestFlight. Rerun `agvtool` after every `xcodegen generate` (regeneration resets it to `1`).

Fallback: `.github/workflows/ios-native-ci.yml` (manual dispatch) still archives + uploads on `macos-26`.

## Test

```sh
cd ios-native && xcodegen generate && xcodebuild \
  -project LlamasCookbookNative.xcodeproj -scheme LlamasCookbookNative \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The scheme is `LlamasCookbookNative` — there is no `LlamasCookbook` scheme.

## Notes

- Do not commit the generated `.xcodeproj`.
- Do not hand-edit signing material into the repo.
- Current behavior: see `AGENTS.md` at the repo root (the source of truth;
  there is no `CLAUDE.md` in this tree).
- **Localized strings must live in an `.lproj`.** iOS string lookup only
  searches `.lproj` directories, so a `Localizable.strings` at the bundle
  root ships but never resolves — and a CloudKit `alertLocalizationKey` push
  then renders as the raw key with no fallback. XcodeGen only builds the
  variant group that preserves `.lproj` when it discovers the localization
  while scanning a DIRECTORY, so `project.yml` points at
  `Resources/Localizations`, not at the `.lproj` or the file. After changing
  anything here, confirm with:
  `find "$(find ~/Library/Developer/Xcode/DerivedData -name LlamasCookbook.app | head -1)" -name '*.lproj'`
