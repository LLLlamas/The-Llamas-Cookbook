# Timer Sound Settings

Feature plan for per-user timer sound + haptic preferences, surfaced in the Profile settings cog.

Last updated: 2026-05-03.

---

## What iOS lets us control (and what it doesn't)

**Sound choice — yes, with our own bundles.** `UNNotificationSound(named:)` plays any `.caf` / `.wav` file you ship inside the app bundle. Apple's named alarm tones from the Clock app (`Radar`, `Beacon`, `Ripples`, etc.) are private and unreachable to third-party apps — you can't pass those names to `UNNotificationSound`. The system default (`UNNotificationSound.default`) is available and maps to whatever the user has set as their default notification sound in Settings > Sounds.

Bottom line: **bundle our own 3-4 short sounds**. The app already ships `timer-alarm.caf`; we add 2-3 more `.caf` files alongside it. Each sound plays identically whether the timer fires in-app (via `AlarmPlayer`) or via the lock-screen notification.

**Volume — in-app only.** `AVAudioPlayer.volume` is fully controllable (0.0–1.0); `AlarmPlayer` currently hardcodes 0.9. We can expose Low / Medium / Full for the in-app alarm. Lock-screen notification volume follows the system Ringer volume — **no app can override that independently**. We should note this in the UI so users know to adjust Ringer volume in Settings if the notification is too quiet.

**Vibration / haptic intensity — yes for the in-app alarm.** The current `alarmTask` fires `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)` + `Haptics.warning()` every 1.2 s. iOS 13+ `CHHapticEngine` (CoreHaptics) gives us custom patterns: timing, intensity, sharpness. We can offer Off / Pulse (current) / Rapid (tighter rhythm) as named presets using a small CoreHaptics pattern dictionary per mode. Lock-screen notification haptics are system-managed and not separately configurable per app.

---

## Proposed sound library (4 options)

| Key | Filename | Character | Duration |
|-----|----------|-----------|----------|
| `bell` | `timer-alarm.caf` | Existing alarm bell | ~2 s |
| `chime` | `timer-chime.caf` | Soft wind-chime strike | ~1.5 s |
| `ping` | `timer-ping.caf` | Short crisp ping | ~0.6 s |
| `default` | (none — `UNNotificationSound.default`) | System default notification tone | n/a |

Source `timer-chime.caf` and `timer-ping.caf` from a royalty-free library (Freesound CC0, Zapsplat free tier, or commissioned). Target: mono, 44.1 kHz, `.caf` container, under 3 s.

A "Silent (vibrate only)" option is also valid — just omit the `AVAudioPlayer.start()` call and still run the haptic loop.

---

## New model: `TimerSettings`

Mirror the `AppearanceSettings` pattern exactly — `@Observable`, UserDefaults-backed, environment-injected.

```swift
// ios-native/Sources/App/TimerSettings.swift
import Foundation

enum TimerSound: String, CaseIterable {
    case bell    = "bell"      // timer-alarm.caf (existing)
    case chime   = "chime"     // timer-chime.caf
    case ping    = "ping"      // timer-ping.caf
    case system  = "system"    // UNNotificationSound.default
    case silent  = "silent"    // vibrate only

    var displayName: String {
        switch self {
        case .bell:   return "Bell"
        case .chime:  return "Chime"
        case .ping:   return "Ping"
        case .system: return "Default"
        case .silent: return "Silent"
        }
    }

    // nil → UNNotificationSound.default
    var cafFilename: String? {
        switch self {
        case .bell:   return "timer-alarm"
        case .chime:  return "timer-chime"
        case .ping:   return "timer-ping"
        case .system, .silent: return nil
        }
    }
}

enum TimerHaptic: String, CaseIterable {
    case off     = "off"
    case pulse   = "pulse"    // current: kSystemSoundID_Vibrate every 1.2 s
    case rapid   = "rapid"    // CoreHaptics: tight double-tap every 0.8 s

    var displayName: String {
        switch self {
        case .off:    return "Off"
        case .pulse:  return "Pulse"
        case .rapid:  return "Rapid"
        }
    }
}

enum TimerVolume: String, CaseIterable {
    case low    = "low"     // 0.4
    case medium = "medium"  // 0.65
    case full   = "full"    // 0.9 (current default)

    var level: Float {
        switch self {
        case .low:    return 0.4
        case .medium: return 0.65
        case .full:   return 0.9
        }
    }

    var displayName: String {
        switch self {
        case .low:    return "Low"
        case .medium: return "Medium"
        case .full:   return "Full"
        }
    }
}

@Observable
final class TimerSettings {
    private static let soundKey   = "timerSound"
    private static let hapticKey  = "timerHaptic"
    private static let volumeKey  = "timerVolume"

    var sound:   TimerSound   = .bell
    var haptic:  TimerHaptic  = .pulse
    var volume:  TimerVolume  = .full

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.soundKey),
           let v   = TimerSound(rawValue: raw)   { sound  = v }
        if let raw = UserDefaults.standard.string(forKey: Self.hapticKey),
           let v   = TimerHaptic(rawValue: raw)  { haptic = v }
        if let raw = UserDefaults.standard.string(forKey: Self.volumeKey),
           let v   = TimerVolume(rawValue: raw)  { volume = v }
    }

    func persist() {
        UserDefaults.standard.set(sound.rawValue,  forKey: Self.soundKey)
        UserDefaults.standard.set(haptic.rawValue, forKey: Self.hapticKey)
        UserDefaults.standard.set(volume.rawValue, forKey: Self.volumeKey)
    }
}
```

