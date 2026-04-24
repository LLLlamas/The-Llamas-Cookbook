import AVFoundation

/// Plays the bundled `timer-alarm.caf` on loop while the in-app
/// `TimerReadyOverlay` is visible. Falls back silently if the resource
/// isn't in the bundle (dev builds that skipped CI) — vibration + haptic
/// still fire so the user is alerted either way.
@MainActor
final class AlarmPlayer {
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        guard let url = Bundle.main.url(forResource: "timer-alarm", withExtension: "caf") else {
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 0.9
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            // Silent fallback — vibration path in CookModeView still runs.
            player = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
