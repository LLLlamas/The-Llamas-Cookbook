import Foundation
import UserNotifications

/// Local-notification helper for cooking timers. Schedules a single
/// alert-with-sound notification for the timer's end time so the user
/// still hears the ding when the app is backgrounded or the phone is
/// locked. Live Activity (Dynamic Island) is a separate future path —
/// this just handles the "don't miss the timer" baseline.
enum TimerNotifications {
    /// Per-cook identifier prefix. Each active cook's pending timer
    /// notification lives under `cooking-timer-<cookID>` so two
    /// concurrent cooks (e.g. muffins + pizza dough) each get their
    /// own dedicated lock-screen banner instead of one overwriting the
    /// other. The legacy single-id `"cooking-timer"` key is kept only
    /// in `cancelAll` for cleanup of pre-multi installs.
    private static let identifierPrefix = "cooking-timer-"
    private static let legacyIdentifier = "cooking-timer"

    private static func identifier(for cookID: UUID) -> String {
        "\(identifierPrefix)\(cookID.uuidString)"
    }

    /// Request alert+sound permission. Idempotent — iOS caches the answer
    /// and subsequent calls return the cached decision without re-prompting.
    static func requestPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `userInfo` keys. `recipeID` rides along so the AppDelegate's
    /// `didReceive` handler can deep-link back to the right recipe via
    /// `llamascookbook://cook/<uuid>`. `cookID` is added so PR-3 deep-link
    /// routing can disambiguate two cooks of the same recipe.
    static let recipeIDUserInfoKey = "recipeID"
    static let cookIDUserInfoKey = "cookID"

    /// Schedule (or replace) the timer notification for one cook. Per
    /// cook, not per timer slot — re-extending the same cook's running
    /// timer just rewrites the cook's existing pending request. Two
    /// concurrent cooks each get their own request keyed by `cookID`,
    /// so neither overwrites the other.
    static func schedule(
        cookID: UUID,
        endDate date: Date,
        label: String,
        recipeID: UUID,
        recipeTitle: String,
        stepNumber: Int,
        stepText: String?
    ) {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = formatTitle(recipeTitle: recipeTitle, stepNumber: stepNumber)
        content.body = formatBody(label: label, stepText: stepText)
        content.userInfo = [
            recipeIDUserInfoKey: recipeID.uuidString,
            cookIDUserInfoKey: cookID.uuidString,
        ]
        if Bundle.main.url(forResource: "timer-alarm", withExtension: "caf") != nil {
            content.sound = UNNotificationSound(named: UNNotificationSoundName("timer-alarm.caf"))
        } else {
            content.sound = .default
        }

        let id = identifier(for: cookID)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        let center = UNUserNotificationCenter.current()
        // Replace any previously scheduled request for THIS cook so
        // extend/subtract and step-to-step transitions don't leave a
        // stale notification. Other cooks' notifications stay intact.
        center.removePendingNotificationRequests(withIdentifiers: [id])
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

    /// Remove pending + delivered notifications for one cook only.
    /// Other cooks' timers are untouched — exactly what we want when a
    /// single cook's timer is canceled, extended, or its ready overlay
    /// is dismissed while another cook is still ticking.
    static func cancel(cookID: UUID) {
        let id = identifier(for: cookID)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// Wipe every cooking-timer notification — pending and delivered,
    /// per-cook + the legacy single-id leftover from pre-multi installs.
    /// Called from `CookingSession.endAll()` when the whole session is
    /// torn down. Async fetch + filter is required because pending IDs
    /// aren't enumerable synchronously.
    static func cancelAll() {
        let center = UNUserNotificationCenter.current()
        // Legacy id (just in case a notification scheduled under a
        // pre-multi build is still pending when v2 launches).
        center.removePendingNotificationRequests(withIdentifiers: [legacyIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [legacyIdentifier])
        // Per-cook ids — fetch then filter by prefix.
        center.getPendingNotificationRequests { reqs in
            let ids = reqs.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
            if !ids.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
        center.getDeliveredNotifications { notifs in
            let ids = notifs.map(\.request.identifier).filter { $0.hasPrefix(identifierPrefix) }
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }
}
