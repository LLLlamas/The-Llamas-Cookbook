import AVFoundation
import AudioToolbox

/// Plays the user's chosen `TimerSound` while the in-app
/// `TimerReadyOverlay` is visible. Loops `bell` (bundled `.caf` via
/// `AVAudioPlayer`); for `chime` / `ping` / `system` it fires a
/// non-loopable `SystemSoundID` once, so the caller's per-tick
/// haptic loop also drives the audio re-trigger cadence.
/// `silent` is a true no-op — vibration alone alerts the user.
@MainActor
final class AlarmPlayer {
    private var player: AVAudioPlayer?
    /// SystemSoundID-based cadence: a Task that re-plays the
    /// fire-and-forget tone every few seconds while the alarm is
    /// active. `AVAudioPlayer` paths leave this nil — they loop
    /// natively via `numberOfLoops = -1`.
    private var systemSoundLoopTask: Task<Void, Never>?
    private var previewAutoStopTask: Task<Void, Never>?

    func start(sound: TimerSound, volume: TimerVolume) {
        guard player == nil, systemSoundLoopTask == nil else { return }
        previewAutoStopTask?.cancel()
        previewAutoStopTask = nil

        switch sound {
        case .silent:
            return
        case .bell:
            startLoopedFile(named: sound.bundledCAFName, volume: volume)
        case .chime, .ping, .system:
            guard let id = sound.systemSoundID else { return }
            startSystemSoundLoop(id: id)
        }
    }

    /// One-shot playback for the settings-row preview tap. Cuts off
    /// any in-flight alarm first so a user adjusting picks while a
    /// timer is ringing doesn't stack tones.
    func previewOnce(sound: TimerSound, volume: TimerVolume) {
        stop()
        guard sound != .silent else { return }

        if let name = sound.bundledCAFName,
           let url = Bundle.main.url(forResource: name, withExtension: "caf") {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
                try AVAudioSession.sharedInstance().setActive(true, options: [])
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = 0
                p.volume = volume.level
                p.prepareToPlay()
                p.play()
                player = p
            } catch {
                player = nil
            }
        } else if let id = sound.systemSoundID {
            AudioServicesPlaySystemSound(id)
        }

        // Auto-release after 3 s so we don't hold the audio session
        // open between previews.
        previewAutoStopTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            stop()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        systemSoundLoopTask?.cancel()
        systemSoundLoopTask = nil
        previewAutoStopTask?.cancel()
        previewAutoStopTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startLoopedFile(named name: String?, volume: TimerVolume) {
        guard let name,
              let url = Bundle.main.url(forResource: name, withExtension: "caf")
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
            // Silent fallback — vibration path in CookModeView still runs.
            player = nil
        }
    }

    /// Re-fires a non-loopable `SystemSoundID` every 2 s so chime/ping
    /// behave like an ongoing alarm rather than a one-shot ding. The
    /// system tones themselves are short (<1 s) and ignore
    /// `AVAudioPlayer.volume` — they ride the system Ringer level —
    /// so the volume picker is a no-op for these sounds. Documented
    /// in the settings sheet's footnote.
    private func startSystemSoundLoop(id: SystemSoundID) {
        AudioServicesPlaySystemSound(id)
        systemSoundLoopTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                AudioServicesPlaySystemSound(id)
            }
        }
    }
}
