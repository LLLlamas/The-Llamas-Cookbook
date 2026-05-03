import Foundation
import AudioToolbox
import UserNotifications

/// User-customizable cook-timer alert preferences. Source of truth for
/// `AlarmPlayer` (in-app loop) and `TimerNotifications.schedule` (lock-
/// screen banner) — both read this at fire time so a change in the
/// settings sheet takes effect on the next timer without restart.
///
/// Sibling pattern to `AppearanceSettings`: instantiated in
/// `LlamasCookbookApp`, injected via `.environment(...)`, persisted to
/// UserDefaults via `didSet` so picks survive cold launch.
@Observable
final class TimerSettings {
    private static let soundKey  = "timerSound"
    private static let hapticKey = "timerHaptic"
    private static let volumeKey = "timerVolume"

    /// Suppress writes during rehydrate so a cold launch doesn't churn
    /// UserDefaults with the same values it just read.
    private var isInitializing: Bool = true

    var sound: TimerSound = .bell {
        didSet {
            guard !isInitializing else { return }
            UserDefaults.standard.set(sound.rawValue, forKey: Self.soundKey)
        }
    }

    var haptic: TimerHaptic = .pulse {
        didSet {
            guard !isInitializing else { return }
            UserDefaults.standard.set(haptic.rawValue, forKey: Self.hapticKey)
        }
    }

    var volume: TimerVolume = .full {
        didSet {
            guard !isInitializing else { return }
            UserDefaults.standard.set(volume.rawValue, forKey: Self.volumeKey)
        }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.soundKey),
           let v = TimerSound(rawValue: raw) { sound = v }
        if let raw = UserDefaults.standard.string(forKey: Self.hapticKey),
           let v = TimerHaptic(rawValue: raw) { haptic = v }
        if let raw = UserDefaults.standard.string(forKey: Self.volumeKey),
           let v = TimerVolume(rawValue: raw) { volume = v }
        isInitializing = false
    }
}

// MARK: - Sound

/// Five timer sound choices. `bell` is the bundled `timer-alarm.caf`
/// (the only custom file shipping today — playable both in-app and as
/// the lock-screen `UNNotificationSound`). `chime` and `ping` use
/// built-in iOS `SystemSoundID` tones for the in-app loop; on the
/// lock screen they fall back to `.default` because third-party apps
/// can't reference Apple's private alarm-tone library
/// (Radar/Beacon/etc.) via `UNNotificationSound`. `system` is the
/// user's chosen default notification tone everywhere. `silent`
/// suppresses sound on both surfaces — vibration still fires unless
/// `TimerHaptic` is also `.off`.
enum TimerSound: String, CaseIterable, Identifiable {
    case bell   = "bell"
    case chime  = "chime"
    case ping   = "ping"
    case system = "system"
    case silent = "silent"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bell:   return "Bell"
        case .chime:  return "Chime"
        case .ping:   return "Ping"
        case .system: return "Default"
        case .silent: return "Silent"
        }
    }

    /// `.caf` filename in the main bundle for sounds that ship as
    /// custom audio assets. Only `bell` does today; chime/ping rely on
    /// `SystemSoundID` for the in-app loop and `.default` for the
    /// lock-screen banner.
    var bundledCAFName: String? {
        switch self {
        case .bell:                            return "timer-alarm"
        case .chime, .ping, .system, .silent:  return nil
        }
    }

    /// Built-in iOS system sound used when the in-app loop can't pull
    /// from a bundled file. `nil` for `bell` (uses the bundled .caf
    /// looped via AVAudioPlayer) and `silent` (no sound). Picked from
    /// the documented SystemSoundID set so they're guaranteed present
    /// on every device.
    var systemSoundID: SystemSoundID? {
        switch self {
        case .bell:   return nil
        case .chime:  return 1013   // Tri-tone — soft three-note bell
        case .ping:   return 1054   // Tink — short crisp tick
        case .system: return 1304   // Default new-message alert
        case .silent: return nil
        }
    }

    /// Lock-screen notification sound. `bell` uses the bundled .caf
    /// directly; everything else falls back to `.default` (or nil for
    /// `silent`) because there's no public API to reference Apple's
    /// private alarm tones from a `UNNotificationSound`.
    var notificationSound: UNNotificationSound? {
        switch self {
        case .bell:
            if Bundle.main.url(forResource: "timer-alarm", withExtension: "caf") != nil {
                return UNNotificationSound(named: UNNotificationSoundName("timer-alarm.caf"))
            }
            return .default
        case .chime, .ping, .system:
            return .default
        case .silent:
            return nil
        }
    }
}

// MARK: - Haptic

/// Vibration cadence during the in-app ready overlay. Lock-screen
/// notification haptics are system-managed and not separately
/// configurable per app, so this only affects the foreground alarm
/// loop.
enum TimerHaptic: String, CaseIterable, Identifiable {
    case off   = "off"
    case pulse = "pulse"
    case rapid = "rapid"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:   return "Off"
        case .pulse: return "Pulse"
        case .rapid: return "Rapid"
        }
    }

    /// Cadence between successive vibration fires while the ready
    /// overlay is up. `.off` returns a long sleep so the alarm task
    /// effectively idles without spinning.
    var intervalMilliseconds: Int {
        switch self {
        case .off:   return 2000
        case .pulse: return 1200
        case .rapid: return 600
        }
    }
}

// MARK: - Volume

/// In-app `AVAudioPlayer.volume` level. Lock-screen notification
/// volume follows the system Ringer slider — no app can override that
/// per-notification, so this slider only affects the foreground loop.
enum TimerVolume: String, CaseIterable, Identifiable {
    case low    = "low"
    case medium = "medium"
    case full   = "full"

    var id: String { rawValue }

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
