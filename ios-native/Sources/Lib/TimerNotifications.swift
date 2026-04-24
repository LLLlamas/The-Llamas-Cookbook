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

    /// Schedule (or replace) the timer notification to fire at `date` with
    /// a copy keyed off the cooking label ("Bake timer ready", etc.).
    static func schedule(endDate date: Date, label: String) {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(StringCase.capitalizeFirst(label)) timer ready!"
        content.body = "Time's up — check on your food."
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

    /// Remove any pending or already-delivered cooking-timer notification.
    /// Called on cancel, and when the in-app ready overlay is dismissed
    /// so a stale banner doesn't linger in the notification center.
    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
