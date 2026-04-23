# Llamas Cookbook — Native iOS (SwiftUI)

The ground-up SwiftUI port of Llamas Cookbook. Runs alongside the Expo/React Native app at the repo root during the port; replaces it once parity is reached.

## Project layout

```
ios-native/
├── project.yml              # XcodeGen config → generates the .xcodeproj
├── Sources/
│   ├── App/                 # @main entry point + root navigation
│   ├── Models/              # SwiftData @Model types (Recipe, Ingredient, RecipeStep)
│   ├── Theme/               # Colors, typography, spacing
│   └── Views/               # One folder per feature area
└── Resources/
    └── Assets.xcassets/     # Asset catalog (app icon, etc.)
```

The `.xcodeproj` is generated on demand by XcodeGen and is gitignored.

## Bundle identifier

Both Swift and RN ship under `com.llamascookbook.app`. Same App Store Connect app record, same provisioning profile, same signing secrets.

**Don't run both TestFlight workflows at once.** The most recent upload wins on TestFlight, so shipping Swift replaces RN on your phone until you ship RN again. During the port we mostly push Swift builds; only re-run the RN workflow if you need to compare something on the current RN version.

Swift build numbers get an offset of 10000 on top of `github.run_number` so they never collide with RN's lower build numbers in the App Store Connect history.

## Building locally (requires a Mac)

Not supported from Windows. On a Mac:

```sh
brew install xcodegen
cd ios-native
xcodegen generate
open LlamasCookbookNative.xcodeproj
```

## CI

`.github/workflows/ios-native-ci.yml` archives the Swift app on GitHub's `macos-latest` runner and uploads it to TestFlight via the existing signing secrets. Only manually triggerable (`workflow_dispatch`) to prevent accidental Swift uploads overwriting the RN app while we're still mid-port.

## Port status

| Area             | Status                                                    |
| ---------------- | --------------------------------------------------------- |
| Xcode project    | Scaffolded (XcodeGen)                                     |
| SwiftData models | Recipe, Ingredient, RecipeStep                            |
| Theme            | Colors, typography, spacing constants                     |
| Library screen   | Placeholder list + empty state + "add placeholder" button |
| Recipe detail    | Not started                                               |
| Recipe editor    | Not started                                               |
| Cook mode        | Not started                                               |
| Settings         | Not started                                               |
| Llama mascot     | Not started (RN version uses inline SVG)                  |
| Haptics / timers | Not started                                               |
| App icon         | Placeholder                                               |
