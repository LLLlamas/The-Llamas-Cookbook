import ActivityKit
import Foundation

/// Payload for the cooking-timer Live Activity. Shared between the main
/// app (which issues `Activity<TimerAttributes>.request/update/end` calls)
/// and the Widget Extension (which renders the Dynamic Island + Lock
/// Screen presentations from the same type).
///
/// `ContentState` is the mutable part — `endDate` shifts when the user
/// adds or subtracts time. `TimerAttributes` (the outer struct) is
/// immutable for the life of the activity and carries recipe context.
struct TimerAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// When the timer fires. Used with `Text(_:style: .timer)` in the
        /// widget so iOS counts down automatically without our app
        /// pushing per-second updates.
        public var endDate: Date

        /// Human label for the timer ("Bake", "Pot", "Cook"). Capitalized
        /// for display inside the widget.
        public var label: String

        /// 1-based index of the step that owns this timer, so the widget
        /// can say "Step 3" without needing the full recipe object.
        public var stepNumber: Int
    }

    /// Recipe title shown in the Lock Screen / expanded Dynamic Island
    /// presentations. Immutable during the activity.
    public var recipeTitle: String

    /// Identifier the widget bakes into its `widgetURL` so a tap deep-links
    /// the user back into Cook Mode for the exact recipe whose timer fired,
    /// not just "the foreground app".
    public var recipeID: UUID

    /// Distinct cook identity per active session — admits the case (PR 2)
    /// where the same recipe is cooked twice in parallel and each batch
    /// owns its own timer + Live Activity. **Optional for migration**:
    /// activities that survived an app upgrade across the multi-recipe
    /// landing decode with `cookID == nil`, which the registry treats as
    /// "this is the only cook in the session — adopt it." Default-nil so
    /// existing `TimerAttributes(recipeTitle:recipeID:)` call sites
    /// still compile during the PR-1 incremental rollout.
    public var cookID: UUID? = nil
}
