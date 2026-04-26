import Foundation
import UserNotifications

/// Local-notification helper for cooking timers. Schedules a single
/// alert-with-sound notification for the timer's end time so the user
/// still hears the ding when the app is backgrounded or the phone is
/// locked. Live Activity (Dynamic Island) is a separate future path —
/// this just handles the "don't miss the timer" baseline.
enum TimerNotifications {
    private static let identifier = "cooking-timer"

    /// Request alert+sound permission. Idempotent — iOS caches the answer
    /// and subsequent calls return the cached decision without re-prompting.
    static func requestPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Schedule (or replace) the timer notification to fire at `date`.
    /// The copy folds in the recipe title, step number, and a snippet of
    /// the step text so the banner reads as "Brownies — Step 4 done /
    /// Bake at 350°F for 25 min" rather than a generic "Step X is done".
    /// `stepText` is optional — when blank we fall back to a label-based
    /// hint ("Your bake timer is ready").
    static func schedule(
        endDate date: Date,
        label: String,
        recipeTitle: String,
        stepNumber: Int,
        stepText: String?
    ) {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = formatTitle(recipeTitle: recipeTitle, stepNumber: stepNumber)
        content.body = formatBody(label: label, stepText: stepText)
        // Bundled beep-pattern CAF (see workflow's "Generate timer alarm
        // sound" step). Falls back to the system default ding if the
        // file is missing (e.g. a local dev build that skipped CI).
        if let _ = Bundle.main.url(forResource: "timer-alarm", withExtension: "caf") {
            content.sound = UNNotificationSound(named: UNNotificationSoundName("timer-alarm.caf"))
        } else {
            content.sound = .default
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        let center = UNUserNotificationCenter.current()
        // Replace any previously scheduled request so extend/subtract
        // and step-to-step transitions don't leave stale notifications.
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.add(request, withCompletionHandler: nil)
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
            // Cap to keep the body single-line on the lock screen — iOS
            // truncates with an ellipsis past about 110 chars in 2-line
            // banner mode. We pre-trim slightly under that to leave room
            // for the trailing prompt.
            let snippet = raw.count > 100 ? raw.prefix(100) + "…" : Substring(raw)
            return "\(snippet) — tap to check it off."
        }
        return "Your \(label) timer is ready. Tap to continue cooking."
    }

    /// Remove any pending or already-delivered cooking-timer notification.
    /// Called on cancel, and when the in-app ready overlay is dismissed
    /// so a stale banner doesn't linger in the notification center.
    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