Instantiate in `LlamasCookbookApp` alongside `AppearanceSettings` and inject with `.environment(timerSettings)`.

---

## Wire-up changes

### AlarmPlayer

Add `start(sound: TimerSound, volume: TimerVolume)`:

```swift
func start(sound: TimerSound, volume: TimerVolume) {
    guard player == nil else { return }
    guard sound != .silent else { return }  // vibrate-only path
    guard let name = sound.cafFilename,
          let url  = Bundle.main.url(forResource: name, withExtension: "caf")
    else { return }

    do {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try AVAudioSession.sharedInstance().setActive(true, options: [])
        let p = try AVAudioPlayer(contentsOf: url)
        p.numberOfLoops = -1
        p.volume = volume.level
        p.prepareToPlay()
        p.play()
        player = p
    } catch {
        player = nil
    }
}
```

Keep the no-arg `start()` as a fallback for any call sites that haven't been updated yet — it continues to call the new `start(sound: .bell, volume: .full)`.

### TimerNotifications

`schedule(...)` already has the `timer-alarm.caf` fallback path. Pass the sound in:

```swift
// In TimerNotifications.schedule(...)
if let name = timerSound.cafFilename,
   Bundle.main.url(forResource: name, withExtension: "caf") != nil {
    content.sound = UNNotificationSound(named: UNNotificationSoundName("\(name).caf"))
} else if timerSound == .silent {
    content.sound = nil   // silent notification — still appears in NC
} else {
    content.sound = .default
}
```

Add `timerSound: TimerSound` parameter to `schedule(...)`. Call sites in `CookModeView.startTimer` and `extendTimer` read `@Environment(TimerSettings.self)` and pass `settings.sound`.

### CookModeView.startAlarm

```swift
// Inject at top of CookModeView:
@Environment(TimerSettings.self) private var timerSettings

private func startAlarm() {
    alarmPlayer.start(sound: timerSettings.sound, volume: timerSettings.volume)
    alarmTask?.cancel()
    alarmTask = Task { @MainActor in
        while !Task.isCancelled {
            timerSettings.haptic.fire()     // see §Haptic helper below
            try? await Task.sleep(for: .milliseconds(timerSettings.haptic.intervalMs))
        }
    }
}
```

### Haptic helper on TimerHaptic

```swift
extension TimerHaptic {
    var intervalMs: Int {
        switch self {
        case .off:    return 2000
        case .pulse:  return 1200   // current
        case .rapid:  return 800
        }
    }

    func fire() {
        switch self {
        case .off: break
        case .pulse:
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            Haptics.warning()
        case .rapid:
            // CoreHaptics double-tap
            playRapidHaptic()
        }
    }
}
```

`playRapidHaptic()` is a file-private helper that creates a `CHHapticEngine` pattern — two sharp transient events 0.1 s apart, intensity 0.9. CoreHaptics requires a running engine; create it lazily and restart on `AVAudioSession` interruption.

---

## Profile UI placement

The settings cog sheet in `ProfileView` already handles Sign Out / Delete Account. Add a **Cook Mode** section above the destructive actions:

```
Cook Mode
  Timer Sound       Bell  >
  Alarm Volume      Full  >
  Vibration         Pulse >
```

Each row is a `NavigationLink` (if the cog sheet is in a `NavigationStack`) or a `.sheet`-driven picker. A short preview plays when the user lifts their finger from a new sound row — use `AlarmPlayer.previewOnce(sound:)` (single non-looping play, auto-stop after 3 s).

Alternatively, inline pickers (one `Picker(.segmented)` per setting) keep the sheet single-page without nested navigation — fine given there are only 4/3/3 options per setting.

---

## Preview helper (one-shot playback)

Needed so the user hears what they're picking before confirming:

```swift
// AlarmPlayer addition
func previewOnce(sound: TimerSound, volume: TimerVolume) {
    stop()  // cut off any live alarm
    guard sound != .silent,
          let name = sound.cafFilename,
          let url  = Bundle.main.url(forResource: name, withExtension: "caf") else { return }

    do {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try AVAudioSession.sharedInstance().setActive(true, options: [])
        let p = try AVAudioPlayer(contentsOf: url)
        p.numberOfLoops = 0
        p.volume = volume.level
        p.prepareToPlay()
        p.play()
        player = p
        // Auto-release after 3 s so we don't hold the audio session open.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            stop()
        }
    } catch {
        player = nil
    }
}
```

---

## What to note in the UI

- "Alarm volume only affects the in-app alert. To adjust lock-screen notification volume, use your phone's Ringer volume."
- Silent mode suppresses both the in-app sound and the notification sound — vibration still works unless Vibration is also set to Off.

---

## Files to touch

| File | Change |
|------|--------|
| `Sources/App/TimerSettings.swift` | **New** — model |
| `Sources/App/LlamasCookbookApp.swift` | Instantiate + inject `TimerSettings` |
| `Sources/Lib/AlarmPlayer.swift` | Add `start(sound:volume:)` + `previewOnce(sound:volume:)` |
| `Sources/Lib/TimerNotifications.swift` | Add `timerSound` param to `schedule(...)` |
| `Sources/Views/Cook/CookModeView.swift` | Read `TimerSettings` in `startAlarm()` + `startTimer()` + `extendTimer()` |
| `Sources/Views/Profile/ProfileView.swift` | Cook Mode section in cog sheet |
| `ios-native/Resources/` | Add `timer-chime.caf`, `timer-ping.caf` |
| `ios-native/project.yml` | List new `.caf` resources in `Copy Bundle Resources` |
