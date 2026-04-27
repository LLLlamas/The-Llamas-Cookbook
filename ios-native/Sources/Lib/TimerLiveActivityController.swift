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
        // No auto-adopt: with multi-cook, multiple activities may be
        // alive across distinct cooks and `activities.first` is a
        // coin-flip on which one we'd pick. CookModeView calls
        // `adopt(forRecipeID:)` once it knows which cook it's
        // rendering so the right orphan attaches.
    }

    /// Re-attach to an existing Live Activity for this cook's recipe,
    /// if iOS still has one alive from a previous app session. Called
    /// from `CookModeView.onAppear` so a kill-and-restore mid-timer
    /// hands the lock-screen widget back to the right controller
    /// instead of orphaning it. Multi-cook safe: filters by
    /// `recipeID` so a different cook's activity isn't grabbed.
    func adopt(forRecipeID recipeID: UUID) {
        guard activity == nil else { return }
        activity = Activity<TimerAttributes>.activities
            .first(where: { $0.attributes.recipeID == recipeID })
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
