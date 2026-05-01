# Multi-Recipe Cook Mode

`CookingSession` supports 1-4 active cooks. `ActiveCook.id` is distinct from `Recipe.id`. Per-cook state persists; state file is `cooking-session-states.v2` (with v1 migration).

## Files

- `ios-native/Sources/App/CookingSession.swift`
- `ios-native/Sources/App/CookingSessionState.swift`
- `ios-native/Sources/App/RootView.swift`
- `ios-native/Sources/Views/Cook/CookModeView.swift`
- `ios-native/Sources/Lib/TimerNotifications.swift`
- `ios-native/Sources/Lib/TimerLiveActivityController.swift`

## Open

`TimerLiveActivityController` is per-Cook-Mode-view. Add `TimerLiveActivityRegistry` keyed by `cookID` so backgrounded cooks keep their Live Activities.

## Test

- One-cook behavior unchanged.
- Marking one of multiple cooks done keeps Cook Mode open.
- Marking the last cook done dismisses Cook Mode.
- Force-kill restores active cooks and timers.
