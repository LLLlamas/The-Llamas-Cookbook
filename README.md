# Llamas Cookbook

A personal, offline-first iOS recipe keeper. SwiftUI + SwiftData, iOS 18+.

**Full project reference:** [PROJECT.md](./PROJECT.md)

**Original product spec (vision / JTBD / UX — still authoritative):** [llamas-cookbook-plan.md](./llamas-cookbook-plan.md)

## Layout

- [`ios-native/`](./ios-native) — the live Swift app and its XcodeGen config
- [`outdated/rn-expo/`](./outdated/rn-expo) — archived first implementation (Expo + React Native), kept for reference during the Swift port
- [`.github/workflows/ios-native-ci.yml`](./.github/workflows/ios-native-ci.yml) — Archive + TestFlight workflow (manual dispatch only)

## Shipping a new TestFlight build

Run the **iOS Native (Swift) TestFlight** workflow in GitHub Actions on `main`. Lorenzo's Windows machine can't build locally — every build runs on GitHub's `macos-latest`. See [PROJECT.md §8](./PROJECT.md#8-ci--development-workflow) for the full dev loop.
