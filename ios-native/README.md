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

## Notes

- Do not commit the generated `.xcodeproj`.
- Do not hand-edit signing material into the repo.
- Current behavior: see root `CLAUDE.md`.
