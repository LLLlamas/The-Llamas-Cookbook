import AVFoundation

/// Plays the in-app cook-timer alert during the `TimerReadyOverlay`.
/// Unified on the bundled `timer-alarm.caf` so the foreground tone
/// matches the AlarmKit lock-screen alert exactly (AlarmKit references
/// the same file via `.named("timer-alarm")`). The `TimerSound`
/// parameter is preserved on the API surface for call-site stability
/// but no longer changes which file plays.
@MainActor
final class AlarmPlayer {
    private var player: AVAudioPlayer?
    private var previewAutoStopTask: Task<Void, Never>?

    func start(sound: TimerSound, volume: TimerVolume) {
        guard player == nil else { return }
        previewAutoStopTask?.cancel()
        previewAutoStopTask = nil
        startLoopedFile(volume: volume)
    }

    /// One-shot playback for the settings-row preview tap. Cuts off
    /// any in-flight alarm first so a user adjusting picks while a
    /// timer is ringing doesn't stack tones.
    func previewOnce(sound: TimerSound, volume: TimerVolume) {
        stop()
        guard let url = Bundle.main.url(forResource: "timer-alarm", withExtension: "caf") else { return }
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
        previewAutoStopTask?.cancel()
        previewAutoStopTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startLoopedFile(volume: TimerVolume) {
        guard let url = Bundle.main.url(forResource: "timer-alarm", withExtension: "caf")
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
}
