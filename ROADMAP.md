# Llamas Cookbook — Roadmap

Things we've talked about but deferred. Each section is self-contained so a
future session can pick one up without rereading the whole conversation.

---

## 0. Live Activity — Apple Developer portal setup (⚠️ action required)

The Live Activity target has been implemented in the repo but **will not
build on CI until the widget's provisioning profile is created and added
as a secret**. One-time setup — takes ~10 minutes.

### Step 1 — Register the widget App ID on Apple Developer
1. Go to https://developer.apple.com/account/resources/identifiers/list
2. Click the **+** button → "App IDs" → Continue → "App" → Continue
3. Fill in:
   - Description: `Llamas Cookbook Timer Widget`
   - Bundle ID: **Explicit**, `com.llamascookbook.app.widget`
   - Capabilities: leave defaults (nothing extra needed for Live Activities —
     the main app's capabilities cover it)
4. Continue → Register.

### Step 2 — Create the widget's App Store provisioning profile
1. Go to https://developer.apple.com/account/resources/profiles/list
2. Click **+** → "App Store Connect" → Continue
3. Select App ID: `com.llamascookbook.app.widget`
4. Select the distribution certificate you used for the main app.
5. Name it something like `Llamas Cookbook Widget App Store`
6. Generate + **Download** the `.mobileprovision` file.

### Step 3 — Base64-encode it and add as a repo secret
On Windows (PowerShell) — from wherever you saved the `.mobileprovision`:
```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("Llamas_Cookbook_Widget_App_Store.mobileprovision")) | Set-Clipboard
```
Then go to the repo's Settings → Secrets and variables → Actions → "New
repository secret":
- Name: `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`
- Value: paste from clipboard.

### Step 4 — Confirm the existing distribution certificate covers the widget
The widget extension is signed with the **same** `IOS_DIST_CERT_P12_BASE64`
distribution certificate the main app uses. No new cert required — Apple
Distribution certs sign any App ID under the same team. Nothing to do here
unless your cert has expired.

### Step 5 — Trigger the workflow
Once the secret is in place, the existing `ios-native-ci.yml` picks it up
automatically. Run the workflow once to confirm both profiles install and
the archive signs clean.

### If the build fails
Common culprits (in order of likelihood):
1. Widget profile bundle id mismatch — must be exactly `com.llamascookbook.app.widget`.
2. Widget profile distribution cert doesn't match the main app's — regenerate
   with the same cert.
3. Profile expired — default validity is 1 year.
4. `NSSupportsLiveActivities` missing from the main app's Info.plist — should be
   there via project.yml, but verify the generated Info.plist after xcodegen.

---

## 1. Live Activity (Dynamic Island + Lock Screen timer) — IMPLEMENTED

### What it is
A Live Activity is iOS 16.1+'s mechanism for showing an app's short-lived,
user-initiated state outside the app: on the Lock Screen and (on iPhone 14
Pro and newer) in the Dynamic Island. It updates in real time without the
app running.

For Llamas Cookbook this means the cooking timer could sit in the Dynamic
Island with a live countdown, the way Apple's built-in Timer app does — the
user can quickly glance at remaining time while the phone is locked or
they're in another app.

### Why it's worth doing
- **Ambient awareness.** Local notifications alert you *once* at the end.
  A Live Activity shows the countdown continuously, so the user doesn't
  need to unlock the phone or re-open the app to check how long is left.
- **Interactive controls.** With App Intents + LiveActivityIntent, the user
  can tap +1 min / –1 min / Cancel from the expanded Dynamic Island
  without re-entering the app.
- **Expected behavior.** For a cooking-timer app on modern iPhones, users
  have come to expect this. Its absence will feel like a missing feature.

### What we already have without it
- Local notification scheduled at timer end (see [`TimerNotifications`](./ios-native/Sources/Lib/TimerNotifications.swift)).
  Fires banner + default sound + system haptic regardless of app state.
- The in-app `TimerReadyOverlay` with continuous vibration when the user is
  in the app at expiry.
- Extend / subtract / cancel while the app is open, via the `RunningTimerSheet`.

So "did the user get alerted when the timer ended?" — yes, they did, even
with the app closed. What they don't get is a *live* visual while away.

### Work required

#### New target in [ios-native/project.yml](./ios-native/project.yml)
```yaml
LlamasCookbookTimerWidget:
  type: app-extension
  platform: iOS
  sources:
    - path: WidgetExtension
  settings:
    base:
      PRODUCT_BUNDLE_IDENTIFIER: com.llamascookbook.app.widget
      INFOPLIST_KEY_CFBundleDisplayName: "Llamas Cookbook Timer"
      INFOPLIST_KEY_NSExtensionPointIdentifier: com.apple.widgetkit-extension
      SWIFT_VERSION: "5.10"
```
And add to the main app's Info.plist: `INFOPLIST_KEY_NSSupportsLiveActivities: YES`.

#### New files under `ios-native/WidgetExtension/`
1. `TimerAttributes.swift` — `ActivityAttributes` + nested `ContentState`:
   ```swift
   struct TimerAttributes: ActivityAttributes {
       struct ContentState: Codable, Hashable {
           var endDate: Date
           var label: String   // "Bake", "Pot", "Cook", etc.
       }
       var recipeTitle: String
       var stepNumber: Int
   }
   ```
2. `TimerWidgetBundle.swift` — `@main` bundle with the Live Activity widget.
3. `TimerLiveActivity.swift` — three presentations:
   - **Lock-screen:** recipe title + step number + `Text(endDate, style: .timer)` + pause/cancel intents.
   - **Dynamic Island compact:** `timer` SF Symbol on the leading side, `Text(endDate, style: .timer)` on the trailing side.
   - **Dynamic Island expanded:** recipe title + countdown + minus/plus-minute / cancel intents.
   - **Dynamic Island minimal:** just the `timer` glyph.

#### Main-app wiring in [CookModeView](./ios-native/Sources/Views/Cook/CookModeView.swift)
- `import ActivityKit`
- Hold a `@State var currentActivity: Activity<TimerAttributes>?`
- `startTimer(...)` → `Activity.request(attributes: ..., content: ..., pushType: nil)`
- `extendTimer(...)` → `await activity.update(ActivityContent(state: ..., staleDate: nil))`
- `cancelTimer()` / `onStop` → `await activity.end(dismissalPolicy: .immediate)`

#### Interactive controls (optional, iOS 17+)
Add a `LiveActivityIntent` conforming struct for +1 min, –1 min, Cancel.
These run in the main app on tap from the Dynamic Island. Requires the
app and widget to share a common target via a framework or package so the
intent type is available in both. Non-trivial — defer to a second pass.

#### Signing + CI
- Generate a second App Store provisioning profile for the widget bundle id
  (`com.llamascookbook.app.widget`).
- Add `IOS_WIDGET_PROVISIONING_PROFILE_BASE64` secret in GitHub Actions.
- Update [`ios-native-ci.yml`](./.github/workflows/ios-native-ci.yml) to
  install both profiles and sign both targets. `ExportOptions.plist` needs
  `provisioningProfiles` entries for both bundle ids.

### Risks
- **Signing friction.** Two provisioning profiles on a Windows-CI-only
  setup means one more secret to rotate, one more thing to mismatch.
- **App Store review.** Live Activities for cooking timers are routine,
  but the reviewer may ping us for "why" if the presentation looks generic.
  Solution: include the recipe title + step number, not just the countdown.
- **State-reset on force-kill.** When the user force-quits the app, iOS
  automatically ends the Live Activity. If the user relaunches within the
  timer window, we currently lose the in-app timer state. We should persist
  `timerEndsAt` / `timerStepId` / `timerLabel` to `UserDefaults` at start
  and restore on launch — otherwise the Live Activity keeps counting in
  the Dynamic Island but the app itself forgets which step was timing.
  This should land *before* Live Activity ships.

### Rough time estimate
~3–5 hours of Xcode work on a real Mac (target plumbing, widget UI,
wiring, signing). A pure Windows-CI iteration is doable but painful
because signing errors can't be reproduced locally.

### Sequencing
1. Land timer-state persistence (small, standalone, useful now).
2. Add the widget extension target + minimal Live Activity (lock-screen
   + compact Dynamic Island only).
3. Iterate on expanded Dynamic Island.
4. Add App Intents for in-island +1/-1/cancel.

### Status
- ✅ TimerAttributes shared type: `ios-native/Sources/Shared/TimerAttributes.swift`
- ✅ Widget target in `ios-native/project.yml` (`LlamasCookbookTimerWidget`)
- ✅ Widget UI: `ios-native/WidgetExtension/TimerLiveActivity.swift`
   (lock-screen + compact / minimal / expanded Dynamic Island)
- ✅ Widget Info.plist with `NSExtensionPointIdentifier`
- ✅ Main app Info.plist flag `NSSupportsLiveActivities: YES`
- ✅ `TimerLiveActivityController` wrapper for start/update/end
- ✅ Wired through `CookModeView` start / extend / cancel / stop / disappear
- ✅ CI workflow installs both provisioning profiles + embeds widget in archive
- ⏳ Apple Developer portal work (see section 0 above) — **user action required**
- ⏳ App Intents for in-island controls (iOS 17+)
- ⏳ Timer-state persistence via UserDefaults so a force-killed app restores the running timer

---

## 2. Future items (placeholder)

Additional deferred work goes here when we identify it.
