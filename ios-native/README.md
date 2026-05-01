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

Do not build from Windows. CI archives via `.github/workflows/ios-native-ci.yml`. On a Mac:

```sh
brew install xcodegen
cd ios-native
xcodegen generate
open LlamasCookbookNative.xcodeproj
```

## Notes

- Do not commit the generated `.xcodeproj`.
- Do not hand-edit signing material into the repo.
- Current behavior: see root `CLAUDE.md`.
