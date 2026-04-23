# Archived: Expo / React Native implementation

This was the first version of Llamas Cookbook, written in Expo (React Native) + TypeScript between 2026-04-18 and 2026-04-23. It shipped to TestFlight once. On 2026-04-23 the project pivoted to native SwiftUI + SwiftData, which lives at [`/ios-native/`](../../ios-native/).

## What's here

| Path | What |
|---|---|
| `App.tsx` / `index.ts` | Expo app entry points |
| `app.json` / `eas.json` | Expo + EAS config |
| `package.json` / `package-lock.json` / `tsconfig.json` | JavaScript toolchain |
| `src/` | All TypeScript source — screens, components, Zustand store, theme, types |
| `assets/` | Icons + splash images used by the RN build |
| `workflows/ios-testflight.yml` | The old GitHub Actions workflow that built this version on a macOS runner |

Nothing here is wired to the live app anymore. The RN workflow has been moved out of `.github/workflows/`, so pushes will not build or submit this version to TestFlight.

## Why it's still in the repo

- Quick reference while porting equivalent screens to SwiftUI. The RN source shows what the UX is supposed to feel like without needing to run the old app.
- `git blame` on this tree still works, so historical decisions stay visible.
- The spec [`../../llamas-cookbook-plan.md`](../../llamas-cookbook-plan.md) references React Native in its tech sections — this folder is where the concrete implementation of that spec lived.

## How to fully delete when the Swift port reaches parity

```sh
git rm -r outdated/rn-expo
git commit -m "Retire the archived RN implementation"
```

The Swift app reuses the bundle id `com.llamascookbook.app` already, so retirement requires no ASC or Apple Developer changes.
