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

    /// True when a Live Activity is currently running for this cook.
    /// Used by `extendTimer` to choose between `start` (after expiry
    /// cleared the activity) and `update` (mid-run adjustment).
    var isActive: Bool { activity != nil }

    init() {
        // No auto-adopt: with multi-cook, multiple activities may be
        // alive across distinct cooks and `activities.first` is a
        // coin-flip on which one we'd pick. CookModeView calls
        // `adopt(forRecipeID:)` once it knows which cook it's
        // rendering so the right orphan attaches.
    }

    /// Re-attach to an existing Live Activity for this cook, if iOS
    /// still has one alive from a previous app session. Called from
    /// `CookModeView.onAppear` so a kill-and-restore mid-timer hands
    /// the lock-screen widget back to the right controller instead of
    /// orphaning it. Filters by `cookID` so two parallel cooks of the
    /// same recipe don't grab each other's activities. Falls back to
    /// a legacy activity (cookID nil) for the same recipe so users who
    /// upgrade across the multi-cook landing don't lose their banner.
    func adopt(forCookID cookID: UUID, recipeID: UUID) {
        guard activity == nil else { return }
        let activities = Activity<TimerAttributes>.activities
        if let match = activities.first(where: { $0.attributes.cookID == cookID }) {
            activity = match
            return
        }
        activity = activities.first(where: {
            $0.attributes.cookID == nil && $0.attributes.recipeID == recipeID
        })
    }

    /// Begin a live activity tied to the given timer. No-op if one is
    /// already running — the caller should `end()` first if they want
    /// to replace it.
    func start(
        cookID: UUID,
        recipeID: UUID,
        recipeTitle: String,
        endDate: Date,
        label: String,
        stepNumber: Int
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity == nil else { return }

        let attributes = TimerAttributes(
            recipeTitle: recipeTitle,
            recipeID: recipeID,
            cookID: cookID
        )
        let state = TimerAttributes.ContentState(
            endDate: endDate,
            label: label,
            stepNumber: stepNumber
        )
        // staleDate tells iOS when to fade/remove the activity automatically
        // if the app never issues an update or end. Give it a small buffer
        // past the end date so the "0:00" state is visible briefly.
        let content = ActivityContent(state: state, staleDate: endDate.addingTimeInterval(30))

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
        let content = ActivityContent(state: state, staleDate: endDate.addingTimeInterval(30))
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

    /// End every Live Activity tied to a given cook, regardless of
    /// which controller (if any) currently owns it. Lets non-view
    /// callers — `CookingSession.remove`, `endAll()` — clean up
    /// activities for cooks that were never foregrounded (and
    /// therefore never adopted by a `CookModeView`'s `@State`
    /// controller). Fire-and-forget; `Activity.end` is async but the
    /// dismissal itself is owned by ActivityKit, so we don't need to
    /// await before mutating the session.
    ///
    /// Filters by `cookID` so two parallel cooks of the same recipe
    /// don't tear each other's banners down.
    static func endActivities(forCookID cookID: UUID) {
        let matching = Activity<TimerAttributes>.activities
            .filter { $0.attributes.cookID == cookID }
        endAll(matching)
    }

    /// End every Live Activity tied to a given recipe. Used by the
    /// recipe-deletion path (`cleanupCooks(forDeletedRecipeID:)`)
    /// where every cook for that recipe is being torn down anyway,
    /// so collapsing all matching banners is the right behavior.
    /// Also catches legacy activities (cookID nil) created before
    /// the multi-cook landing.
    static func endActivities(forRecipeID recipeID: UUID) {
        let matching = Activity<TimerAttributes>.activities
            .filter { $0.attributes.recipeID == recipeID }
        endAll(matching)
    }

    private static func endAll(_ activities: [Activity<TimerAttributes>]) {
        for activity in activities {
            let finalContent = ActivityContent(state: activity.content.state, staleDate: nil)
            Task {
                await activity.end(finalContent, dismissalPolicy: .immediate)
            }
        }
    }
}
