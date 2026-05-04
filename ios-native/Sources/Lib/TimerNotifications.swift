import AlarmKit
import Foundation
import SwiftUI

/// Cook-timer fire-path. Schedules and cancels per-cook alarms via
/// AlarmKit (iOS 26+) so the alert reaches the user on the lock
/// screen, in another app, and in Silent mode without needing the
/// Critical Alerts entitlement. AlarmKit also owns the countdown +
/// alert Live Activity presentation, so the widget extension's
/// `ActivityConfiguration<AlarmAttributes<TimerAlarmMetadata>>`
/// renders Dynamic Island + lock-screen UI from the same scheduled
/// alarm — no separate `TimerLiveActivityController` round-trip.
///
/// Type name + method shapes are deliberately preserved from the
/// pre-AlarmKit `UNUserNotificationCenter` implementation so
/// `CookModeView` + `CookingSession` call sites don't churn.
enum TimerNotifications {
    /// Per-cook deterministic UUID derived from `cookID`. AlarmKit
    /// keys alarms by UUID, and we want re-scheduling the same cook's
    /// timer (extend/subtract, step transitions) to overwrite the
    /// existing alarm rather than stacking. Using `cookID` directly
    /// is convenient — it's already a UUID and unique per cook.
    private static func alarmID(for cookID: UUID) -> UUID { cookID }

    // Kept as no-ops for symmetry with old call sites (e.g. AppDelegate
    // routes that still read these from a `userInfo` dict). AlarmKit
    // doesn't carry arbitrary `userInfo` through to the tap callback the
    // way `UNNotificationContent` did — recipe routing now lives on
    // `TimerAlarmMetadata` instead.
    static let recipeIDUserInfoKey = "recipeID"
    static let cookIDUserInfoKey = "cookID"

    /// Request AlarmKit authorization. Idempotent; subsequent calls
    /// after the user's first decision return the cached state without
    /// re-prompting. Fire-and-forget — caller doesn't await; the
    /// schedule call below silently no-ops when authorization is
    /// missing so a denied user still sees the in-app ready overlay.
    static func requestPermission() {
        Task {
            do {
                _ = try await AlarmManager.shared.requestAuthorization()
            } catch {
                // Auth failures degrade to the in-app `AlarmPlayer`
                // path — Cook Mode still rings while foregrounded, the
                // lock-screen alert just won't fire.
            }
        }
    }

    /// Current AlarmKit authorization state. Useful for surfacing a
    /// one-time "lock-screen alerts are off" hint in Cook Mode when
    /// the user has denied. Returns nil if the AlarmKit accessor
    /// shape on the running SDK doesn't match — degrades to "we don't
    /// know," which the UI should treat as "don't show the hint."
    static func currentAuthorizationState() -> AlarmManager.AuthorizationState {
        AlarmManager.shared.authorizationState
    }

    /// Schedule (or replace) the AlarmKit alarm for one cook. Per cook,
    /// not per timer slot — re-extending the same cook's running timer
    /// rewrites the cook's existing alarm. Two concurrent cooks each
    /// get their own alarm keyed by `cookID`, so neither overwrites
    /// the other.
    ///
    /// `timerSound` mapping: `bell` → bundled `timer-alarm.caf`,
    /// `system` → AlarmKit's default tone, `silent` → no sound. The
    /// in-app `AlarmPlayer` continues to ring the foregrounded ready
    /// overlay independently using the same `TimerSettings` pick.
    static func schedule(
        cookID: UUID,
        endDate date: Date,
        label: String,
        recipeID: UUID,
        recipeTitle: String,
        stepNumber: Int,
        stepText: String?,
        timerSound: TimerSound
    ) {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return }

        let id = alarmID(for: cookID)
        let metadata = TimerAlarmMetadata(
            recipeTitle: recipeTitle,
            recipeID: recipeID,
            cookID: cookID,
            label: label,
            stepNumber: stepNumber,
            endDate: date
        )

