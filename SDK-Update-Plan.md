# SDK Update Summary

Historical deadline plan. Current state is iOS 26 SDK via CI.

## Current Requirements

- CI runner: `macos-26`
- Xcode: 26.x
- Deployment target: iOS 18.0
- Build SDK: iOS 26.x
- Liquid Glass opt-out: `UIDesignRequiresCompatibility = true`

## Critical Files

- `.github/workflows/ios-native-ci.yml`
- `ios-native/Resources/AppInfo.plist`
- `ios-native/project.yml`

## Still Needed

- Adopt Liquid Glass before iOS 27 removes the compatibility opt-out.
- Keep CI printing toolchain versions so SDK drift is obvious.
- Do not raise deployment target unless product decides to drop older iOS support.
