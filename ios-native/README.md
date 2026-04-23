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

Swift: `com.llamascookbook.app.native`
RN:    `com.llamascookbook.app`

The bundles are distinct so both apps can live on the phone side-by-side during the port. When the Swift app reaches parity we retire the RN app and decide whether to keep the `.native` suffix or migrate to the original bundle id (requires a new ASC app record either way).

## Building locally (requires a Mac)

Not supported from Windows. On a Mac:

```sh
brew install xcodegen
cd ios-native
xcodegen generate
open LlamasCookbookNative.xcodeproj
```

## CI

`.github/workflows/ios-native-ci.yml` builds the Swift app for the iOS Simulator on GitHub's `macos-latest` runner. It runs on every push that touches `ios-native/` or the workflow file, and is manually triggerable via `workflow_dispatch`. No signing; no TestFlight upload yet.

Once the Swift app has meaningful functionality we'll add a TestFlight workflow mirroring the RN one, using the same signing secrets plus a new provisioning profile for the `.native` bundle id.

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