        Task {
            // Defensive: cancel any existing alarm under this cookID so
            // re-scheduling on extend / step transition doesn't stack.
            // AlarmKit's `schedule(...)` is documented to overwrite an
            // existing alarm with the same id, but cancel-then-schedule
            // is the safer ordering on the public-beta API surface.
            try? AlarmManager.shared.cancel(id: id)

            let alertTitle = formatTitle(recipeTitle: recipeTitle, stepNumber: stepNumber)
            let alertBody = formatBody(label: label, stepText: stepText)

            let presentation = AlarmPresentation(
                alert: AlarmPresentation.Alert(
                    title: LocalizedStringResource(stringLiteral: alertTitle),
                    stopButton: AlarmButton(
                        text: LocalizedStringResource(stringLiteral: "Stop"),
                        textColor: .white,
                        systemImageName: "stop.fill"
                    )
                ),
                countdown: AlarmPresentation.Countdown(
                    title: LocalizedStringResource(stringLiteral: alertBody),
                    pauseButton: nil
                )
            )

            let attributes = AlarmAttributes<TimerAlarmMetadata>(
                presentation: presentation,
                metadata: metadata,
                tintColor: Color(red: 0.788, green: 0.486, blue: 0.365)
            )

            let configuration = AlarmManager.AlarmConfiguration<TimerAlarmMetadata>(
                countdownDuration: .init(preAlert: seconds, postAlert: nil),
                attributes: attributes,
                sound: alarmSound(for: timerSound)
            )

            do {
                _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
            } catch {
                // Authorization missing or scheduling rejected.
                // Foregrounded ready overlay still rings via AlarmPlayer.
            }
        }
    }

    /// Map `TimerSound` to AlarmKit's `AlertConfiguration.AlertSound`.
    /// `bell` references the bundled `.caf` by name; `system` uses
    /// AlarmKit's default tone; `silent` returns nil so AlarmKit
    /// suppresses audio (the alert still fires visually + haptically).
    /// Chime / ping aren't in the picker today — they fall back to
    /// `.default` for safety if a future picker re-enables them.
    private static func alarmSound(for sound: TimerSound) -> AlertSound? {
        switch sound {
        case .silent:
            return nil
        case .bell:
            if Bundle.main.url(forResource: "timer-alarm", withExtension: "caf") != nil {
                return .named("timer-alarm")
            }
            return .default
        case .system, .chime, .ping:
            return .default
        }
    }

    private static func formatTitle(recipeTitle: String, stepNumber: Int) -> String {
        let trimmed = recipeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Step \(stepNumber) ready"
        }
        return "\(StringCase.titleCase(trimmed)) — Step \(stepNumber) ready"
    }

    private static func formatBody(label: String, stepText: String?) -> String {
        if let raw = stepText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            // Cap to keep the body single-line on the alert presentation —
            // AlarmKit's countdown title truncates past about 110 chars.
            let snippet = raw.count > 100 ? raw.prefix(100) + "…" : Substring(raw)
            return "\(snippet) — tap to check it off."
        }
        return "Your \(label) timer is ready. Tap to continue cooking."
    }

    /// Cancel the alarm + dismiss its Live Activity for one cook only.
    /// Other cooks' alarms are untouched.
    static func cancel(cookID: UUID) {
        let id = alarmID(for: cookID)
        try? AlarmManager.shared.cancel(id: id)
    }

    /// Tear down every cooking-timer alarm. Called from
    /// `CookingSession.endAll()` when the whole session is torn down.
    /// Enumerates every alarm AlarmKit knows about and cancels each —
    /// safe because the only alarms this app schedules are cooking
    /// timers (so `alarms` never contains anything we want to keep).
    static func cancelAll() {
        Task {
            // AlarmManager.alarms surface is in flux on the iOS 26
            // public-beta SDK; if the accessor is sync-throws on this
            // build, drop the `await` here.
            guard let alarms = try? await AlarmManager.shared.alarms else { return }
            for alarm in alarms {
                try? AlarmManager.shared.cancel(id: alarm.id)
            }
        }
    }
}
