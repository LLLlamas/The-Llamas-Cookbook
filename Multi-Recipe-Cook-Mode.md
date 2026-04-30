# Multi-Recipe Cook Mode Summary

Historical plan, mostly implemented.

## Current Behavior

- `CookingSession` supports 1-4 active cooks.
- `ActiveCook.id` is distinct from `Recipe.id`.
- Cook Mode can switch between cooks and persists per-cook state.
- Session state is saved in `cooking-session-states.v2` with v1 migration.

## Critical Files

- `ios-native/Sources/App/CookingSession.swift`
- `ios-native/Sources/App/CookingSessionState.swift`
- `ios-native/Sources/App/RootView.swift`
- `ios-native/Sources/Views/Cook/CookModeView.swift`
- `ios-native/Sources/Lib/TimerNotifications.swift`
- `ios-native/Sources/Lib/TimerLiveActivityController.swift`

## Still Open

`TimerLiveActivityController` is still effectively per visible Cook Mode view. Add a `TimerLiveActivityRegistry` keyed by `cookID` so backgrounded cooks keep managed Live Activities.

## Must Test

- One-cook behavior unchanged.
- Marking one of multiple cooks done keeps Cook Mode open.
- Marking the last cook done dismisses Cook Mode.
- Force-kill restores active cooks and timers.
