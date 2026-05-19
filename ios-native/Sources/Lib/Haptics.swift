import UIKit
import CoreHaptics

enum Haptics {
    @MainActor
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    @MainActor
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @MainActor
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @MainActor
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    // MARK: - CoreHaptics save thud

    /// A satisfying, weighty "thud" played when a recipe is committed to
    /// the library. High intensity + medium-low sharpness reads as a soft,
    /// padded hit rather than a crisp click — the tactile equivalent of a
    /// cookbook closing. Falls back to a heavy `UIImpact` hit on devices
    /// without a haptic engine.
    @MainActor
    static func recipeSaved() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            return
        }
        HapticEngineHost.shared.playThud()
    }

    // MARK: - Ascending impact ramps

    /// Three-hit ascending punch played as Cook Mode spins up — light →
    /// medium → heavy over ~0.4s. Pure `UIImpactFeedbackGenerator`; no
    /// CoreHaptics needed for a fixed three-tap pattern.
    @MainActor
    static func cookModeStarted() {
        playAscendingRamp(spacing: 0.12)
    }

    /// Tighter ascending ramp (~0.08s between hits) fired when a running
    /// cook timer drops to 3 seconds left — a "brace yourself" pre-alert
    /// just before the AlarmKit alert fires.
    @MainActor
    static func timerAlmostDone() {
        playAscendingRamp(spacing: 0.08)
    }

    /// Fire `.light`, `.medium`, `.heavy` impacts spaced `spacing` seconds
    /// apart. The generators are created up front so each hit plays through
    /// a prepared generator rather than a cold one.
    @MainActor
    private static func playAscendingRamp(spacing: TimeInterval) {
        let light = UIImpactFeedbackGenerator(style: .light)
        let medium = UIImpactFeedbackGenerator(style: .medium)
        let heavy = UIImpactFeedbackGenerator(style: .heavy)
        light.prepare()
        medium.prepare()
        heavy.prepare()

        light.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + spacing) {
            medium.impactOccurred()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + spacing * 2) {
            heavy.impactOccurred()
        }
    }
}

// MARK: - CoreHaptics engine host

/// Lazily-warmed singleton owner of the shared `CHHapticEngine`. Keeping a
/// single long-lived engine avoids the ~10ms cold-start cost on every
/// `recipeSaved()` call. The engine is re-created transparently if iOS
/// resets it (audio-session interruptions, app backgrounding) — all
/// failure paths are swallowed silently; a missed haptic is never worth a
/// crash or a visible error.
@MainActor
private final class HapticEngineHost {
    static let shared = HapticEngineHost()

    private var engine: CHHapticEngine?

    private init() {}

    /// Return a started engine, building one on first use and rebuilding
    /// after an iOS-initiated reset. Returns nil if the engine can't be
    /// created at all (caller falls back to `UIImpact`).
    private func startedEngine() -> CHHapticEngine? {
        if let engine { return engine }
        do {
            let newEngine = try CHHapticEngine()
            // iOS can reset the engine out from under us (interruptions,
            // backgrounding). Drop our reference so the next call rebuilds.
            // CoreHaptics invokes these handlers off the main thread, so
            // hop back before touching the `@MainActor`-isolated property.
            newEngine.resetHandler = { [weak self] in
                Task { @MainActor in self?.engine = nil }
            }
            newEngine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.engine = nil }
            }
            try newEngine.start()
            engine = newEngine
            return newEngine
        } catch {
            engine = nil
            return nil
        }
    }

    /// Play the soft, weighty save thud — a single transient event with
    /// high intensity (~0.9) and medium-low sharpness (~0.3).
    func playThud() {
        guard let engine = startedEngine() else {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            return
        }
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
            ],
            relativeTime: 0
        )
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Engine may have died between start and play — drop it so the
            // next call rebuilds, and fall back to a UIImpact hit.
            self.engine = nil
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
    }
}
