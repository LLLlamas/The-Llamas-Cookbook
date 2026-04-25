import ActivityKit
import Foundation

/// Thin wrapper around a single Live Activity instance for the cooking
/// timer. Tolerates being called in environments where Live Activities
/// aren't available (simulator before iOS 16.2, user disabled them in
/// Settings, rate-limited) — every failure path silently degrades to
/// "no live activity", and the existing local notification still fires.
@MainActor
final class TimerLiveActivityController {
    private var activity: Activity<TimerAttributes>?

    init() {
        // Adopt any activity that's still alive in iOS from a previous
        // app session — without this, a kill-and-restore mid-timer
        // leaves the lock-screen widget visible but unreachable from
        // the new controller, and the next `end()` becomes a no-op
        // while the orphan keeps ticking until its staleDate.
        activity = Activity<TimerAttributes>.activities.first
    }

    /// Begin a live activity tied to the given timer. No-op if one is
    /// already running — the caller should `end()` first if they want
    /// to replace it.
    func start(
        recipeID: UUID,
        recipeTitle: String,
        endDate: Date,
        label: String,
        stepNumber: Int
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity == nil else { return }

        let attributes = TimerAttributes(recipeTitle: recipeTitle, recipeID: recipeID)
        let state = TimerAttributes.ContentState(
            endDate: endDate,
            label: label,
            stepNumber: stepNumber
        )
        // staleDate tells iOS when to fade/remove the activity automatically
        // if the app never issues an update or end. Give it a small buffer
        // past the end date so the "0:00" state is visible briefly.
        let content = ActivityContent(state: state, staleDate: endDate.addingTimeInterval(120))

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            activity = nil
        }
    }

    /// Push a new end date (extend / subtract) into the running activity.
    func update(endDate: Date, label: String, stepNumber: Int) {
        guard let activity else { return }
        let state = TimerAttributes.ContentState(
            endDate: endDate,
            label: label,
            stepNumber: stepNumber
        )
        let content = ActivityContent(state: state, staleDate: endDate.addingTimeInterval(120))
        Task {
            await activity.update(content)
        }
    }

    /// Immediate dismissal on cancel or Stop-after-expiry. Fire-and-forget.
    func end() {
        guard let activity else { return }
        let finalState = activity.content.state
        let finalContent = ActivityContent(state: finalState, staleDate: nil)
        Task {
            await activity.end(finalContent, dismissalPolicy: .immediate)
        }
        self.activity = nil
    }
}
